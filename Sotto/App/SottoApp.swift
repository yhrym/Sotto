import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel: AppModel

    init() {
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
            _appModel = StateObject(
                wrappedValue: AppModel(
                    recordingService: recordingService,
                    transcriptionService: transcriptionService
                )
            )
        } catch {
            _appModel = StateObject(
                wrappedValue: AppModel(
                    initialFailureMessage: "Sottoの初期化に失敗しました: \(error.localizedDescription)"
                )
            )
        }
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
}
