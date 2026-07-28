import Foundation
import XCTest
@testable import Sotto

final class TranscriptionRecoveryTests: XCTestCase {
    func testFailedStemCleanupIsPersistedAndRetriedAfterRestartWithoutDeletingMixedFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("jobs.json")
        let mixedURL = directory.appendingPathComponent("recording.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        for url in [mixedURL, systemURL, microphoneURL] {
            try Data("audio".utf8).write(to: url)
        }

        var job = makeJob(
            mixedURL: mixedURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
        job.phase = .succeeded
        job.progress = 1
        job.stemCleanupState = .pending
        let store = try TranscriptionJobStore(storeURL: storeURL)
        try store.save([job])

        let remover = FailingStemRemover()
        let firstQueue = try TranscriptionQueue(
            store: store,
            modelManager: SpeechModelManager(),
            stemRemover: { url in
                try remover.remove(url)
            }
        )
        await firstQueue.resumePendingJobs()
        try await waitUntil {
            await firstQueue.allJobs().first?.stemCleanupState == .failed
        }

        let failedOnDisk = try store.load().first
        XCTAssertEqual(failedOnDisk?.stemCleanupState, .failed)
        XCTAssertNotNil(failedOnDisk?.stemCleanupFailureReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(remover.attemptedURLs.contains(mixedURL))

        remover.shouldFail = false
        let restartedQueue = try TranscriptionQueue(
            store: store,
            modelManager: SpeechModelManager(),
            stemRemover: { url in
                try remover.remove(url)
            }
        )
        await restartedQueue.resumePendingJobs()
        try await waitUntil {
            await restartedQueue.allJobs().first?.stemCleanupState == .completed
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertEqual(try store.load().first?.stemCleanupState, .completed)
    }

    func testCleanupRetryRequestedFromJobsHandlerRunsAfterActiveProcessorFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("jobs.json")
        let mixedURL = directory.appendingPathComponent("recording.m4a")
        let systemURL = directory.appendingPathComponent("system.m4a")
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")
        for url in [mixedURL, systemURL, microphoneURL] {
            try Data("audio".utf8).write(to: url)
        }

        var job = makeJob(
            mixedURL: mixedURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
        job.phase = .succeeded
        job.progress = 1
        job.stemCleanupState = .pending
        let store = try TranscriptionJobStore(storeURL: storeURL)
        try store.save([job])

        let remover = FailOnceStemRemover()
        let queue = try TranscriptionQueue(
            store: store,
            modelManager: SpeechModelManager(),
            stemRemover: { url in
                try remover.remove(url)
            }
        )
        await queue.setJobsHandler { jobs in
            guard let failed = jobs.first(where: {
                $0.stemCleanupState == .failed
            }) else {
                return
            }
            try? await queue.retryStemCleanup(jobID: failed.id)
        }

        await queue.resumePendingJobs()
        try await waitUntil {
            await queue.allJobs().first?.stemCleanupState == .completed
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(remover.attemptedURLs.contains(mixedURL))
        XCTAssertEqual(try store.load().first?.stemCleanupState, .completed)
    }

    func testRetryRejectsBookmarkOutsideMarkdownAncestor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalFolder = directory.appendingPathComponent("original", isDirectory: true)
        let unrelatedFolder = directory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originalFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelatedFolder,
            withIntermediateDirectories: true
        )

        var job = makeJob(
            mixedURL: originalFolder.appendingPathComponent("recording.m4a"),
            systemURL: directory.appendingPathComponent("system.m4a"),
            microphoneURL: directory.appendingPathComponent("microphone.m4a")
        )
        job.phase = .failed
        job.failureReason = "test"
        let store = try TranscriptionJobStore(
            storeURL: directory.appendingPathComponent("jobs.json")
        )
        try store.save([job])
        let queue = try TranscriptionQueue(
            store: store,
            modelManager: SpeechModelManager()
        )
        let unrelatedBookmark = try unrelatedFolder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        do {
            try await queue.retry(
                jobID: job.id,
                destinationBookmark: unrelatedBookmark
            )
            XCTFail("祖先でない保存先bookmarkを受理しました。")
        } catch TranscriptionError.destinationBookmarkMismatch {
            // Expected.
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }

        let unchanged = await queue.allJobs().first
        XCTAssertEqual(unchanged?.phase, .failed)
        XCTAssertEqual(unchanged?.destinationBookmark, job.destinationBookmark)
    }

    func testFinalizeFailurePersistsRecoverableFailedJobAndClearsServiceContext() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingFolder = directory.appendingPathComponent("recordings", isDirectory: true)
        let cacheFolder = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingFolder,
            withIntermediateDirectories: true
        )
        let store = try TranscriptionJobStore(
            storeURL: directory.appendingPathComponent("jobs.json")
        )
        let queue = try TranscriptionQueue(
            store: store,
            modelManager: SpeechModelManager()
        )
        let coordinator = FinalizeFailingCoordinator()
        let service = try SottoRecordingService(
            transcriptionQueue: queue,
            coordinator: coordinator,
            cacheRoot: cacheFolder,
            permissionRequester: {}
        )
        let settings = RecordingLaunchSettings(
            bitrate: 128_000,
            microphoneGain: 0.7,
            systemGain: 0.7,
            transcriptionEnabled: true,
            keepTemporaryFiles: false
        )

