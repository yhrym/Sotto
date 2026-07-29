import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        HStack(spacing: 4) {
            menuBarIcon

            if appModel.recordingState.isRecording {
                Text(appModel.elapsedText)
            }

            if let activity = appModel.transcriptionActivity {
                transcriptionProgress(activity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var menuBarIcon: some View {
        Group {
            if appModel.recordingState.isRecording {
                Image("MenuBarGhostRecording")
                    .renderingMode(.original)
            } else {
                Image("MenuBarGhost")
                    .renderingMode(.template)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var accessibilityDescription: String {
        if appModel.recordingState.isRecording {
            return "Sotto 録音中 \(appModel.elapsedText)"
        }
        if let activity = appModel.transcriptionActivity {
            return activity.description
        }
        return "Sotto"
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
