import Foundation

struct TranscriptMerger: Sendable {
    func merge(
        system: [TranscriptEntry],
        selfSpeaker: [TranscriptEntry]
    ) -> [TranscriptEntry] {
        (system + selfSpeaker).sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.speaker != rhs.speaker {
                return lhs.speaker == .system
            }
            return lhs.text < rhs.text
        }
    }
}

struct MarkdownTranscriptWriter: Sendable {
    func render(
        recordingStartedAt: Date,
        duration: TimeInterval,
        entries: [TranscriptEntry],
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            "# \(formatter.string(from: recordingStartedAt)) (\(durationText(duration)))",
            ""
        ]
        lines.append(
            contentsOf: entries.map {
                let oneLineText = $0.text
                    .split(whereSeparator: \.isNewline)
                    .joined(separator: " ")
                return "- [\(timestamp($0.startTime))] \($0.speaker.rawValue): \(oneLineText)"
            }
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }

    func write(
        recordingStartedAt: Date,
        duration: TimeInterval,
        entries: [TranscriptEntry],
        to url: URL,
        timeZone: TimeZone = .current
    ) throws {
        let markdown = render(
            recordingStartedAt: recordingStartedAt,
            duration: duration,
            entries: entries,
            timeZone: timeZone
        )
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    private func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return "\(hours)時間\(minutes)分\(remainder)秒"
        }
        return "\(minutes)分\(remainder)秒"
    }
}