        try await service.startRecording(in: recordingFolder, settings: settings)
        let capturedDestination = await coordinator.destination
        let destination = try XCTUnwrap(capturedDestination)
        for url in [
            destination.mixedFileURL,
            try XCTUnwrap(destination.systemStemURL),
            try XCTUnwrap(destination.microphoneStemURL),
        ] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("partial".utf8).write(to: url)
        }

        do {
            _ = try await service.stopRecording()
            XCTFail("finalize失敗が成功扱いになりました。")
        } catch RecordingServiceError.coordinatorFailed {
            // Expected.
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }

        let recoveredJobs = await queue.allJobs()
        let recoveryJob = try XCTUnwrap(recoveredJobs.first)
        XCTAssertEqual(recoveryJob.phase, .failed)
        XCTAssertEqual(recoveryJob.mixedAudioURL, destination.mixedFileURL)
        XCTAssertEqual(recoveryJob.systemAudioURL, destination.systemStemURL)
        XCTAssertEqual(recoveryJob.microphoneAudioURL, destination.microphoneStemURL)
        XCTAssertEqual(recoveryJob.stemCleanupState, .pending)
        XCTAssertTrue(
            recoveryJob.failureReason?.contains("録音ファイルの確定に失敗") == true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.mixedFileURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recoveryJob.systemAudioURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recoveryJob.microphoneAudioURL.path)
        )
        let secondStopResult = try await service.stopRecording()
        XCTAssertNil(secondStopResult)

        // A failed stop must not leave the service permanently "active".
        try await service.startRecording(in: recordingFolder, settings: settings)
    }

    private func makeJob(
        mixedURL: URL,
        systemURL: URL,
        microphoneURL: URL
    ) -> TranscriptionJob {
        TranscriptionJob(
            recordingStartedAt: Date(),
            duration: 1,
            mixedAudioURL: mixedURL,
            systemAudioURL: systemURL,
            microphoneAudioURL: microphoneURL,
            markdownURL: mixedURL.deletingPathExtension().appendingPathExtension("md"),
            destinationBookmark: nil,
            keepTemporaryFiles: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
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

private final class FailingStemRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var failureEnabled = true
    private var attempts: [URL] = []

    var shouldFail: Bool {
        get { lock.withLock { failureEnabled } }
        set { lock.withLock { failureEnabled = newValue } }
    }

    var attemptedURLs: [URL] {
        lock.withLock { attempts }
    }

    func remove(_ url: URL) throws {
        let fails = lock.withLock {
            attempts.append(url)
            return failureEnabled
        }
        if fails {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class FailOnceStemRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures = 1
    private var attempts: [URL] = []

    var attemptedURLs: [URL] {
        lock.withLock { attempts }
    }

    func remove(_ url: URL) throws {
        let shouldFail = lock.withLock {
            attempts.append(url)
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

private actor FinalizeFailingCoordinator: RecordingCoordinating {
    private(set) var destination: RecordingSegmentDestination?
    private var state: RecordingState = .idle

    func setAudioLevelHandler(_ handler: RecordingCoordinator.AudioLevelHandler?) {}

    func start(
        settings: RecordingCoreSettings,
        segmentProvider: @escaping RecordingCoordinator.SegmentProvider
    ) async throws {
        let destination = try await segmentProvider(1)
        self.destination = destination
        state = .recording(
            startedAt: Date(),
            segment: 1,
            fileURL: destination.mixedFileURL
        )
    }

    func stop() {
        state = .failed(message: "injected finalize failure")
    }

    func currentState() -> RecordingState {
        state
    }
}
