import AVFoundation
import Foundation

enum RecordingServiceError: LocalizedError {
    case alreadyRecording
    case diskSpaceUnavailable
    case insufficientDiskSpace(bytes: Int64)
    case cacheDirectoryUnavailable
    case coordinatorFailed(String)
    case coordinatorFailedAndRecoveryFailed(recording: String, recovery: String)
    case segmentCreationFailed
    case transcriptionQueueUnavailable

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
        case let .coordinatorFailedAndRecoveryFailed(recording, recovery):
            "録音を正常に完了できず、一時音声の回復情報も保存できませんでした。録音: \(recording) 回復情報: \(recovery)"
        case .segmentCreationFailed:
            "分割録音ファイルの保存先を作成できませんでした。"
        case .transcriptionQueueUnavailable:
            "文字起こし用一時ファイルの回復情報を保存できないため、録音を開始できません。"
        }
    }
}

protocol RecordingCoordinating: Sendable {
    func setAudioLevelHandler(_ handler: RecordingCoordinator.AudioLevelHandler?) async
    func start(
        settings: RecordingCoreSettings,
        segmentProvider: @escaping RecordingCoordinator.SegmentProvider
    ) async throws
    func stop() async
    func currentState() async -> RecordingState
}

extension RecordingCoordinator: RecordingCoordinating {
    func currentState() -> RecordingState {
        state
    }
}

/// Concrete bridge used by AppModel. It performs start preflight, generates stable
/// part names, and enqueues finalized synchronized stems for on-device transcription.
actor SottoRecordingService: AppRecordingServicing {
    private struct Segment: Sendable {
        let number: Int
        let destination: RecordingSegmentDestination
    }

    typealias PermissionRequester = @Sendable () async throws -> Void

    private let coordinator: any RecordingCoordinating
    private let transcriptionQueue: TranscriptionQueue?
    private let fileManager: FileManager
    private let cacheRoot: URL
    private let permissionRequester: PermissionRequester
    private var segments: [Segment] = []
    private var recordingStartedAt: Date?
    private var launchSettings: RecordingLaunchSettings?
    private var destinationBookmark: Data?
    private var active = false

    init(
        transcriptionQueue: TranscriptionQueue? = nil,
        fileManager: FileManager = .default,
        coordinator: any RecordingCoordinating = RecordingCoordinator(),
        cacheRoot: URL? = nil,
        permissionRequester: @escaping PermissionRequester = {
            try await CapturePermissionController.requestRequiredPermissions()
        }
    ) throws {
        self.transcriptionQueue = transcriptionQueue
        self.fileManager = fileManager
        self.coordinator = coordinator
        self.permissionRequester = permissionRequester
        if let cacheRoot {
            self.cacheRoot = cacheRoot
        } else {
            guard let caches = fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first else {
                throw RecordingServiceError.cacheDirectoryUnavailable
            }
            self.cacheRoot = caches
                .appending(path: "Sotto", directoryHint: .isDirectory)
                .appending(path: "Transcription", directoryHint: .isDirectory)
        }
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
        guard !settings.transcriptionEnabled || transcriptionQueue != nil else {
            throw RecordingServiceError.transcriptionQueueUnavailable
        }
        try await permissionRequester()
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
            let recoveryError = await persistFailedSegments(
                reason: "録音の開始処理に失敗しました: \(error.localizedDescription)"
            )
            clearRecordingContext()
            if let recoveryError {
                throw RecordingServiceError.coordinatorFailedAndRecoveryFailed(
                    recording: error.localizedDescription,
                    recovery: recoveryError.localizedDescription
                )
            }
            throw error
        }
    }

    func stopRecording() async throws -> URL? {
        guard active else { return nil }
        active = false
        await coordinator.stop()
        let finalState = await coordinator.currentState()
        let completedSegments = segments
        let settings = launchSettings
        let start = recordingStartedAt
        let bookmark = destinationBookmark
        defer { clearRecordingContext() }

        let jobs = await makeTranscriptionJobs(
            segments: completedSegments,
            settings: settings,
            start: start,
            destinationBookmark: bookmark
        )

        if case let .failed(message) = finalState {
            if let transcriptionQueue, !jobs.isEmpty {
                do {
                    try await transcriptionQueue.recordFailed(
                        jobs,
                        reason: "録音ファイルの確定に失敗しました: \(message)"
                    )
                } catch {
                    throw RecordingServiceError.coordinatorFailedAndRecoveryFailed(
                        recording: message,
                        recovery: error.localizedDescription
                    )
                }
            }
            throw RecordingServiceError.coordinatorFailed(message)
        }

        if let transcriptionQueue, !jobs.isEmpty {
            try await transcriptionQueue.enqueue(jobs)
        }
        return completedSegments.last?.destination.mixedFileURL
    }

    private func persistFailedSegments(reason: String) async -> Error? {
        let jobs = await makeTranscriptionJobs(
            segments: segments,
            settings: launchSettings,
            start: recordingStartedAt,
            destinationBookmark: destinationBookmark
        )
        guard !jobs.isEmpty, let transcriptionQueue else { return nil }
        do {
            try await transcriptionQueue.recordFailed(jobs, reason: reason)
            return nil
        } catch {
            return error
        }
    }

    private func makeTranscriptionJobs(
        segments: [Segment],
        settings: RecordingLaunchSettings?,
        start: Date?,
        destinationBookmark: Data?
    ) async -> [TranscriptionJob] {
        guard settings?.transcriptionEnabled == true,
              let settings,
              let start else {
            return []
        }
        var result: [TranscriptionJob] = []
        var segmentStart = start
        for segment in segments {
            guard let systemURL = segment.destination.systemStemURL,
                  let microphoneURL = segment.destination.microphoneStemURL else {
                continue
            }
            let mixedURL = segment.destination.mixedFileURL
            let asset = AVURLAsset(url: mixedURL)
            let loadedDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
            result.append(
                TranscriptionJob(
                    recordingStartedAt: segmentStart,
                    duration: duration,
                    mixedAudioURL: mixedURL,
                    systemAudioURL: systemURL,
                    microphoneAudioURL: microphoneURL,
                    markdownURL: mixedURL.deletingPathExtension().appendingPathExtension("md"),
                    destinationBookmark: destinationBookmark,
                    keepTemporaryFiles: settings.keepTemporaryFiles
                )
            )
            segmentStart.addTimeInterval(duration)
        }
        return result
    }

    private func clearRecordingContext() {
        active = false
        segments.removeAll()
        recordingStartedAt = nil
        launchSettings = nil
        destinationBookmark = nil
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
