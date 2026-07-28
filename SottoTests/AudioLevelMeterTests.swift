import XCTest
@testable import Sotto

final class AudioLevelMeterTests: XCTestCase {
    func testSilenceAndInvalidSamplesReturnZero() {
        XCTAssertEqual(AudioLevelMeter.normalizedRMS(samples: []), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedRMS(samples: [0, 0]), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedRMS(samples: [.infinity]), 0)
    }

    func testUnityAmplitudeReturnsOne() {
        XCTAssertEqual(AudioLevelMeter.normalizedRMS(samples: [1, -1, 1, -1]), 1)
    }

    func testMinusThirtyDecibelsMapsToHalf() {
        let amplitude = Float(pow(10.0, -30.0 / 20.0))
        XCTAssertEqual(
            AudioLevelMeter.normalizedRMS(samples: [amplitude, -amplitude]),
            0.5,
            accuracy: 0.0001
        )
    }

    func testVeryLowNoiseIsSuppressed() {
        XCTAssertEqual(
            AudioLevelMeter.normalizedRMS(samples: [0.0005, -0.0005]),
            0
        )
    }
}
