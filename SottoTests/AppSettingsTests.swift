import XCTest
@testable import Sotto

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsMatchProductRequirements() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.bitrate, .kbps192)
        XCTAssertEqual(settings.microphoneGain, 0.7)
        XCTAssertEqual(settings.systemGain, 0.7)
        XCTAssertTrue(settings.transcriptionEnabled)
        XCTAssertFalse(settings.keepTemporaryFiles)
    }

    func testSettingsArePersisted() throws {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        settings?.bitrate = .kbps256
        settings?.microphoneGain = 0.5
        settings?.transcriptionEnabled = false
        settings = nil

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.bitrate, .kbps256)
        XCTAssertEqual(restored.microphoneGain, 0.5)
        XCTAssertFalse(restored.transcriptionEnabled)
    }
}
