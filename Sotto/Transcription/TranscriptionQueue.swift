import Foundation

actor TranscriptionQueue {
    typealias JobsHandler = @Sendable ([TranscriptionJob]) async -> Void

    private let store: TranscriptionJobStore
    private let modelManager: SpeechModelManager
    private let merger = TranscriptMerger()
    private let markdownWriter = MarkdownTranscriptWriter()
    private let fileManager: FileManager
    private var jobs: [TranscriptionJob]
    private var processorTask: Task<Void, Never>?
    private var jobsHandler: JobsHandler?

    init(
        store: TranscriptionJobStore,
        modelManager: SpeechModelManager,
        fileManager: FileManager = .default
    ) throws {
        self.store = store
        self.modelManager = modelManager
        self.fileManager = fileManager
        self.jobs = try store.load().map { job in
            var recovered = job
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
        jobs.append(job)
        try await persistAndPublish()
        startProcessorIfNeeded()
    }

    func resumePendingJobs() {
        startProcessorIfNeeded()
    }

    func retry(jobID: UUID, destinationBookmark: Data? = nil) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].phase == .failed else { return }
        if let destinationBookmark {
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

    private func startProcessorIfNeeded() {
        guard processorTask == nil else { return }
        guard jobs.contains(where: { $0.phase == .queued }) else { return }

        processorTask = Task { [weak self] in
            await self?.processPendingJobs()
        }
    }

    private func processPendingJobs() async {
        while let jobID = jobs.first(where: { $0.phase == .queued })?.id {
            await process(jobID: jobID)
        }
        processorTask = nil
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
            let meeting = try await transcriber.transcribe(
                audioURL: job.systemAudioURL,
                speaker: .meeting
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
            let merged = merger.merge(meeting: meeting, selfSpeaker: selfSpeaker)

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
            // remain available for recovery and manual retry.
            try await transition(jobID: jobID, phase: .succeeded, progress: 1)
            if !job.keepTemporaryFiles {
                try? fileManager.removeItem(at: job.systemAudioURL)
                try? fileManager.removeItem(at: job.microphoneAudioURL)
            }
        } catch {
            await fail(jobID: jobID, error: error)
        }
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
        replacement.createdAt = job.createdAt
        replacement.updatedAt = job.updatedAt
        return replacement
    }
}
