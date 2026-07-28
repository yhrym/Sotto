import Foundation
import Testing
@testable import Sotto

struct TranscriptMergerTests {
    @Test
    func mergesByTimestampWithMeetingFirstForTies() {
        let meeting = [
            TranscriptEntry(startTime: 7, speaker: .meeting, text: "後"),
            TranscriptEntry(startTime: 3, speaker: .meeting, text: "会議")
        ]
        let selfSpeaker = [
            TranscriptEntry(startTime: 3, speaker: .selfSpeaker, text: "自分")
        ]

        let merged = TranscriptMerger().merge(
            meeting: meeting,
            selfSpeaker: selfSpeaker
        )

        #expect(merged.map(\.text) == ["会議", "自分", "後"])
    }

    @Test
    func rendersRequiredMarkdownFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let start = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 14,
                minute: 30,
                second: 12
            )
        )!

        let markdown = MarkdownTranscriptWriter().render(
            recordingStartedAt: start,
            duration: 3_133,
            entries: [
                TranscriptEntry(
                    startTime: 3,
                    speaker: .meeting,
                    text: "おはようございます"
                ),
                TranscriptEntry(
                    startTime: 7,
                    speaker: .selfSpeaker,
                    text: "よろしくお願いします"
                )
            ],
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )

        #expect(markdown.contains("# 2026-07-28 14:30:12 (52分13秒)"))
        #expect(markdown.contains("- [00:00:03] 会議: おはようございます"))
        #expect(markdown.contains("- [00:00:07] 自分: よろしくお願いします"))
    }
}
