import Foundation

actor TranscriptionQueue {
    typealias JobsHandler = @Sendable ([TranscriptionJob]) async -> Void
    typealias StemRemover = @Sendable (URL) throws -> Void

    private let store: TranscriptionJobStore
    private let modelManager: SpeechModelManager
    private let merger = TranscriptMerger()
    private let markdownWriter = MarkdownTranscriptWriter()
    private let fileManager: FileManager
    private let stemRemover: StemRemover
    private var jobs: [TranscriptionJob]
    private var processorTask: Task<Void, Never>?
    private var processorRestartRequested = false
    private var jobsHandler: JobsHandler?

    init(
        store: TranscriptionJobStore,
        modelManager: SpeechModelManager,
        fileManager: FileManager = .default,
        stemRemover: StemRemover? = nil
    ) throws {
        self.store = store
        self.modelManager = modelManager
        self.fileManager = fileManager
        self.stemRemover = stemRemover ?? { url in
            try FileManager.default.removeItem(at: url)
        }
        self.jobs = try store.load().map { job in
            var recovered = job
            if recovered.stemCleanupState == nil {
                recovered.stemCleanupState = recovered.keepTemporaryFiles ? .retained : .pending
                recovered.stemCleanupFailureReason = nil
            }
            if !job.phase.isTerminal {
                recovered.phase = .queued
                recovered.progress = 0
                recovered.failureReason = nil
                recovered.updatedAt = Date()
            }
            return recovered
        }
        try store.save(jobs)
    }

    func setJobsHandler(_ handler: JobsHandler?) async {
        jobsHandler = handler
        await handler?(jobs)
    }

    func allJobs() -> [TranscriptionJob] {
        jobs
    }

    func enqueue(_ job: TranscriptionJob) async throws {
        try await enqueue([job])
    }

    func enqueue(_ newJobs: [TranscriptionJob]) async throws {
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        try await persistAndPublish()
        startProcessorIfNeeded()
    }

    func recordFailed(_ newJobs: [TranscriptionJob], reason: String) async throws {
        guard !newJobs.isEmpty else { return }
        let now = Date()
        jobs.append(
            contentsOf: newJobs.map { job in
                var failed = job
                failed.phase = .failed
                failed.progress = 0
                failed.failureReason = reason
                failed.updatedAt = now
                return failed
            }
        )
        try await persistAndPublish()
    }

    func resumePendingJobs() {
        startProcessorIfNeeded()
    }

    func retry(jobID: UUID, destinationBookmark: Data? = nil) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].phase == .failed else { return }
        if let destinationBookmark {
            try validateDestinationBookmark(destinationBookmark, for: jobs[index])
            jobs[index] = replacingDestinationBookmark(
                in: jobs[index],
                with: destinationBookmark
            )
        }
        jobs[index].phase = .queued
        jobs[index].progress = 0
        jobs[index].failureReason = nil
        jobs[index].updatedAt = Date()
        try await persistAndPublish()
        startProcessorIfNeeded()
    }

    func retryStemCleanup(jobID: UUID) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].phase == .succeeded,
              !jobs[index].keepTemporaryFiles,
              jobs[index].stemCleanupState == .failed else {
            return
        }
        jobs[index].stemCleanupState = .pending
        jobs[index].stemCleanupFailureReason = nil
        jobs[index].updatedAt = Date()
        try await persistAndPublish()
        startProcessorIfNeeded()
    }

    private func startProcessorIfNeeded() {
        guard processorTask == nil else {
            processorRestartRequested = true
            return
        }
        guard jobs.contains(where: {
            $0.phase == .queued || isStemCleanupEligible($0)
        }) else { return }

        processorRestartRequested = false
        processorTask = Task { [weak self] in
            await self?.processPendingJobs()
        }
    }

    private func processPendingJobs() async {
        var attemptedCleanupIDs: Set<UUID> = []
        while true {
            if let jobID = jobs.first(where: { $0.phase == .queued })?.id {
                await process(jobID: jobID)
                continue
            }
            guard let cleanupID = jobs.first(where: {
                isStemCleanupEligible($0) && !attemptedCleanupIDs.contains($0.id)
            })?.id else {
                break
            }
            attemptedCleanupIDs.insert(cleanupID)
            await processStemCleanup(jobID: cleanupID)
        }
        processorTask = nil
        if processorRestartRequested {
            processorRestartRequested = false
            startProcessorIfNeeded()
        }
    }

    private func process(jobID: UUID) async {
        do {
            try validateTemporaryFiles(jobID: jobID)

            try await transition(jobID: jobID, phase: .waitingForModel, progress: 0)
            try await modelManager.ensureJapaneseModel { [weak self] progress in
                await self?.updateProgress(
                    jobID: jobID,
                    phase: .waitingForModel,
                    progress: min(max(progress * 0.1, 0), 0.1)
                )
            }

            guard let job = jobs.first(where: { $0.id == jobID }) else { return }
            let transcriber = SpeechFileTranscriber(modelManager: modelManager)

            try await transition(jobID: jobID, phase: .transcribingSystem, progress: 0.1)
            let system = try await transcriber.transcribe(
                audioURL: job.systemAudioURL,
                speaker: .system
            ) { [weak self] progress in
                await self?.updateProgress(
                    jobID: jobID,
                    phase: .transcribingSystem,
                    progress: 0.1 + progress * 0.4
                )
            }

            try await transition(jobID: jobID, phase: .transcribingMicrophone, progress: 0.5)
            let selfSpeaker = try await transcriber.transcribe(
                audioURL: job.microphoneAudioURL,
                speaker: .selfSpeaker
            ) { [weak self] progress in
                await self?.updateProgress(
                    jobID: jobID,
                    phase: .transcribingMicrophone,
                    progress: 0.5 + progress * 0.4
                )
            }

            try await transition(jobID: jobID, phase: .merging, progress: 0.92)
            let merged = merger.merge(system: system, selfSpeaker: selfSpeaker)

            try await transition(jobID: jobID, phase: .writingMarkdown, progress: 0.96)
            try withDestinationAccess(for: job) {
                try fileManager.createDirectory(
                    at: job.markdownURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try markdownWriter.write(
                    recordingStartedAt: job.recordingStartedAt,
                    duration: job.duration,
                    entries: merged,
                    to: job.markdownURL,
                    timeZone: job.recordingTimeZoneIdentifier
                        .flatMap(TimeZone.init(identifier:)) ?? .current
                )
            }

            // Persist success before cleanup. If persistence fails, both stem files
            // remain available and the durable pending cleanup state is retried.
            try await transition(jobID: jobID, phase: .succeeded, progress: 1)
        } catch {
            await fail(jobID: jobID, error: error)
        }
    }

    private func processStemCleanup(jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              isStemCleanupEligible(jobs[index]) else {
            return
        }
        let stemURLs = [
            jobs[index].systemAudioURL,
            jobs[index].microphoneAudioURL,
        ]
        var failures: [String] = []
        for url in stemURLs {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try stemRemover(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        jobs[index].stemCleanupState = failures.isEmpty ? .completed : .failed
        jobs[index].stemCleanupFailureReason = failures.isEmpty
            ? nil
            : "文字起こし用一時ファイルの削除に失敗しました: \(failures.joined(separator: ", "))"
        jobs[index].updatedAt = Date()
        do {
            try await persistAndPublish()
        } catch {
            jobs[index].stemCleanupFailureReason = [
                jobs[index].stemCleanupFailureReason,
                "cleanup状態の保存に失敗しました: \(error.localizedDescription)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            await jobsHandler?(jobs)
        }
    }

    private func isStemCleanupEligible(_ job: TranscriptionJob) -> Bool {
        guard job.phase == .succeeded, !job.keepTemporaryFiles else { return false }
        return job.stemCleanupState == .pending || job.stemCleanupState == .failed
    }

    private func validateTemporaryFiles(jobID: UUID) throws {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        for url in [job.systemAudioURL, job.microphoneAudioURL] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw TranscriptionError.missingTemporaryFile(url)
            }
        }
    }

    private func withDestinationAccess<T>(
        for job: TranscriptionJob,
        operation: () throws -> T
    ) throws -> T {
        guard let bookmark = job.destinationBookmark else {
            return try operation()
        }
        var stale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, scopedURL.startAccessingSecurityScopedResource() else {
            throw TranscriptionError.invalidDestinationBookmark
        }
        defer { scopedURL.stopAccessingSecurityScopedResource() }
        return try operation()
    }

    private func validateDestinationBookmark(
        _ bookmark: Data,
        for job: TranscriptionJob
    ) throws {
        var stale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else {
            throw TranscriptionError.invalidDestinationBookmark
        }

        let selectedFolder = scopedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let markdownFolder = job.markdownURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let selectedPath = selectedFolder.path
        let markdownPath = markdownFolder.path
        guard markdownPath == selectedPath
                || markdownPath.hasPrefix(selectedPath.hasSuffix("/")
                    ? selectedPath
                    : selectedPath + "/") else {
            throw TranscriptionError.destinationBookmarkMismatch
        }
    }

    private func transition(
        jobID: UUID,
        phase: TranscriptionPhase,
        progress: Double
    ) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].phase = phase
        jobs[index].progress = min(max(progress, 0), 1)
        jobs[index].failureReason = nil
        jobs[index].updatedAt = Date()
        try await persistAndPublish()
    }

    private func updateProgress(
        jobID: UUID,
        phase: TranscriptionPhase,
        progress: Double
    ) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].phase == phase else { return }
        jobs[index].progress = min(max(progress, 0), 1)
        jobs[index].updatedAt = Date()
        await jobsHandler?(jobs)
    }

    private func fail(jobID: UUID, error: Error) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].phase = .failed
        jobs[index].failureReason = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        jobs[index].updatedAt = Date()
        do {
            try await persistAndPublish()
        } catch {
            jobs[index].failureReason = [
                jobs[index].failureReason,
                "ジョブ状態の保存にも失敗しました: \(error.localizedDescription)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            await jobsHandler?(jobs)
        }
    }

    private func persistAndPublish() async throws {
        try store.save(jobs)
        await jobsHandler?(jobs)
    }

    private func replacingDestinationBookmark(
        in job: TranscriptionJob,
        with bookmark: Data
    ) -> TranscriptionJob {
        var replacement = TranscriptionJob(
            id: job.id,
            recordingStartedAt: job.recordingStartedAt,
            duration: job.duration,
            mixedAudioURL: job.mixedAudioURL,
            systemAudioURL: job.systemAudioURL,
            microphoneAudioURL: job.microphoneAudioURL,
            markdownURL: job.markdownURL,
            destinationBookmark: bookmark,
            keepTemporaryFiles: job.keepTemporaryFiles,
            recordingTimeZoneIdentifier: job.recordingTimeZoneIdentifier
        )
        replacement.phase = job.phase
        replacement.progress = job.progress
        replacement.failureReason = job.failureReason
        replacement.stemCleanupState = job.stemCleanupState
        replacement.stemCleanupFailureReason = job.stemCleanupFailureReason
        replacement.createdAt = job.createdAt
        replacement.updatedAt = job.updatedAt
        return replacement
    }
}
