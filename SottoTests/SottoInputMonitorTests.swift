import CoreMedia
import Foundation
import XCTest
@testable import Sotto

final class SottoInputMonitorTests: XCTestCase {
    func testPassesSelectedMicrophoneToCaptureSession() async throws {
        let session = FakeAudioCaptureSession()
        let selectedDevice = MicrophoneIDCollector()
        let monitor = SottoInputMonitor(
            sessionFactory: { microphoneDeviceID, audioHandler, stopHandler in
                selectedDevice.store(microphoneDeviceID)
                session.configure(audioHandler: audioHandler, stopHandler: stopHandler)
                return session
            },
            permissionRequester: {}
        )

        try await monitor.start(
            microphoneDeviceID: "built-in-microphone",
            levelHandler: { _ in },
            stopHandler: { _ in }
        )

        XCTAssertEqual(selectedDevice.value, "built-in-microphone")
        await monitor.stop()
    }

    func testStopDuringPermissionWaitPreventsGhostCapture() async throws {
        let session = FakeAudioCaptureSession()
        let permissionGate = PermissionGate()
        let levels = LevelCollector()
        let monitor = SottoInputMonitor(
            sessionFactory: { _, audioHandler, stopHandler in
                session.configure(audioHandler: audioHandler, stopHandler: stopHandler)
                return session
            },
            permissionRequester: {
                await permissionGate.wait()
            }
        )

        let startTask = Task {
            try await monitor.start(
                microphoneDeviceID: nil,
                levelHandler: { snapshot in
                    await levels.append(snapshot)
                },
                stopHandler: { _ in }
            )
        }
        try await waitUntil {
            await permissionGate.isWaiting
        }
        await monitor.stop()
        await permissionGate.resume()
        try await startTask.value

        XCTAssertEqual(session.observedStartCount, 0)
        let lastLevel = await levels.lastValue()
        XCTAssertEqual(lastLevel, AudioLevelSnapshot())
    }

