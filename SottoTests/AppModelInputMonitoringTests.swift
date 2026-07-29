import XCTest
@testable import Sotto

@MainActor
final class AppModelInputMonitoringTests: XCTestCase {
    func testInputMonitoringPublishesLevelsAndStopsWithoutRecording() async throws {
        let monitor = InputMonitorSpy()
        let model = AppModel(inputMonitor: monitor)

        model.toggleInputMonitoring()
        try await waitUntil { model.isInputMonitoring }

        XCTAssertEqual(model.audioLevels.system, 0.25)
        XCTAssertEqual(model.audioLevels.microphone, 0.75)
        let startCount = await monitor.startCount
        XCTAssertEqual(startCount, 1)

        model.toggleInputMonitoring()
        try await waitUntil {
            let stopCount = await monitor.stopCount
            return !model.isInputMonitoring && stopCount == 1
        }

        XCTAssertEqual(model.audioLevels, AudioLevelSnapshot())
    }

    func testStoppingDuringStartPreventsGhostMonitoring() async throws {
        let monitor = SuspendedInputMonitorSpy()
        let model = AppModel(inputMonitor: monitor)

        model.toggleInputMonitoring()
        try await waitUntil { await monitor.startCount == 1 }
        model.stopInputMonitoring()

        try await waitUntil {
            let stopCount = await monitor.stopCount
            return !model.isInputMonitoring
                && !model.isInputMonitoringTransitioning
                && stopCount == 1
        }
        await monitor.finishStart()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(model.isInputMonitoring)
        XCTAssertEqual(model.audioLevels, AudioLevelSnapshot())
    }

    func testInputMonitoringUsesSelectedMicrophone() async throws {
        let suiteName = "AppModelInputMonitoringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.microphoneDeviceID = "selected-microphone"
        let monitor = InputMonitorSpy()
        let model = AppModel(settings: settings, inputMonitor: monitor)

        model.toggleInputMonitoring()
        try await waitUntil { model.isInputMonitoring }

        let capturedDeviceID = await monitor.microphoneDeviceID
        XCTAssertEqual(capturedDeviceID, "selected-microphone")
        model.stopInputMonitoring()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("条件が時間内に成立しませんでした。")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor InputMonitorSpy: AppInputMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var microphoneDeviceID: String?

    func start(
        microphoneDeviceID: String?,
        levelHandler: @escaping LevelHandler,
        stopHandler: @escaping StopHandler
    ) async throws {
        startCount += 1
        self.microphoneDeviceID = microphoneDeviceID
        await levelHandler(AudioLevelSnapshot(system: 0.25, microphone: 0.75))
    }

    func stop() async {
        stopCount += 1
    }
}

private actor SuspendedInputMonitorSpy: AppInputMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?

    func start(
        microphoneDeviceID: String?,
        levelHandler: @escaping LevelHandler,
        stopHandler: @escaping StopHandler
    ) async throws {
        startCount += 1
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() async {
        stopCount += 1
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}
