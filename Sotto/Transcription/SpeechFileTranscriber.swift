import AVFAudio
import CoreMedia
import Foundation
import Speech

struct SpeechFileTranscriber: Sendable {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    private let modelManager: SpeechModelManager

    init(modelManager: SpeechModelManager) {
        self.modelManager = modelManager
    }

    func transcribe(
        audioURL: URL,
        speaker: SpeakerLabel,
        progressHandler: ProgressHandler? = nil
    ) async throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.missingTemporaryFile(audioURL)
        }
        let values = try audioURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw TranscriptionError.emptyAudioFile(audioURL)
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        guard audioFile.length > 0, audioFile.processingFormat.sampleRate > 0 else {
            throw TranscriptionError.emptyAudioFile(audioURL)
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let transcriber = try await modelManager.makeJapaneseTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let entries: [TranscriptEntry] = collectResults(
            from: transcriber,
            speaker: speaker,
            duration: duration,
            progressHandler: progressHandler
        )

        guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
            await analyzer.cancelAndFinishNow()
            _ = try? await entries
            throw TranscriptionError.noFinalAnalysisTime(audioURL)
        }
        try await analyzer.finalizeAndFinish(through: lastSampleTime)

        let result = try await entries
        await progressHandler?(1)
        return result
    }

    private func collectResults(
        from transcriber: SpeechTranscriber,
        speaker: SpeakerLabel,
        duration: TimeInterval,
        progressHandler: ProgressHandler?
    ) async throws -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []

        for try await result in transcriber.results {
            guard result.isFinal else { continue }
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let rawStartTime = CMTimeGetSeconds(result.range.start)
                entries.append(
                    TranscriptEntry(
                        startTime: rawStartTime.isFinite ? max(0, rawStartTime) : 0,
                        speaker: speaker,
                        text: text
                    )
                )
            }

            let finalized = CMTimeGetSeconds(result.resultsFinalizationTime)
            if finalized.isFinite, duration > 0 {
                await progressHandler?(min(max(finalized / duration, 0), 0.99))
            }
        }

        return entries
    }
}
