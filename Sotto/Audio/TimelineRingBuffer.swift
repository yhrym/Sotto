import Foundation

/// A sparse, timestamp-addressed PCM queue. It deliberately renders absent frames
/// as zero rather than shifting subsequent audio earlier.
struct TimelineRingBuffer: Sendable {
    private struct Entry: Sendable {
        let startFrame: Int64
        let frameCount: Int
        let samples: [Float]

        var endFrame: Int64 { startFrame + Int64(frameCount) }
    }

    let channelCount: Int
    private var entries: [Entry] = []
    private(set) var latestEndFrame: Int64?
    private(set) var earliestStartFrame: Int64?

    init(channelCount: Int) {
        self.channelCount = channelCount
    }

    mutating func insert(startFrame: Int64, samples: [Float]) {
        guard channelCount > 0, samples.count >= channelCount else { return }
        let completeSampleCount = samples.count - (samples.count % channelCount)
        let entry = Entry(
            startFrame: startFrame,
            frameCount: completeSampleCount / channelCount,
            samples: Array(samples.prefix(completeSampleCount))
        )
        entries.append(entry)
        entries.sort { $0.startFrame < $1.startFrame }
        earliestStartFrame = min(earliestStartFrame ?? startFrame, startFrame)
        latestEndFrame = max(latestEndFrame ?? entry.endFrame, entry.endFrame)
    }

    func render(startFrame: Int64, frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }
        let endFrame = startFrame + Int64(frameCount)
        var output = [Float](repeating: 0, count: frameCount * channelCount)

        for entry in entries where entry.endFrame > startFrame && entry.startFrame < endFrame {
            let overlapStart = max(startFrame, entry.startFrame)
            let overlapEnd = min(endFrame, entry.endFrame)
            let overlapFrames = Int(overlapEnd - overlapStart)
            guard overlapFrames > 0 else { continue }

            let sourceOffset = Int(overlapStart - entry.startFrame) * channelCount
            let destinationOffset = Int(overlapStart - startFrame) * channelCount
            let sampleCount = overlapFrames * channelCount
            output.replaceSubrange(
                destinationOffset..<(destinationOffset + sampleCount),
                with: entry.samples[sourceOffset..<(sourceOffset + sampleCount)]
            )
        }
        return output
    }

    mutating func discard(before frame: Int64) {
        entries.removeAll { $0.endFrame <= frame }
        earliestStartFrame = entries.map(\.startFrame).min()
    }
}
