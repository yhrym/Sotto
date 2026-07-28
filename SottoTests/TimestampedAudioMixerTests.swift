import CoreMedia
import XCTest
@testable import Sotto

final class TimestampedAudioMixerTests: XCTestCase {
    func testAppliesGainsAndClampsSimultaneousSpeech() {
        var configuration = TimestampedAudioMixer.Configuration()
        configuration.sampleRate = 10
        configuration.channelCount = 2
        configuration.systemGain = 0.7
        configuration.microphoneGain = 0.7
        configuration.blockFrameCount = 2
        // Leave a reordering window so the system chunk is not intentionally
        // committed as microphone silence before the microphone callback arrives.
        configuration.maximumLateness = 1
        let mixer = TimestampedAudioMixer(configuration: configuration)

        XCTAssertTrue(mixer.append(chunk(.system, start: 0, frames: 2, value: 1)).isEmpty)
        let output = mixer.append(chunk(.microphone, start: 0, frames: 2, value: 0.5))

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].mixedSamples, [1, 1, 1, 1])
        XCTAssertEqual(output[0].systemSamples, [1, 1, 1, 1])
        XCTAssertEqual(output[0].microphoneSamples, [0.5, 0.5, 0.5, 0.5])
    }

    func testMissingSourceIsSilenceWithoutTimelineCompression() {
        var configuration = TimestampedAudioMixer.Configuration()
        configuration.sampleRate = 10
        configuration.channelCount = 2
        configuration.blockFrameCount = 2
        configuration.maximumLateness = 0.2
        let mixer = TimestampedAudioMixer(configuration: configuration)

        let output = mixer.append(chunk(.system, start: 0, frames: 6, value: 0.25))

        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.flatMap(\.microphoneSamples), [Float](repeating: 0, count: 8))
        XCTAssertEqual(output[0].presentationTimeStamp, CMTime(value: 0, timescale: 10))
        XCTAssertEqual(output[1].presentationTimeStamp, CMTime(value: 2, timescale: 10))
    }

    func testLateEarlierPTSDoesNotMoveOriginAfterOutputStarts() {
        var configuration = TimestampedAudioMixer.Configuration()
        configuration.sampleRate = 10
        configuration.channelCount = 2
        configuration.blockFrameCount = 2
        configuration.maximumLateness = 1
        let mixer = TimestampedAudioMixer(configuration: configuration)

        _ = mixer.append(chunk(.system, start: 100, frames: 2, value: 0.1))
        let first = mixer.append(chunk(.microphone, start: 100, frames: 2, value: 0.1))
        XCTAssertEqual(first.first?.presentationTimeStamp, .zero)

        _ = mixer.append(chunk(.system, start: 99, frames: 1, value: 0.9))
        _ = mixer.append(chunk(.system, start: 102, frames: 2, value: 0.2))
        let second = mixer.append(chunk(.microphone, start: 102, frames: 2, value: 0.2))

        XCTAssertEqual(second.first?.presentationTimeStamp, CMTime(value: 2, timescale: 10))
    }

    func testFinishPadsTrailingShortBlockOnlyToLatestPTS() {
        var configuration = TimestampedAudioMixer.Configuration()
        configuration.sampleRate = 10
        configuration.channelCount = 2
        configuration.blockFrameCount = 4
        configuration.maximumLateness = 1
        let mixer = TimestampedAudioMixer(configuration: configuration)

        _ = mixer.append(chunk(.system, start: 5, frames: 3, value: 0.5))
        let output = mixer.finish()

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].frameCount, 3)
        XCTAssertEqual(output[0].presentationTimeStamp, .zero)
        XCTAssertEqual(output[0].microphoneSamples, [Float](repeating: 0, count: 6))
    }

    private func chunk(
        _ source: AudioSource,
        start: Int64,
        frames: Int,
        value: Float
    ) -> CapturedAudioChunk {
        CapturedAudioChunk(
            source: source,
            presentationTimeStamp: CMTime(value: start, timescale: 10),
            sampleRate: 10,
            channelCount: 2,
            samples: [Float](repeating: value, count: frames * 2)
        )
    }
}
