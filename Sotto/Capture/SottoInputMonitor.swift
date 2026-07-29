import Foundation

protocol AudioCaptureSession: Sendable {
    func start() async throws
    func stop() async throws
}

extension ScreenCaptureSession: AudioCaptureSession {}

/// Input-level preview backed by ScreenCaptureKit. This actor never creates a
/// writer, temporary file, transcription job, or sleep assertion.
actor SottoInputMonitor {
    typealias LevelHandler = @Sendable (AudioLevelSnapshot) async -> Void
    typealias StopHandler = @Sendable (Error) async -> Void
    typealias SessionFactory = @Sendable (
        String?,
        @escaping ScreenCaptureSession.AudioHandler,
        @escaping ScreenCaptureSession.StopHandler
    ) throws -> any AudioCaptureSession
    typealias PermissionRequester = @Sendable () async throws -> Void

    private enum State {
        case idle
        case starting
        case active
        case stopping
    }

    private let sessionFactory: SessionFactory
    private let permissionRequester: PermissionRequester
    private var state: State = .idle
    private var session: (any AudioCaptureSession)?
    private var generation: UInt64 = 0
    private var levels = AudioLevelSnapshot()
    private var lastLevelPublication: ContinuousClock.Instant?
    private var levelHandler: LevelHandler?
    private var stopHandler: StopHandler?
    private var startAttemptInProgress = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionFactory: @escaping SessionFactory = { microphoneDeviceID, audioHandler, stopHandler in
            try ScreenCaptureSession(
                microphoneDeviceID: microphoneDeviceID,
                audioHandler: audioHandler,
                stopHandler: stopHandler
            )
        },
        permissionRequester: @escaping PermissionRequester = {
            try await CapturePermissionController.requestRequiredPermissions()
        }
    ) {
        self.sessionFactory = sessionFactory
        self.permissionRequester = permissionRequester
    }

    func start(
        microphoneDeviceID: String?,
        levelHandler: @escaping LevelHandler,
        stopHandler: @escaping StopHandler
    ) async throws {
        guard state == .idle else { return }
        startAttemptInProgress = true
        defer { finishStartAttempt() }
        generation &+= 1
        let currentGeneration = generation
        self.levelHandler = levelHandler
        self.stopHandler = stopHandler
        levels = AudioLevelSnapshot()
        lastLevelPublication = nil
        state = .starting

        do {
            try await permissionRequester()
        } catch {
            resetIfCurrent(generation: currentGeneration)
            throw error
        }
        guard generation == currentGeneration, state == .starting else {
            return
        }

        let createdSession: any AudioCaptureSession
        do {
            createdSession = try sessionFactory(
                microphoneDeviceID,
                { [weak self] chunk in
                    Task {
                        await self?.receive(chunk, generation: currentGeneration)
                    }
                },
                { [weak self] error in
                    Task {
                        await self?.captureStoppedUnexpectedly(
                            error,
                            generation: currentGeneration
                        )
                    }
                }
            )
        } catch {
            resetIfCurrent(generation: currentGeneration)
            throw error
        }
        session = createdSession

        do {
            try await createdSession.start()
        } catch {
            resetIfCurrent(generation: currentGeneration)
            throw error
        }

        guard generation == currentGeneration, state == .starting else {
            try? await createdSession.stop()
            return
        }
        state = .active
        await levelHandler(levels)
    }

    func stop() async {
        let handler = levelHandler
        guard state != .idle else {
            await handler?(AudioLevelSnapshot())
            return
        }

        generation &+= 1
        state = .stopping
        let currentSession = session
        session = nil
        try? await currentSession?.stop()
        if currentSession != nil {
            await waitForStartAttemptToFinish()
        }
        state = .idle
        levels = AudioLevelSnapshot()
        lastLevelPublication = nil
        levelHandler = nil
        stopHandler = nil
        await handler?(AudioLevelSnapshot())
    }

    private func receive(_ chunk: CapturedAudioChunk, generation: UInt64) async {
        guard generation == self.generation,
              state == .starting || state == .active else {
            return
        }
        let level = AudioLevelMeter.normalizedRMS(samples: chunk.samples)
        switch chunk.source {
        case .system:
            levels.system = levels.system * 0.65 + level * 0.35
        case .microphone:
            levels.microphone = levels.microphone * 0.65 + level * 0.35
        }

        let now = ContinuousClock.now
        if let lastLevelPublication,
           now - lastLevelPublication < .milliseconds(50) {
            return
        }
        lastLevelPublication = now
        await levelHandler?(levels)
    }

    private func captureStoppedUnexpectedly(
        _ error: Error,
        generation: UInt64
    ) async {
        guard generation == self.generation,
              state == .starting || state == .active else {
            return
        }
        self.generation &+= 1
        let levelHandler = self.levelHandler
        let stopHandler = self.stopHandler
        session = nil
        state = .idle
        levels = AudioLevelSnapshot()
        lastLevelPublication = nil
        self.levelHandler = nil
        self.stopHandler = nil
        await levelHandler?(AudioLevelSnapshot())
        await stopHandler?(error)
    }

    private func resetIfCurrent(generation: UInt64) {
        guard generation == self.generation else { return }
        self.generation &+= 1
        session = nil
        state = .idle
        levels = AudioLevelSnapshot()
        lastLevelPublication = nil
        levelHandler = nil
        stopHandler = nil
    }

    private func waitForStartAttemptToFinish() async {
        guard startAttemptInProgress else { return }
        await withCheckedContinuation { continuation in
            startCompletionWaiters.append(continuation)
        }
    }

    private func finishStartAttempt() {
        startAttemptInProgress = false
        let waiters = startCompletionWaiters
        startCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
