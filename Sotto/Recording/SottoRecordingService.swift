import AVFoundation
import Foundation

enum RecordingServiceError: LocalizedError {
    case alreadyRecording
    case diskSpaceUnavailable
    case insufficientDiskSpace(bytes: Int64)
    case cacheDirectoryUnavailable
    case coordinatorFailed(String)
    case segmentCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "すでに録音中です。"
        case .diskSpaceUnavailable:
            "保存先のディスク残量を確認できませんでした。"
        case let .insufficientDiskSpace(bytes):
            "ディスクの空き容量が1 GB未満です（残り \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）。"
        case .cacheDirectoryUnavailable:
            "文字起こし用一時ファイルの保存先を作成できませんでした。"
        case let .coordinatorFailed(message):
            "録音を正常に完了できませんでした: \(message)"
        case .segmentCreationFailed:
            "分割録音ファイルの保存先を作成できませんでした。"
        }
    }
}

/// Concrete bridge used by AppModel. It performs start preflight, generates stable
/// part names, and enqueues finalized synchronized stems for on-device transcription.
actor SottoRecordingService: AppRecordingServicing {
    private struct Segment: Sendable {
        let number: Int
        let destination: RecordingSegmentDestination
    }

    private let coordinator: RecordingCoordinator
    private let transcriptionQueue: TranscriptionQueue?
    private let fileManager: FileManager
    private let cacheRoot: URL
    private var segments: [Segment] = []
    private var recordingStartedAt: Date?
    private var launchSettings: RecordingLaunchSettings?
    private var destinationBookmark: Data?
    private var active = false

    init(
        transcriptionQueue: TranscriptionQueue? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.transcriptionQueue = transcriptionQueue
        self.fileManager = fileManager
        coordinator = RecordingCoordinator()
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw RecordingServiceError.cacheDirectoryUnavailable
        }
        cacheRoot = caches
            .appending(path: "Sotto", directoryHint: .isDirectory)
            .appending(path: "Transcription", directoryHint: .isDirectory)
    }

    func setLevelHandler(_ handler: LevelHandler?) async {
        await coordinator.setAudioLevelHandler { levels in
            Task {
                await handler?(levels)
            }
        }
    }

    func startRecording(
        in folderURL: URL,
        settings: RecordingLaunchSettings
    ) async throws {
        guard !active else { throw RecordingServiceError.alreadyRecording }
        try await CapturePermissionController.requestRequiredPermissions()
        try verifyDiskSpace(at: folderURL)

        let startedAt = Date()
        let baseName = Self.fileNameFormatter.string(from: startedAt)
        if settings.transcriptionEnabled {
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        }

        segments.removeAll()
        recordingStartedAt = startedAt
        launchSettings = settings
        destinationBookmark = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        active = true

        do {
            try await coordinator.start(
                settings: RecordingCoreSettings(
                    bitRate: settings.bitrate,
                    systemGain: settings.systemGain,
                    microphoneGain: settings.microphoneGain,
                    transcriptionEnabled: settings.transcriptionEnabled
                )
            ) { [weak self] segmentNumber in
                guard let self else { throw RecordingServiceError.segmentCreationFailed }
                return try await self.makeDestination(
                    folderURL: folderURL,
                    baseName: baseName,
                    segmentNumber: segmentNumber,
                    transcriptionEnabled: settings.transcriptionEnabled
                )
            }
        } catch {
            active = false
            segments.removeAll()
            recordingStartedAt = nil
            launchSettings = nil
            throw error
        }
    }

    func stopRecording() async throws -> URL? {
        guard active else { return nil }
        active = false
        await coordinator.stop()
        let finalState = await coordinator.state
        if case let .failed(message) = finalState {
            throw RecordingServiceError.coordinatorFailed(message)
        }

        let completedSegments = segments
        let settings = launchSettings
        let start = recordingStartedAt
        defer {
            segments.removeAll()
            recordingStartedAt = nil
            launchSettings = nil
            destinationBookmark = nil
        }

        if settings?.transcriptionEnabled == true,
           let settings,
           let start,
           let transcriptionQueue {
            var segmentStart = start
            for segment in completedSegments {
                guard let systemURL = segment.destination.systemStemURL,
                      let microphoneURL = segment.destination.microphoneStemURL else {
                    continue
                }
                let asset = AVURLAsset(url: segment.destination.mixedFileURL)
                let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                let mixedURL = segment.destination.mixedFileURL
                let job = TranscriptionJob(
                    recordingStartedAt: segmentStart,
                    duration: max(0, duration),
                    mixedAudioURL: mixedURL,
                    systemAudioURL: systemURL,
                    microphoneAudioURL: microphoneURL,
                    markdownURL: mixedURL.deletingPathExtension().appendingPathExtension("md"),
                    destinationBookmark: destinationBookmark,
                    keepTemporaryFiles: settings.keepTemporaryFiles
                )
                try await transcriptionQueue.enqueue(job)
                segmentStart.addTimeInterval(max(0, duration))
            }
        }
        return completedSegments.last?.destination.mixedFileURL
    }

    private func makeDestination(
        folderURL: URL,
        baseName: String,
        segmentNumber: Int,
        transcriptionEnabled: Bool
    ) throws -> RecordingSegmentDestination {
        let suffix = segmentNumber == 1 ? "" : String(format: "_part%02d", segmentNumber)
        let mixedURL = folderURL.appending(path: "\(baseName)\(suffix).m4a")
        let destination: RecordingSegmentDestination
        if transcriptionEnabled {
            let identifier = UUID().uuidString
            destination = RecordingSegmentDestination(
                mixedFileURL: mixedURL,
                systemStemURL: cacheRoot.appending(path: "\(identifier)-system.m4a"),
                microphoneStemURL: cacheRoot.appending(path: "\(identifier)-microphone.m4a")
            )
        } else {
            destination = RecordingSegmentDestination(
                mixedFileURL: mixedURL,
                systemStemURL: nil,
                microphoneStemURL: nil
            )
        }
        segments.append(Segment(number: segmentNumber, destination: destination))
        return destination
    }

    private func verifyDiskSpace(at folderURL: URL) throws {
        let values = try folderURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw RecordingServiceError.diskSpaceUnavailable
        }
        guard available >= 1_000_000_000 else {
            throw RecordingServiceError.insufficientDiskSpace(bytes: available)
        }
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()
}
