import Foundation

actor SottoTranscriptionService: AppTranscriptionServicing {
    private let queue: TranscriptionQueue
    private let modelManager: SpeechModelManager
    private var statusHandler: StatusHandler?
    private var jobs: [TranscriptionJob] = []
    private var modelPreparation: (description: String, progress: Double?)?
    private var modelPreparationTask: Task<Void, Never>?

    init(queue: TranscriptionQueue, modelManager: SpeechModelManager) {
        self.queue = queue
        self.modelManager = modelManager
    }

    func setStatusHandler(_ handler: StatusHandler?) async {
        statusHandler = handler
        await queue.setJobsHandler { [weak self] jobs in
            await self?.receive(jobs)
        }
        jobs = await queue.allJobs()
        await publish()
        await queue.resumePendingJobs()
    }

    func prepareModelIfNeeded() {
        guard modelPreparationTask == nil else { return }
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            await self.setModelPreparation(description: "日本語モデルを確認中…", progress: nil)
            do {
                try await self.modelManager.ensureJapaneseModel { [weak self] progress in
                    await self?.setModelPreparation(
                        description: "日本語モデルを準備中…",
                        progress: progress
                    )
                }
                await self.clearModelPreparation()
            } catch {
                await self.finishModelPreparation(with: error)
            }
        }
    }

    func retryLastFailure(destinationBookmark: Data?) async throws {
        if let failed = jobs
            .filter({ $0.phase == .failed })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            try await queue.retry(
                jobID: failed.id,
                destinationBookmark: destinationBookmark
            )
            return
        }
        if let cleanupFailure = jobs
            .filter({ $0.stemCleanupState == .failed })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            try await queue.retryStemCleanup(jobID: cleanupFailure.id)
            return
        }
        throw AppServiceUnavailableError.transcription
    }

    private func receive(_ jobs: [TranscriptionJob]) async {
        self.jobs = jobs
        await publish()
    }

    private func setModelPreparation(
        description: String,
        progress: Double?
    ) async {
        modelPreparation = (description, progress)
        await publish()
    }

    private func clearModelPreparation() async {
        modelPreparation = nil
        modelPreparationTask = nil
        await publish()
    }

    private func finishModelPreparation(with error: Error) async {
        modelPreparation = nil
        modelPreparationTask = nil
        await statusHandler?(
            AppTranscriptionStatus(
                description: nil,
                progress: nil,
                lastFailureMessage: error.localizedDescription
            )
        )
    }

    private func publish() async {
        let active = jobs
            .filter { !$0.phase.isTerminal }
            .min(by: { $0.createdAt < $1.createdAt })
        let failure = jobs
            .filter {
                $0.phase == .failed || $0.stemCleanupState == .failed
            }
            .max(by: { $0.updatedAt < $1.updatedAt })
            .flatMap { job in
                job.phase == .failed
                    ? job.failureReason
                    : job.stemCleanupFailureReason
            }

        if let active {
            await statusHandler?(
                AppTranscriptionStatus(
                    description: description(for: active.phase),
                    progress: active.progress,
                    lastFailureMessage: failure
                )
            )
        } else if let modelPreparation {
            await statusHandler?(
                AppTranscriptionStatus(
                    description: modelPreparation.description,
                    progress: modelPreparation.progress,
                    lastFailureMessage: failure
                )
            )
        } else {
            await statusHandler?(
                AppTranscriptionStatus(
                    description: nil,
                    progress: nil,
                    lastFailureMessage: failure
                )
            )
        }
    }

    private func description(for phase: TranscriptionPhase) -> String {
        switch phase {
        case .queued:
            "文字起こし待機中"
        case .waitingForModel:
            "日本語モデルを準備中…"
        case .transcribingSystem:
            "システム音声を文字起こし中…"
        case .transcribingMicrophone:
            "マイク音声を文字起こし中…"
        case .merging:
            "話者ラベルを統合中…"
        case .writingMarkdown:
            "Markdownを保存中…"
        case .succeeded:
            "文字起こし完了"
        case .failed:
            "文字起こし失敗"
        }
    }
}
