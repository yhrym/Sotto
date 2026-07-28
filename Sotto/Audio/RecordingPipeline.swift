import Foundation

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

    private let distributor = PCMDistributor()
    private let levelHandler: LevelHandler
    private let mixedMixer: TimestampedAudioMixer
    private let stemSynchronizer: TimestampedAudioMixer?
    private let mixedWriter: AssetWriterSink
    private let systemWriter: AssetWriterSink?
    private let microphoneWriter: AssetWriterSink?
    private let mixedPathLock = NSLock()
    private let stemPathLock = NSLock()
    private var subscriptionIDs: [UUID] = []

    init(
        configuration: RecordingPipelineConfiguration,
        onFailure: @escaping FailureHandler,
        onLevel: @escaping LevelHandler = { _, _ in }
    ) throws {
        levelHandler = onLevel
        var mixedConfiguration = TimestampedAudioMixer.Configuration()
        mixedConfiguration.systemGain = configuration.systemGain
        mixedConfiguration.microphoneGain = configuration.microphoneGain
        mixedMixer = TimestampedAudioMixer(configuration: mixedConfiguration)
        mixedWriter = try AssetWriterSink(
            url: configuration.mixedFileURL,
            bitRate: configuration.bitRate,
            failureHandler: onFailure
        )

        if configuration.writesStems,
           let systemURL = configuration.systemStemURL,
           let microphoneURL = configuration.microphoneStemURL {
            stemSynchronizer = TimestampedAudioMixer()
            systemWriter = try AssetWriterSink(
                url: systemURL,
                bitRate: configuration.bitRate,
                failureHandler: onFailure
            )
            microphoneWriter = try AssetWriterSink(
                url: microphoneURL,
                bitRate: configuration.bitRate,
                failureHandler: onFailure
            )
        } else {
            stemSynchronizer = nil
            systemWriter = nil
            microphoneWriter = nil
        }

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
        levelHandler(chunk.source, Self.meterLevel(for: chunk.samples))
        distributor.publish(chunk)
    }

    func finish() async throws {
        subscriptionIDs.forEach(distributor.unsubscribe)
        subscriptionIDs.removeAll()

        mixedPathLock.withLock {
            appendMixed(mixedMixer.finish())
        }
        if let stemSynchronizer {
            stemPathLock.withLock {
                appendStems(stemSynchronizer.finish())
            }
        }

        try await mixedWriter.finish()
        try await systemWriter?.finish()
        try await microphoneWriter?.finish()
    }

    private func consumeForMixedFile(_ chunk: CapturedAudioChunk) {
        mixedPathLock.withLock {
            appendMixed(mixedMixer.append(chunk))
        }
    }

    private func consumeForStemFiles(_ chunk: CapturedAudioChunk) {
        guard let stemSynchronizer else { return }
        stemPathLock.withLock {
            appendStems(stemSynchronizer.append(chunk))
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

    /// Maps RMS amplitude from -60...0 dB onto a UI-friendly 0...1 range.
    /// Only the scalar level is retained; no audio samples leave the pipeline.
    private static func meterLevel(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))
        guard rms.isFinite, rms > 0.001 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }
}
