import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    enum Bitrate: Int, CaseIterable, Identifiable {
        case kbps96 = 96_000
        case kbps128 = 128_000
        case kbps192 = 192_000
        case kbps256 = 256_000

        var id: Int { rawValue }

        var displayName: String {
            "\(rawValue / 1_000) kbps"
        }
    }

    @Published var bitrate: Bitrate {
        didSet { defaults.set(bitrate.rawValue, forKey: Keys.bitrate) }
    }

    @Published var microphoneGain: Double {
        didSet { defaults.set(microphoneGain, forKey: Keys.microphoneGain) }
    }

    @Published var systemGain: Double {
        didSet { defaults.set(systemGain, forKey: Keys.systemGain) }
    }

    @Published var transcriptionEnabled: Bool {
        didSet { defaults.set(transcriptionEnabled, forKey: Keys.transcriptionEnabled) }
    }

    @Published var keepTemporaryFiles: Bool {
        didSet { defaults.set(keepTemporaryFiles, forKey: Keys.keepTemporaryFiles) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedBitrate = defaults.integer(forKey: Keys.bitrate)
        bitrate = Bitrate(rawValue: savedBitrate) ?? .kbps192
        microphoneGain = defaults.object(forKey: Keys.microphoneGain) as? Double ?? 0.7
        systemGain = defaults.object(forKey: Keys.systemGain) as? Double ?? 0.7
        transcriptionEnabled = defaults.object(forKey: Keys.transcriptionEnabled) as? Bool ?? true
        keepTemporaryFiles = defaults.object(forKey: Keys.keepTemporaryFiles) as? Bool ?? false
    }

    private enum Keys {
        static let bitrate = "audio.bitrate"
        static let microphoneGain = "audio.microphoneGain"
        static let systemGain = "audio.systemGain"
        static let transcriptionEnabled = "transcription.enabled"
        static let keepTemporaryFiles = "transcription.keepTemporaryFiles"
    }
}