    func testPublishesLevelsAndZeroAfterStop() async throws {
        let session = FakeAudioCaptureSession()
        let collector = LevelCollector()
        let monitor = SottoInputMonitor(
            sessionFactory: { _, audioHandler, stopHandler in
                session.configure(audioHandler: audioHandler, stopHandler: stopHandler)
                return session
            },
            permissionRequester: {}
        )

        try await monitor.start(
            microphoneDeviceID: nil,
            levelHandler: { snapshot in
                await collector.append(snapshot)
            },
            stopHandler: { _ in }
        )
        session.emit(
            CapturedAudioChunk(
                source: .microphone,
                presentationTimeStamp: .zero,
                sampleRate: 48_000,
                channelCount: 2,
                samples: [Float](repeating: 1, count: 2_048)
            )
        )
        try await waitUntil {
            await collector.values.contains { $0.microphone > 0 }
        }

        await monitor.stop()
        let valuesAfterStop = await collector.values
        XCTAssertEqual(valuesAfterStop.last, AudioLevelSnapshot())
        XCTAssertEqual(session.observedStopCount, 1)

        // A callback already queued by ScreenCaptureKit cannot revive the meter.
        session.emit(
            CapturedAudioChunk(
                source: .system,
                presentationTimeStamp: .zero,
                sampleRate: 48_000,
                channelCount: 2,
                samples: [Float](repeating: 1, count: 2_048)
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        let valuesAfterLateCallback = await collector.values
        XCTAssertEqual(valuesAfterLateCallback.last, AudioLevelSnapshot())
    }

    func testUnexpectedStopIsReportedOnlyOnceAndClearsLevels() async throws {
        let session = FakeAudioCaptureSession()
        let levels = LevelCollector()
        let failures = FailureCollector()
        let monitor = SottoInputMonitor(
            sessionFactory: { _, audioHandler, stopHandler in
                session.configure(audioHandler: audioHandler, stopHandler: stopHandler)
                return session
            },
            permissionRequester: {}
        )
        try await monitor.start(
            microphoneDeviceID: nil,
            levelHandler: { snapshot in
                await levels.append(snapshot)
            },
            stopHandler: { error in
                await failures.append(error.localizedDescription)
            }
        )

        session.fail(TestFailure.captureStopped)
        session.fail(TestFailure.captureStopped)
        try await waitUntil {
            await failures.values.count == 1
        }

        let failureValues = await failures.values
        let levelValues = await levels.values
        XCTAssertEqual(failureValues.count, 1)
        XCTAssertEqual(levelValues.last, AudioLevelSnapshot())
    }

    func testStopWaitsForCaptureStartBeforeReturning() async throws {
        let session = SuspendedStartAudioCaptureSession()
        let monitor = SottoInputMonitor(
            sessionFactory: { _, audioHandler, stopHandler in
                session.configure(audioHandler: audioHandler, stopHandler: stopHandler)
                return session
            },
            permissionRequester: {}
        )

        let startTask = Task {
            try await monitor.start(
                microphoneDeviceID: nil,
                levelHandler: { _ in },
                stopHandler: { _ in }
            )
        }
        try await waitUntil {
            session.isStartWaiting
        }

        let stopCompletion = CompletionFlag()
        let stopTask = Task {
            await monitor.stop()
            await stopCompletion.markFinished()
        }
        try await waitUntil {
            session.observedStopCount == 1
        }
        let stoppedBeforeStartFinished = await stopCompletion.isFinished
        XCTAssertFalse(stoppedBeforeStartFinished)

        session.finishStart()
        try await startTask.value
        await stopTask.value

        XCTAssertEqual(session.observedStartCount, 1)
        XCTAssertEqual(session.observedStopCount, 2)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("条件待機がタイムアウトしました。")
    }
}

private final class FakeAudioCaptureSession: AudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var audioHandler: ScreenCaptureSession.AudioHandler?
    private var stopHandler: ScreenCaptureSession.StopHandler?
    private var startCount = 0
    private(set) var stopCount = 0

    var observedStartCount: Int {
        lock.withLock { startCount }
    }

    var observedStopCount: Int {
        lock.withLock { stopCount }
    }

    func configure(
        audioHandler: @escaping ScreenCaptureSession.AudioHandler,
        stopHandler: @escaping ScreenCaptureSession.StopHandler
    ) {
        lock.withLock {
            self.audioHandler = audioHandler
            self.stopHandler = stopHandler
        }
    }

    func start() async throws {
        lock.withLock {
            startCount += 1
        }
    }

    func stop() async throws {
        lock.withLock {
            stopCount += 1
        }
    }

    func emit(_ chunk: CapturedAudioChunk) {
        let handler = lock.withLock { audioHandler }
        handler?(chunk)
    }

    func fail(_ error: Error) {
        let handler = lock.withLock { stopHandler }
        handler?(error)
    }
}

private final class SuspendedStartAudioCaptureSession: AudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startCount = 0
    private var stopCount = 0

    var isStartWaiting: Bool {
        lock.withLock { startContinuation != nil }
    }

    var observedStartCount: Int {
        lock.withLock { startCount }
    }

    var observedStopCount: Int {
        lock.withLock { stopCount }
    }

    func configure(
        audioHandler: @escaping ScreenCaptureSession.AudioHandler,
        stopHandler: @escaping ScreenCaptureSession.StopHandler
    ) {}

    func start() async throws {
        lock.withLock {
            startCount += 1
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                startContinuation = continuation
            }
        }
    }

    func stop() async throws {
        lock.withLock {
            stopCount += 1
        }
    }

    func finishStart() {
        let continuation = lock.withLock {
            let current = startContinuation
            startContinuation = nil
            return current
        }
        continuation?.resume()
    }
}

private actor LevelCollector {
    private(set) var values: [AudioLevelSnapshot] = []

    func append(_ value: AudioLevelSnapshot) {
        values.append(value)
    }

    func lastValue() -> AudioLevelSnapshot? {
        values.last
    }
}

private actor FailureCollector {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor CompletionFlag {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private enum TestFailure: LocalizedError {
    case captureStopped

    var errorDescription: String? { "capture stopped" }
}

private actor PermissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class MicrophoneIDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.withLock { storedValue }
    }

    func store(_ value: String?) {
        lock.withLock {
            storedValue = value
        }
    }
}
