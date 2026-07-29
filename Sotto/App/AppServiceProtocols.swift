import Foundation

/// Recording-domain code supplies an implementation of this narrow bridge.
/// Keeping it here prevents the menu-bar UI from depending on capture internals.
protocol AppRecordingServicing: Sendable {
    typealias LevelHandler = @Sendable (AudioLevelSnapshot) async -> Void

    func setLevelHandler(_ handler: LevelHandler?) async

    func startRecording(
        in folderURL: URL,
        settings: RecordingLaunchSettings
    ) async throws

    /// Returns the final mixed recording when one was successfully finalized.
    func stopRecording() async throws -> URL?
}

struct AudioLevelSnapshot: Equatable, Sendable {
    var system: Float = 0
    var microphone: Float = 0
}

struct AppTranscriptionStatus: Sendable {
    let description: String?
    let progress: Double?
    let lastFailureMessage: String?
}

protocol AppTranscriptionServicing: Sendable {
    typealias StatusHandler = @Sendable (AppTranscriptionStatus) async -> Void

    func setStatusHandler(_ handler: StatusHandler?) async
    func prepareModelIfNeeded() async
    func retryLastFailure(destinationBookmark: Data?) async throws
    func dismissLastFailure() async throws
}

protocol AppInputMonitoring: Sendable {
    typealias LevelHandler = @Sendable (AudioLevelSnapshot) async -> Void
    typealias StopHandler = @Sendable (Error) async -> Void

    func start(
        microphoneDeviceID: String?,
        levelHandler: @escaping LevelHandler,
        stopHandler: @escaping StopHandler
    ) async throws

    func stop() async
}

extension SottoInputMonitor: AppInputMonitoring {}

struct RecordingLaunchSettings: Sendable {
    let bitrate: Int
    let microphoneGain: Float
    let systemGain: Float
    let microphoneDeviceID: String?
    let transcriptionEnabled: Bool
    let keepTemporaryFiles: Bool
}

enum AppServiceUnavailableError: LocalizedError {
    case recording
    case transcription
    case inputMonitoring

    var errorDescription: String? {
        switch self {
        case .recording:
            "録音サービスがまだ初期化されていません。"
        case .transcription:
            "再実行できる文字起こしジョブがありません。"
        case .inputMonitoring:
            "入力チェックサービスがまだ初期化されていません。"
        }
    }
}

actor UnavailableRecordingService: AppRecordingServicing {
    func setLevelHandler(_ handler: LevelHandler?) async {}

    func startRecording(
        in folderURL: URL,
        settings: RecordingLaunchSettings
    ) async throws {
        throw AppServiceUnavailableError.recording
    }

    func stopRecording() async throws -> URL? {
        throw AppServiceUnavailableError.recording
    }
}

actor UnavailableTranscriptionService: AppTranscriptionServicing {
    func setStatusHandler(_ handler: StatusHandler?) async {}

    func prepareModelIfNeeded() async {}

    func retryLastFailure(destinationBookmark: Data?) async throws {
        throw AppServiceUnavailableError.transcription
    }

    func dismissLastFailure() async throws {
        throw AppServiceUnavailableError.transcription
    }
}

actor UnavailableInputMonitor: AppInputMonitoring {
    func start(
        microphoneDeviceID: String?,
        levelHandler: @escaping LevelHandler,
        stopHandler: @escaping StopHandler
    ) async throws {
        throw AppServiceUnavailableError.inputMonitoring
    }

    func stop() async {}
}
