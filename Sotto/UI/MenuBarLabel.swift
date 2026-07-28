import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        if appModel.recordingState.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                Text(appModel.elapsedText)
                if let activity = appModel.transcriptionActivity {
                    transcriptionProgress(activity)
                }
            }
            .accessibilityElement(children: .combine)
        } else if let activity = appModel.transcriptionActivity {
            Label {
                transcriptionProgress(activity)
            } icon: {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
            .accessibilityLabel(activity.description)
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Sotto")
        }
    }

    @ViewBuilder
    private func transcriptionProgress(
        _ activity: AppModel.TranscriptionActivity
    ) -> some View {
        if let progress = activity.progress {
            Text("\(Int((progress * 100).rounded()))%")
                .monospacedDigit()
        } else {
            Image(systemName: "ellipsis")
                .accessibilityLabel(activity.description)
        }
    }
}
