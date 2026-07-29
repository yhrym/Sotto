import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping

        var isBusy: Bool {
            self != .idle
        }

        var isRecording: Bool {
            if case .recording = self {
                return true
            }
            return false
        }
    }

    struct TranscriptionActivity: Equatable, Sendable {
        var description: String
        var progress: Double?
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published var transcriptionActivity: TranscriptionActivity?
    @Published var lastFailureMessage: String?
    @Published var isShowingError = false
    @Published private(set) var permissionSettingsURL: URL?
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var audioLevels = AudioLevelSnapshot()
    @Published private(set) var isInputMonitoring = false
    @Published private(set) var isInputMonitoringTransitioning = false
    @Published private(set) var availableMicrophones: [MicrophoneDevice] = []

    var settings: AppSettings
    let storage: RecordingStorage

    private let recordingService: any AppRecordingServicing
    private let transcriptionService: any AppTranscriptionServicing
    private let inputMonitor: any AppInputMonitoring
    private let loginItemController: LoginItemController
    private let finderController: FinderController
    private var elapsedTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var settingsObservation: AnyCancellable?
    private var inputMonitoringGeneration: UInt64 = 0
    private var inputMonitoringTask: Task<Void, Never>?

    init(
        settings: AppSettings = AppSettings(),
        storage: RecordingStorage = RecordingStorage(),
        recordingService: any AppRecordingServicing = UnavailableRecordingService(),
        transcriptionService: any AppTranscriptionServicing = UnavailableTranscriptionService(),
        inputMonitor: any AppInputMonitoring = UnavailableInputMonitor(),
        loginItemController: LoginItemController = LoginItemController(),
        finderController: FinderController = FinderController(),
        initialFailureMessage: String? = nil
    ) {
        self.settings = settings
        self.storage = storage
        self.recordingService = recordingService
        self.transcriptionService = transcriptionService
        self.inputMonitor = inputMonitor
        self.loginItemController = loginItemController
        self.finderController = finderController
        isLaunchAtLoginEnabled = loginItemController.isEnabled
        lastFailureMessage = initialFailureMessage
        isShowingError = initialFailureMessage != nil
        refreshMicrophones()

        Task { [weak self, recordingService, transcriptionService] in
            await recordingService.setLevelHandler { [weak self] levels in
                await MainActor.run {
                    self?.audioLevels = levels
                }
            }
            await transcriptionService.setStatusHandler { [weak self] status in
                await MainActor.run {
                    guard let self else { return }
                    if let description = status.description {
                        self.transcriptionActivity = TranscriptionActivity(
                            description: description,
                            progress: status.progress
                        )
                    } else {
                        self.transcriptionActivity = nil
                    }
                    self.lastFailureMessage = status.lastFailureMessage
                }
            }
            guard let self, self.settings.transcriptionEnabled else { return }
            await transcriptionService.prepareModelIfNeeded()
        }

        settings.$transcriptionEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [transcriptionService] enabled in
                guard enabled else { return }
                Task {
                    await transcriptionService.prepareModelIfNeeded()
                }
            }
            .store(in: &cancellables)
        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var elapsedText: String {
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var saveFolderDisplayPath: String {
        storage.currentFolderURL.path(percentEncoded: false)
    }

    var selectedMicrophoneDeviceID: String? {
        settings.microphoneDeviceID.isEmpty ? nil : settings.microphoneDeviceID
    }

    var microphoneChoices: [MicrophoneDevice] {
        guard !settings.microphoneDeviceID.isEmpty,
              !availableMicrophones.contains(where: { $0.id == settings.microphoneDeviceID }) else {
            return availableMicrophones
        }
        return availableMicrophones + [
            MicrophoneDevice(
                id: settings.microphoneDeviceID,
                name: "選択したマイク（未接続）"
            )
        ]
    }

    func refreshMicrophones() {
        availableMicrophones = MicrophoneDevice.connected()
    }

    func toggleRecording() {
        guard recordingState != .starting, recordingState != .stopping else {
            return
        }

        if recordingState.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func toggleInputMonitoring() {
        guard !recordingState.isBusy, !isInputMonitoringTransitioning else {
            return
        }

        if isInputMonitoring {
            stopInputMonitoring()
        } else {
            startInputMonitoring()
        }
    }

    func stopInputMonitoring() {
        guard isInputMonitoring || isInputMonitoringTransitioning else {
            return
        }

        Task {
            await stopInputMonitoringAndWait()
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "録音の保存先を選択"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = storage.currentFolderURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            try storage.selectFolder(selectedURL)
            objectWillChange.send()
        } catch {
            show(error)
        }
    }

    func restoreDefaultSaveFolder() {
        storage.restoreDefaultFolder()
        objectWillChange.send()
    }

    func openSaveFolder() {
        do {
            try finderController.open(storage.accessibleFolderURL())
        } catch {
            show(error)
        }
    }

    func revealLastRecording() {
        do {
            guard let url = try storage.latestRecordingURL() else {
                throw FinderController.Error.recordingNotFound
            }
            finderController.reveal(url)
        } catch {
            show(error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            isLaunchAtLoginEnabled = loginItemController.isEnabled
        } catch {
            isLaunchAtLoginEnabled = loginItemController.isEnabled
            show(error)
        }
    }

    func retryLastFailedTranscription() {
        Task {
            do {
                try await transcriptionService.retryLastFailure(
                    destinationBookmark: storage.currentBookmarkData()
                )
                lastFailureMessage = nil
            } catch {
                show(error)
            }
        }
    }

    func dismissLastFailedTranscription() {
        Task {
            do {
                try await transcriptionService.dismissLastFailure()
                lastFailureMessage = nil
            } catch {
                show(error)
            }
        }
    }

    func dismissError() {
        isShowingError = false
        permissionSettingsURL = nil
    }

    func openPermissionSettings() {
        guard let permissionSettingsURL else { return }
        NSWorkspace.shared.open(permissionSettingsURL)
        dismissError()
    }

    private func startRecording() {
        recordingState = .starting
        Task {
            do {
                await stopInputMonitoringAndWait()
                let folder = try storage.recordingFolder(for: Date())
                try await recordingService.startRecording(
                    in: folder,
                    settings: RecordingLaunchSettings(
                        bitrate: settings.bitrate.rawValue,
                        microphoneGain: Float(settings.microphoneGain),
                        systemGain: Float(settings.systemGain),
                        microphoneDeviceID: selectedMicrophoneDeviceID,
                        transcriptionEnabled: settings.transcriptionEnabled,
                        keepTemporaryFiles: settings.keepTemporaryFiles
                    )
                )
                let startedAt = Date()
                recordingState = .recording(startedAt: startedAt)
                beginElapsedTimer(startedAt: startedAt)
            } catch {
                recordingState = .idle
                show(error)
            }
        }
    }

    private func stopRecording() {
        recordingState = .stopping
        elapsedTask?.cancel()
        elapsedTask = nil

        Task {
            do {
                _ = try await recordingService.stopRecording()
                recordingState = .idle
                audioLevels = AudioLevelSnapshot()
            } catch {
                recordingState = .idle
                audioLevels = AudioLevelSnapshot()
                lastFailureMessage = error.localizedDescription
                show(error)
            }
        }
    }

    private func startInputMonitoring() {
        inputMonitoringGeneration &+= 1
        let generation = inputMonitoringGeneration
        isInputMonitoringTransitioning = true
        audioLevels = AudioLevelSnapshot()

        inputMonitoringTask = Task {
            do {
                try await inputMonitor.start(
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    levelHandler: { [weak self] levels in
                        await self?.receiveInputMonitorLevels(
                            levels,
                            generation: generation
                        )
                    },
                    stopHandler: { [weak self] error in
                        await self?.inputMonitorDidStop(
                            with: error,
                            generation: generation
                        )
                    }
                )

                guard generation == inputMonitoringGeneration,
                      !recordingState.isBusy else {
                    await inputMonitor.stop()
                    return
                }
                isInputMonitoring = true
                isInputMonitoringTransitioning = false
            } catch {
                guard generation == inputMonitoringGeneration else {
                    return
                }
                isInputMonitoring = false
                isInputMonitoringTransitioning = false
                audioLevels = AudioLevelSnapshot()
                show(error)
            }
        }
    }

    private func stopInputMonitoringAndWait() async {
        inputMonitoringTask?.cancel()
        inputMonitoringTask = nil
        inputMonitoringGeneration &+= 1
        isInputMonitoring = false
        isInputMonitoringTransitioning = false
        audioLevels = AudioLevelSnapshot()
        await inputMonitor.stop()
    }

    private func receiveInputMonitorLevels(
        _ levels: AudioLevelSnapshot,
        generation: UInt64
    ) {
        guard generation == inputMonitoringGeneration,
              !recordingState.isBusy else {
            return
        }
        audioLevels = levels
    }

    private func inputMonitorDidStop(
        with error: any Error,
        generation: UInt64
    ) {
        guard generation == inputMonitoringGeneration else {
            return
        }
        inputMonitoringGeneration &+= 1
        isInputMonitoring = false
        isInputMonitoringTransitioning = false
        audioLevels = AudioLevelSnapshot()
        show(error)
    }

    private func beginElapsedTimer(startedAt: Date) {
        elapsedTask?.cancel()
        elapsedSeconds = 0
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            }
        }
    }

    private func show(_ error: any Error) {
        lastFailureMessage = error.localizedDescription
        permissionSettingsURL = (error as? CapturePermissionError)?.systemSettingsURL
        isShowingError = true
    }
}
