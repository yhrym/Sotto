import CoreMedia
import Foundation

enum AudioSource: String, Sendable {
    case system
    case microphone
}

/// Interleaved Float32 PCM. Capture adapters must normalize to this representation
/// before publishing a chunk.
struct CapturedAudioChunk: Sendable {
    let source: AudioSource
    let presentationTimeStamp: CMTime
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]

    var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    var duration: CMTime {
        CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate))
    }

    func replacingSource(with source: AudioSource) -> Self {
        Self(
            source: source,
            presentationTimeStamp: presentationTimeStamp,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: samples
        )
    }
}

struct SynchronizedAudioBlock: Sendable {
    let presentationTimeStamp: CMTime
    let sampleRate: Double
    let channelCount: Int
    let systemSamples: [Float]
    let microphoneSamples: [Float]
    let mixedSamples: [Float]

    var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return mixedSamples.count / channelCount
    }

    func chunk(for source: AudioSource) -> CapturedAudioChunk {
        CapturedAudioChunk(
            source: source,
            presentationTimeStamp: presentationTimeStamp,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: source == .system ? systemSamples : microphoneSamples
        )
    }

    var mixedChunk: CapturedAudioChunk {
        CapturedAudioChunk(
            source: .system,
            presentationTimeStamp: presentationTimeStamp,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: mixedSamples
        )
    }
}
