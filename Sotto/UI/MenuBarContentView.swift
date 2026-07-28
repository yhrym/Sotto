import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sotto")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appModel.recordingState.isRecording {
                    Text(appModel.elapsedText)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Button(action: appModel.toggleRecording) {
                Label(
                    appModel.recordingState.isRecording ? "録音を停止" : "録音を開始",
                    systemImage: appModel.recordingState.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appModel.recordingState.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(appModel.recordingState == .starting || appModel.recordingState == .stopping)

            if let activity = appModel.transcriptionActivity {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.description)
                        .font(.caption)
                    if let progress = activity.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if let failure = appModel.lastFailureMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label("処理に失敗しました", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("文字起こしを再実行") {
                        appModel.retryLastFailedTranscription()
                    }
                    .font(.caption)
                }
            }

            Divider()

            Button("保存フォルダを開く", systemImage: "folder") {
                appModel.openSaveFolder()
            }
            Button("直前の録音を表示", systemImage: "doc.badge.clock") {
                appModel.revealLastRecording()
            }

            Divider()

            HStack {
                SettingsLink {
                    Label("設定", systemImage: "gearshape")
                }
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .alert(
            "Sotto",
            isPresented: $appModel.isShowingError,
            actions: {
                if appModel.permissionSettingsURL != nil {
                    Button("システム設定を開く") {
                        appModel.openPermissionSettings()
                    }
                }
                Button("OK") {
                    appModel.dismissError()
                }
            },
            message: {
                Text(appModel.lastFailureMessage ?? "不明なエラーです。")
            }
        )
    }

    private var statusText: String {
        switch appModel.recordingState {
        case .idle:
            "待機中"
        case .starting:
            "録音を開始しています…"
        case .recording:
            "録音中"
        case .stopping:
            "録音を保存しています…"
        }
    }
}
