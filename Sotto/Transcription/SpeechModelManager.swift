import Foundation
import Speech

actor SpeechModelManager {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    private let japanese = Locale(identifier: "ja-JP")

    func makeJapaneseTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechTranscriberUnavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: japanese
        ) else {
            throw TranscriptionError.japaneseLocaleUnsupported
        }
        return SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    func ensureJapaneseModel(
        progressHandler: ProgressHandler? = nil
    ) async throws {
        let transcriber = try await makeJapaneseTranscriber()
        let modules: [any SpeechModule] = [transcriber]
        if let selectedLocale = transcriber.selectedLocales.first {
            _ = try await AssetInventory.reserve(locale: selectedLocale)
        }

        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            await progressHandler?(1)
            return
        case .unsupported:
            throw TranscriptionError.modelUnsupported
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            while !Task.isCancelled {
                switch await AssetInventory.status(forModules: modules) {
                case .installed:
                    await progressHandler?(1)
                    return
                case .downloading:
                    await progressHandler?(0)
                    try await Task.sleep(for: .milliseconds(500))
                case .unsupported:
                    throw TranscriptionError.modelUnsupported
                case .supported:
                    throw TranscriptionError.modelInstallationIncomplete
                @unknown default:
                    throw TranscriptionError.modelInstallationIncomplete
                }
            }
            throw CancellationError()
        }

        let reporter = Task {
            while !Task.isCancelled {
                await progressHandler?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }

        try await request.downloadAndInstall()
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw TranscriptionError.modelInstallationIncomplete
        }
        await progressHandler?(1)
    }
}
