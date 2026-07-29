import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel

    init() {
        let resolvedAppModel: AppModel
        do {
            let modelManager = SpeechModelManager()
            let jobStore = try TranscriptionJobStore()
            let queue = try TranscriptionQueue(
                store: jobStore,
                modelManager: modelManager
            )
            let transcriptionService = SottoTranscriptionService(
                queue: queue,
                modelManager: modelManager
            )
            let recordingService = try SottoRecordingService(
                transcriptionQueue: queue
            )
            let inputMonitor = SottoInputMonitor()
            resolvedAppModel = AppModel(
                recordingService: recordingService,
                transcriptionService: transcriptionService,
                inputMonitor: inputMonitor
            )
        } catch {
            resolvedAppModel = AppModel(
                initialFailureMessage: "Sottoの初期化に失敗しました: \(error.localizedDescription)"
            )
        }
        _appModel = StateObject(wrappedValue: resolvedAppModel)

#if DEBUG
        if let duration = Self.developmentSmokeTestDuration() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await resolvedAppModel.runDevelopmentSmokeTest(duration: duration)
            }
        }
#endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appModel)
        } label: {
            MenuBarLabel()
                .environmentObject(appModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }

#if DEBUG
    private static func developmentSmokeTestDuration() -> TimeInterval? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--sotto-development-smoke-test"),
              arguments.indices.contains(flagIndex + 1),
              let duration = TimeInterval(arguments[flagIndex + 1]),
              (5...300).contains(duration) else {
            return nil
        }
        return duration
    }
#endif
}
