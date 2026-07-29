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
        ZStack {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()

            if appModel.recordingState.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 4, height: 4)
                    .offset(x: 3.5, y: 1)
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
