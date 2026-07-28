import CoreMedia
import Foundation

/// Aligns two normalized streams by PTS. A bounded lateness window permits modest
/// callback jitter; once it expires, a missing source is rendered as silence.
final class TimestampedAudioMixer: @unchecked Sendable {
    struct Configuration: Sendable {
        var sampleRate: Double = 48_000
        var channelCount: Int = 2
        var systemGain: Float = 0.7
        var microphoneGain: Float = 0.7
        var blockFrameCount: Int = 1_024
        var maximumLateness: TimeInterval = 0.100
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private var systemBuffer: TimelineRingBuffer
    private var microphoneBuffer: TimelineRingBuffer
    private var cursor: Int64?
    private var originFrame: Int64?

    init(configuration: Configuration = Configuration()) {
        precondition(configuration.sampleRate > 0)
        precondition(configuration.channelCount > 0)
        precondition(configuration.blockFrameCount > 0)
        self.configuration = configuration
        systemBuffer = TimelineRingBuffer(channelCount: configuration.channelCount)
        microphoneBuffer = TimelineRingBuffer(channelCount: configuration.channelCount)
    }

    func append(_ chunk: CapturedAudioChunk) -> [SynchronizedAudioBlock] {
        lock.withLock {
            guard chunk.sampleRate == configuration.sampleRate,
                  chunk.channelCount == configuration.channelCount,
                  chunk.frameCount > 0 else {
                return []
            }

            let startFrame = Self.framePosition(
                for: chunk.presentationTimeStamp,
                sampleRate: configuration.sampleRate
            )
            // Once output begins its zero point is immutable. An unusually late
            // callback may fill an unrendered range, but must never shift timestamps
            // already handed to AVAssetWriter.
            if cursor == nil {
                originFrame = min(originFrame ?? startFrame, startFrame)
            }

            switch chunk.source {
            case .system:
                systemBuffer.insert(startFrame: startFrame, samples: chunk.samples)
            case .microphone:
                microphoneBuffer.insert(startFrame: startFrame, samples: chunk.samples)
            }

            if cursor == nil, readyToBegin {
                cursor = earliestFrame
            }
            return drain(completeFinalBlock: false)
        }
    }

    /// Flushes all received audio through the latest PTS, padding both streams with
    /// silence where needed. Call only after capture outputs have stopped.
    func finish() -> [SynchronizedAudioBlock] {
        lock.withLock {
            if cursor == nil {
                cursor = earliestFrame
            }
            return drain(completeFinalBlock: true)
        }
    }

    private var earliestFrame: Int64? {
        [systemBuffer.earliestStartFrame, microphoneBuffer.earliestStartFrame]
            .compactMap { $0 }
            .min()
    }

    private var latestFrame: Int64? {
        [systemBuffer.latestEndFrame, microphoneBuffer.latestEndFrame]
            .compactMap { $0 }
            .max()
    }

    private var readyToBegin: Bool {
        if systemBuffer.earliestStartFrame != nil, microphoneBuffer.earliestStartFrame != nil {
            return true
        }
        guard let earliestFrame, let latestFrame else { return false }
        return latestFrame - earliestFrame >= latenessFrames
    }

    private var latenessFrames: Int64 {
        Int64((configuration.maximumLateness * configuration.sampleRate).rounded(.up))
    }

    private func safeEndFrame(finalizing: Bool) -> Int64? {
        guard let latestFrame else { return nil }
        if finalizing {
            return latestFrame
        }

        let systemEnd = systemBuffer.latestEndFrame
        let microphoneEnd = microphoneBuffer.latestEndFrame
        if let systemEnd, let microphoneEnd {
            let commonEnd = min(systemEnd, microphoneEnd)
            let leadingEnd = max(systemEnd, microphoneEnd)
            if leadingEnd - commonEnd > latenessFrames {
                return max(commonEnd, leadingEnd - latenessFrames)
            }
            return commonEnd
        }
        guard let earliestFrame, latestFrame - earliestFrame >= latenessFrames else {
            return nil
        }
        return latestFrame - latenessFrames
    }

    private func drain(completeFinalBlock: Bool) -> [SynchronizedAudioBlock] {
        guard var outputCursor = cursor,
              let originFrame,
              let safeEnd = safeEndFrame(finalizing: completeFinalBlock),
              safeEnd > outputCursor else {
            return []
        }

        var blocks: [SynchronizedAudioBlock] = []
        while outputCursor < safeEnd {
            let remaining = Int(safeEnd - outputCursor)
            if !completeFinalBlock, remaining < configuration.blockFrameCount {
                break
            }
            let frameCount = min(configuration.blockFrameCount, remaining)
            let system = systemBuffer.render(startFrame: outputCursor, frameCount: frameCount)
            let microphone = microphoneBuffer.render(startFrame: outputCursor, frameCount: frameCount)
            var mixed = [Float](repeating: 0, count: frameCount * configuration.channelCount)
            for index in mixed.indices {
                let value = system[index] * configuration.systemGain
                    + microphone[index] * configuration.microphoneGain
                mixed[index] = min(1, max(-1, value))
            }
            blocks.append(
                SynchronizedAudioBlock(
                    presentationTimeStamp: CMTime(
                        value: outputCursor - originFrame,
                        timescale: CMTimeScale(configuration.sampleRate)
                    ),
                    sampleRate: configuration.sampleRate,
                    channelCount: configuration.channelCount,
                    systemSamples: system,
                    microphoneSamples: microphone,
                    mixedSamples: mixed
                )
            )
            outputCursor += Int64(frameCount)
        }
        cursor = outputCursor
        systemBuffer.discard(before: outputCursor)
        microphoneBuffer.discard(before: outputCursor)
        return blocks
    }

    private static func framePosition(for time: CMTime, sampleRate: Double) -> Int64 {
        CMTimeConvertScale(
            time,
            timescale: CMTimeScale(sampleRate),
            method: .roundHalfAwayFromZero
        ).value
    }
}
