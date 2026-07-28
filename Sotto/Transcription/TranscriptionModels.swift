import Foundation

enum SpeakerLabel: String, Codable, Sendable {
    case meeting = "会議"
    case selfSpeaker = "自分"
}

struct TranscriptEntry: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let speaker: SpeakerLabel
    let text: String
}

enum TranscriptionPhase: String, Codable, Sendable {
    case queued
    case waitingForModel
    case transcribingSystem
    case transcribingMicrophone
    case merging
    case writingMarkdown
    case succeeded
    case failed

    var isTerminal: Bool {
        self == .succeeded || self == .failed
    }
}

struct TranscriptionJob: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let recordingStartedAt: Date
    let duration: TimeInterval
    let mixedAudioURL: URL
    let systemAudioURL: URL
    let microphoneAudioURL: URL
    let markdownURL: URL
    let destinationBookmark: Data?
    let keepTemporaryFiles: Bool
    let recordingTimeZoneIdentifier: String?

    var phase: TranscriptionPhase
    var progress: Double
    var failureReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        recordingStartedAt: Date,
        duration: TimeInterval,
        mixedAudioURL: URL,
        systemAudioURL: URL,
        microphoneAudioURL: URL,
        markdownURL: URL,
        destinationBookmark: Data?,
        keepTemporaryFiles: Bool,
        recordingTimeZoneIdentifier: String? = TimeZone.current.identifier
    ) {
        self.id = id
        self.recordingStartedAt = recordingStartedAt
        self.duration = duration
        self.mixedAudioURL = mixedAudioURL
        self.systemAudioURL = systemAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.markdownURL = markdownURL
        self.destinationBookmark = destinationBookmark
        self.keepTemporaryFiles = keepTemporaryFiles
        self.recordingTimeZoneIdentifier = recordingTimeZoneIdentifier
        self.phase = .queued
        self.progress = 0
        self.failureReason = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

enum TranscriptionError: LocalizedError, Sendable {
    case speechTranscriberUnavailable
    case japaneseLocaleUnsupported
    case modelUnsupported
    case modelInstallationIncomplete
    case missingTemporaryFile(URL)
    case emptyAudioFile(URL)
    case invalidDestinationBookmark
    case noFinalAnalysisTime(URL)

    var errorDescription: String? {
        switch self {
        case .speechTranscriberUnavailable:
            "このMacではSpeechTranscriberを利用できません。"
        case .japaneseLocaleUnsupported:
            "このMacではSpeechTranscriberの日本語モデルを利用できません。"
        case .modelUnsupported:
            "必要な日本語音声認識モデルはこのMacでサポートされていません。"
        case .modelInstallationIncomplete:
            "日本語音声認識モデルのインストールが完了しませんでした。"
        case .missingTemporaryFile(let url):
            "文字起こし用一時ファイルが見つかりません: \(url.lastPathComponent)"
        case .emptyAudioFile(let url):
            "文字起こし用一時ファイルに音声がありません: \(url.lastPathComponent)"
        case .invalidDestinationBookmark:
            "保存先フォルダへのアクセス権を復元できませんでした。設定で保存先を選び直してください。"
        case .noFinalAnalysisTime(let url):
            "音声を最後まで解析できませんでした: \(url.lastPathComponent)"
        }
    }
}
