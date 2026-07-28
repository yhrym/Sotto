import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("保存") {
                LabeledContent("保存先") {
                    Text(appModel.saveFolderDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button("デフォルトに戻す") {
                        appModel.restoreDefaultSaveFolder()
                    }
                    Button("変更…") {
                        appModel.chooseSaveFolder()
                    }
                }
                Picker("AACビットレート", selection: $appModel.settings.bitrate) {
                    ForEach(AppSettings.Bitrate.allCases) { bitrate in
                        Text(bitrate.displayName).tag(bitrate)
                    }
                }
            }

            Section("入力レベル") {
                audioLevelRow(
                    title: "システム音声",
                    level: appModel.audioLevels.system,
                    color: .blue
                )
                audioLevelRow(
                    title: "マイク",
                    level: appModel.audioLevels.microphone,
                    color: .green
                )
                Text(
                    appModel.recordingState.isRecording
                        ? "録音前の分離PCMを表示しています。音声データ自体はUIに保持しません。"
                        : "録音中にシステム音声とマイクの入力レベルを表示します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("音声ミックス") {
                gainControl(
                    title: "マイク",
                    value: $appModel.settings.microphoneGain
                )
                gainControl(
                    title: "システム音声",
                    value: $appModel.settings.systemGain
                )
                Text("両方の初期値は0.7です。ミックス後の音声は±1.0に制限されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文字起こし") {
                Toggle("録音停止後に自動で文字起こし", isOn: $appModel.settings.transcriptionEnabled)
                Toggle("一時ファイルを残す", isOn: $appModel.settings.keepTemporaryFiles)
                    .disabled(!appModel.settings.transcriptionEnabled)
                Text("文字起こしは端末内だけで実行します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("一般") {
                Toggle(
                    "ログイン時にSottoを開く",
                    isOn: Binding(
                        get: { appModel.isLaunchAtLoginEnabled },
                        set: { appModel.setLaunchAtLogin($0) }
                    )
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 620)
        .navigationTitle("Sotto 設定")
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

    @ViewBuilder
    private func gainControl(title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0 ... 1.5, step: 0.05)
                    .frame(width: 220)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func audioLevelRow(
        title: String,
        level: Float,
        color: Color
    ) -> some View {
        LabeledContent(title) {
            AudioLevelWaveform(level: level, color: color)
                .frame(width: 280, height: 34)
        }
    }
}

private struct AudioLevelWaveform: View {
    let level: Float
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<28, id: \.self) { index in
                Capsule()
                    .fill(color.gradient)
                    .frame(width: 6, height: barHeight(at: index))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("入力レベル")
        .accessibilityValue("\(Int(level * 100))パーセント")
    }

    private func barHeight(at index: Int) -> CGFloat {
        let normalized = CGFloat(min(1, max(0, level)))
        let envelope = CGFloat(0.35 + 0.65 * abs(sin(Double(index) * 0.72)))
        return 3 + 29 * normalized * envelope
    }
}
