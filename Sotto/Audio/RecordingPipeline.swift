import Foundation

struct RecordingPipelineFinalizationError: LocalizedError, Sendable {
    enum Target: String, Equatable, Sendable {
        case mixedTimeline = "ミックス音声タイムライン"
        case stemTimeline = "系統別音声タイムライン"
        case mixedWriter = "ミックス音声ファイル"
        case systemWriter = "システム音声一時ファイル"
        case microphoneWriter = "マイク音声一時ファイル"
    }

    struct Failure: Equatable, Sendable {
        let target: Target
        let message: String
    }

    let failures: [Failure]

    var errorDescription: String? {
        failures
            .map { "\($0.target.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }
}

struct RecordingPipelineConfiguration: Sendable {
    let mixedFileURL: URL
    let systemStemURL: URL?
    let microphoneStemURL: URL?
    var bitRate: Int = 128_000
    var systemGain: Float = 0.7
    var microphoneGain: Float = 0.7

    var writesStems: Bool {
        systemStemURL != nil && microphoneStemURL != nil
    }
}

/// Owns all writers for one recording part. Capture publishes normalized PCM once;
/// independent subscriptions drive the mixed recording and synchronized stem files.
final class RecordingPipeline: @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void
    typealias LevelHandler = @Sendable (AudioSource, Float) -> Void
    typealias WriterFactory = @Sendable (
        URL,
        Int,
        @escaping FailureHandler
    ) throws -> any RecordingAudioWriter

    private let distributor = PCMDistributor()
    private let failureHandler: FailureHandler
    private let levelHandler: LevelHandler
    private let mixedMixer: TimestampedAudioMixer
    private let stemSynchronizer: TimestampedAudioMixer?
    private let mixedWriter: any RecordingAudioWriter
    private let systemWriter: (any RecordingAudioWriter)?
    private let microphoneWriter: (any RecordingAudioWriter)?
    private let mixedPathLock = NSLock()
    private let stemPathLock = NSLock()
    private var subscriptionIDs: [UUID] = []

    init(
        configuration: RecordingPipelineConfiguration,
        onFailure: @escaping FailureHandler,
        onLevel: @escaping LevelHandler = { _, _ in },
        writerFactory: @escaping WriterFactory = { url, bitRate, failureHandler in
            try AssetWriterSink(
                url: url,
                bitRate: bitRate,
                failureHandler: failureHandler
            )
        }
    ) throws {
        failureHandler = onFailure
        levelHandler = onLevel
        var mixedConfiguration = TimestampedAudioMixer.Configuration()
        mixedConfiguration.systemGain = configuration.systemGain
        mixedConfiguration.microphoneGain = configuration.microphoneGain
        mixedMixer = TimestampedAudioMixer(configuration: mixedConfiguration)
        let createdSystemWriter: (any RecordingAudioWriter)?
        let createdMicrophoneWriter: (any RecordingAudioWriter)?
        if configuration.writesStems,
           let systemURL = configuration.systemStemURL,
           let microphoneURL = configuration.microphoneStemURL {
            stemSynchronizer = TimestampedAudioMixer()
            let systemWriter = try writerFactory(
                systemURL,
                configuration.bitRate,
                onFailure
            )
            do {
                createdMicrophoneWriter = try writerFactory(
                    microphoneURL,
                    configuration.bitRate,
                    onFailure
                )
                createdSystemWriter = systemWriter
            } catch {
                systemWriter.cancel()
                throw error
            }
        } else {
            stemSynchronizer = nil
            createdSystemWriter = nil
            createdMicrophoneWriter = nil
        }

        // Create the irreplaceable mixed recording only after both disposable stem
        // writers are ready. If mixed writer creation fails, cancel the empty stems;
        // capture has not started yet, so no recorded samples can be lost here.
        do {
            mixedWriter = try writerFactory(
                configuration.mixedFileURL,
                configuration.bitRate,
                onFailure
            )
        } catch {
            createdSystemWriter?.cancel()
            createdMicrophoneWriter?.cancel()
            throw error
        }
        systemWriter = createdSystemWriter
        microphoneWriter = createdMicrophoneWriter

        subscriptionIDs.append(
            distributor.subscribe { [weak self] chunk in
                self?.consumeForMixedFile(chunk)
            }
        )
        if stemSynchronizer != nil {
            subscriptionIDs.append(
                distributor.subscribe { [weak self] chunk in
                    self?.consumeForStemFiles(chunk)
                }
            )
        }
    }

    func accept(_ chunk: CapturedAudioChunk) {
        levelHandler(chunk.source, AudioLevelMeter.normalizedRMS(samples: chunk.samples))
        distributor.publish(chunk)
    }

    func finish() async throws {
        subscriptionIDs.forEach(distributor.unsubscribe)
        subscriptionIDs.removeAll()

        var failures: [RecordingPipelineFinalizationError.Failure] = []
        do {
            try mixedPathLock.withLock {
                appendMixed(try mixedMixer.finish())
            }
        } catch {
            failures.append(.init(target: .mixedTimeline, message: error.localizedDescription))
        }
        if let stemSynchronizer {
            do {
                try stemPathLock.withLock {
                    appendStems(try stemSynchronizer.finish())
                }
            } catch {
                failures.append(.init(target: .stemTimeline, message: error.localizedDescription))
            }
        }

        do {
            try await mixedWriter.finish()
        } catch {
            failures.append(.init(target: .mixedWriter, message: error.localizedDescription))
        }
        if let systemWriter {
            do {
                try await systemWriter.finish()
            } catch {
                failures.append(.init(target: .systemWriter, message: error.localizedDescription))
            }
        }
        if let microphoneWriter {
            do {
                try await microphoneWriter.finish()
            } catch {
                failures.append(.init(target: .microphoneWriter, message: error.localizedDescription))
            }
        }

        if !failures.isEmpty {
            throw RecordingPipelineFinalizationError(failures: failures)
        }
    }

    private func consumeForMixedFile(_ chunk: CapturedAudioChunk) {
        do {
            try mixedPathLock.withLock {
                appendMixed(try mixedMixer.append(chunk))
            }
        } catch {
            failureHandler(error)
        }
    }

    private func consumeForStemFiles(_ chunk: CapturedAudioChunk) {
        guard let stemSynchronizer else { return }
        do {
            try stemPathLock.withLock {
                appendStems(try stemSynchronizer.append(chunk))
            }
        } catch {
            failureHandler(error)
        }
    }

    private func appendMixed(_ blocks: [SynchronizedAudioBlock]) {
        for block in blocks {
            mixedWriter.append(block.mixedChunk)
        }
    }

    private func appendStems(_ blocks: [SynchronizedAudioBlock]) {
        for block in blocks {
            systemWriter?.append(block.chunk(for: .system))
            microphoneWriter?.append(block.chunk(for: .microphone))
        }
    }

}
