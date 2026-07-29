import Foundation

enum RecordingState: Sendable, Equatable {
    case idle
    case preflighting
    case starting(segment: Int)
    case recording(startedAt: Date, segment: Int, fileURL: URL)
    case rollingOver(completedSegment: Int)
    case stopping
    case finalizing
    case failed(message: String)

    var isActivelyRecording: Bool {
        switch self {
        case .starting, .recording, .rollingOver:
            true
        default:
            false
        }
    }
}

struct RecordingSegmentDestination: Sendable {
    let mixedFileURL: URL
    let systemStemURL: URL?
    let microphoneStemURL: URL?
}

struct RecordingCoreSettings: Sendable {
    var bitRate: Int = 128_000
    var systemGain: Float = 0.7
    var microphoneGain: Float = 0.7
    var microphoneDeviceID: String?
    var transcriptionEnabled = true
}
