import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum AssetWriterSinkError: LocalizedError {
    case cannotAddInput
    case failedToStart(String)
    case queueOverflow
    case appendFailed(String)
    case finishFailed(String)
    case sampleBuffer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "AAC書き出し入力を作成できませんでした。"
        case let .failedToStart(message):
            "音声ファイルの書き出しを開始できませんでした: \(message)"
        case .queueOverflow:
            "エンコーダーが追いつかず、音声書き出しキューが上限を超えました。"
        case let .appendFailed(message):
            "音声ファイルへの追記に失敗しました: \(message)"
        case let .finishFailed(message):
            "音声ファイルを安全に閉じられませんでした: \(message)"
        case let .sampleBuffer(status):
            "PCMサンプルの作成に失敗しました（OSStatus \(status)）。"
        }
    }
}

protocol RecordingAudioWriter: AnyObject, Sendable {
    @discardableResult
    func append(_ chunk: CapturedAudioChunk) -> Bool
    func finish() async throws
    func cancel()
}

/// Incremental AAC/m4a writer with bounded memory and fragmented output.
final class AssetWriterSink: RecordingAudioWriter, @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let writerQueue: DispatchQueue
    private let stateLock = NSLock()
    private let maximumPendingFrames: Int
    private let failureHandler: FailureHandler
    private var pendingFrames = 0
    private var firstFailure: Error?
    private var isFinishing = false
    private var formatDescription: CMAudioFormatDescription?

    init(
        url: URL,
        bitRate: Int,
        maximumQueuedDuration: TimeInterval = 2,
        failureHandler: @escaping FailureHandler
    ) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioFormatNormalizer.sampleRate,
                AVNumberOfChannelsKey: Int(AudioFormatNormalizer.channelCount),
                AVEncoderBitRateKey: bitRate,
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw AssetWriterSinkError.cannotAddInput
        }
        writer.add(input)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        maximumPendingFrames = Int(AudioFormatNormalizer.sampleRate * maximumQueuedDuration)
        self.failureHandler = failureHandler
        writerQueue = DispatchQueue(label: "jp.sotto.asset-writer.\(UUID().uuidString)")

        guard writer.startWriting() else {
            throw AssetWriterSinkError.failedToStart(
                writer.error.map(String.init(describing:)) ?? "不明なエラー"
            )
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Returns false when the bounded queue rejects the chunk. The failure callback
    /// is invoked once and the recording coordinator should roll over to a new part.
    @discardableResult
    func append(_ chunk: CapturedAudioChunk) -> Bool {
        guard chunk.frameCount > 0 else { return true }
        let accepted = stateLock.withLock {
            guard !isFinishing, firstFailure == nil,
                  pendingFrames + chunk.frameCount <= maximumPendingFrames else {
                return false
            }
            pendingFrames += chunk.frameCount
            return true
        }
        guard accepted else {
            reportFailure(AssetWriterSinkError.queueOverflow)
            return false
        }

        writerQueue.async { [self] in
            defer {
                stateLock.withLock {
                    pendingFrames -= chunk.frameCount
                }
            }
            do {
                let readinessDeadline = ContinuousClock.now + .seconds(2)
                while !input.isReadyForMoreMediaData,
                      ContinuousClock.now < readinessDeadline,
                      writer.status == .writing {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard input.isReadyForMoreMediaData else {
                    throw AssetWriterSinkError.queueOverflow
                }
                let sampleBuffer = try makeSampleBuffer(from: chunk)
                guard input.append(sampleBuffer) else {
                    throw AssetWriterSinkError.appendFailed(
                        writer.error?.localizedDescription ?? "不明なエラー"
                    )
                }
            } catch {
                reportFailure(error)
            }
        }
        return true
    }

    func finish() async throws {
        stateLock.withLock {
            isFinishing = true
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async { [self] in
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if let failure = self.stateLock.withLock({ self.firstFailure }) {
                        continuation.resume(throwing: failure)
                    } else if self.writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: AssetWriterSinkError.finishFailed(
                                self.writer.error?.localizedDescription ?? "不明なエラー"
                            )
                        )
                    }
                }
            }
        }
    }

    func cancel() {
        let shouldCancel = stateLock.withLock {
            guard !isFinishing else { return false }
            isFinishing = true
            return true
        }
        if shouldCancel {
            writer.cancelWriting()
        }
    }

    private func reportFailure(_ error: Error) {
        let shouldReport = stateLock.withLock {
            guard firstFailure == nil else { return false }
            firstFailure = error
            return true
        }
        if shouldReport {
            failureHandler(error)
        }
    }

    private func makeSampleBuffer(from chunk: CapturedAudioChunk) throws -> CMSampleBuffer {
        let description = try pcmFormatDescription()
        let byteCount = chunk.samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw AssetWriterSinkError.sampleBuffer(status)
        }
        status = chunk.samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AssetWriterSinkError.sampleBuffer(status)
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: chunk.frameCount,
            presentationTimeStamp: chunk.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw AssetWriterSinkError.sampleBuffer(status)
        }
        return sampleBuffer
    }

    private func pcmFormatDescription() throws -> CMAudioFormatDescription {
        if let formatDescription {
            return formatDescription
        }
        let channels = UInt32(AudioFormatNormalizer.channelCount)
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: AudioFormatNormalizer.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &created
        )
        guard status == noErr, let created else {
            throw AssetWriterSinkError.sampleBuffer(status)
        }
        formatDescription = created
        return created
    }
}
