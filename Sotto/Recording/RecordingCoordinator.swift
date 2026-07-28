import Foundation

/// Coordinates safe part finalization and automatic restart. Storage naming and
/// preflight policy remain outside this actor and are supplied by the app layer.
actor RecordingCoordinator {
    typealias SegmentProvider = @Sendable (Int) async throws -> RecordingSegmentDestination
    typealias StateHandler = @Sendable (RecordingState) -> Void
    typealias AudioLevelHandler = @Sendable (AudioLevelSnapshot) -> Void

    private(set) var state: RecordingState = .idle {
        didSet { stateHandler(state) }
    }

    private let stateHandler: StateHandler
    private let sleepAssertion = SleepAssertion()
    private var deviceMonitor: AudioDeviceMonitor?
    private var session: ScreenCaptureSession?
    private var pipeline: RecordingPipeline?
    private var segmentProvider: SegmentProvider?
    private var settings = RecordingCoreSettings()
    private var currentSegment = 0
    private var recordingRequested = false
    private var rolloverInProgress = false
    private var audioLevelHandler: AudioLevelHandler?
    private var audioLevels = AudioLevelSnapshot()
    private var lastLevelPublication: ContinuousClock.Instant?

    init(stateHandler: @escaping StateHandler = { _ in }) {
        self.stateHandler = stateHandler
    }

    func setAudioLevelHandler(_ handler: AudioLevelHandler?) {
        audioLevelHandler = handler
        handler?(audioLevels)
    }

    func start(
        settings: RecordingCoreSettings,
        segmentProvider: @escaping SegmentProvider
    ) async throws {
        guard state == .idle || isFailedState else { return }
        state = .preflighting
        self.settings = settings
        self.segmentProvider = segmentProvider
        recordingRequested = true
        currentSegment = 1

        do {
            try sleepAssertion.acquire()
            let monitor = AudioDeviceMonitor { [weak self] in
                Task { await self?.requestRollover(reason: "音声デバイスが変更されました。") }
            }
            try monitor.start()
            deviceMonitor = monitor
            try await startSegment(number: currentSegment)
        } catch {
            recordingRequested = false
            deviceMonitor?.stop()
            deviceMonitor = nil
            sleepAssertion.release()
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        guard state != .idle else { return }
        recordingRequested = false
        deviceMonitor?.stop()
        deviceMonitor = nil
        if rolloverInProgress {
            while rolloverInProgress {
                await Task.yield()
            }
            return
        }
        state = .stopping

        do {
            try await session?.stop()
        } catch {
            // Finalizing the writer is more important than a stopCapture error.
        }
        session = nil
        state = .finalizing
        do {
            try await pipeline?.finish()
            pipeline = nil
            sleepAssertion.release()
            clearAudioLevels()
            state = .idle
        } catch {
            pipeline = nil
            sleepAssertion.release()
            clearAudioLevels()
            state = .failed(message: error.localizedDescription)
        }
    }

    func resetFailure() {
        guard isFailedState else { return }
        state = .idle
    }

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    private func startSegment(number: Int) async throws {
        guard let segmentProvider else { return }
        state = .starting(segment: number)
        let destination = try await segmentProvider(number)
        let configuration = RecordingPipelineConfiguration(
            mixedFileURL: destination.mixedFileURL,
            systemStemURL: settings.transcriptionEnabled ? destination.systemStemURL : nil,
            microphoneStemURL: settings.transcriptionEnabled ? destination.microphoneStemURL : nil,
            bitRate: settings.bitRate,
            systemGain: settings.systemGain,
            microphoneGain: settings.microphoneGain
        )
        let pipeline = try RecordingPipeline(
            configuration: configuration,
            onFailure: { [weak self] error in
                Task { await self?.requestRollover(reason: error.localizedDescription) }
            },
            onLevel: { [weak self] source, level in
                Task { await self?.receiveAudioLevel(level, from: source) }
            }
        )
        self.pipeline = pipeline

        let session = try ScreenCaptureSession(
            audioHandler: { [weak pipeline] chunk in
                pipeline?.accept(chunk)
            },
            stopHandler: { [weak self] error in
                Task { await self?.requestRollover(reason: error.localizedDescription) }
            }
        )
        self.session = session
        do {
            try await session.start()
            state = .recording(
                startedAt: Date(),
                segment: number,
                fileURL: destination.mixedFileURL
            )
        } catch {
            self.session = nil
            try? await pipeline.finish()
            self.pipeline = nil
            throw error
        }
    }

    private func requestRollover(reason: String) async {
        guard recordingRequested, !rolloverInProgress else { return }
        rolloverInProgress = true
        defer { rolloverInProgress = false }
        let completedSegment = currentSegment
        state = .rollingOver(completedSegment: completedSegment)

        do {
            try await session?.stop()
        } catch {
            // The delegate may already have reported the stopped stream.
        }
        session = nil
        do {
            try await pipeline?.finish()
            pipeline = nil
        } catch {
            recordingRequested = false
            deviceMonitor?.stop()
            deviceMonitor = nil
            sleepAssertion.release()
            clearAudioLevels()
            state = .failed(message: "\(reason) \(error.localizedDescription)")
            return
        }

        guard recordingRequested else {
            sleepAssertion.release()
            clearAudioLevels()
            state = .idle
            return
        }
        currentSegment += 1
        do {
            try await startSegment(number: currentSegment)
        } catch {
            recordingRequested = false
            deviceMonitor?.stop()
            deviceMonitor = nil
            sleepAssertion.release()
            clearAudioLevels()
            state = .failed(message: "\(reason) \(error.localizedDescription)")
        }
    }

    private func receiveAudioLevel(_ level: Float, from source: AudioSource) {
        let clamped = min(1, max(0, level))
        switch source {
        case .system:
            audioLevels.system = audioLevels.system * 0.65 + clamped * 0.35
        case .microphone:
            audioLevels.microphone = audioLevels.microphone * 0.65 + clamped * 0.35
        }

        let now = ContinuousClock.now
        if let lastLevelPublication,
           now - lastLevelPublication < .milliseconds(50) {
            return
        }
        lastLevelPublication = now
        audioLevelHandler?(audioLevels)
    }

    private func clearAudioLevels() {
        audioLevels = AudioLevelSnapshot()
        lastLevelPublication = nil
        audioLevelHandler?(audioLevels)
    }
}
