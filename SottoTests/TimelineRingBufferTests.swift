import XCTest
@testable import Sotto

final class TimelineRingBufferTests: XCTestCase {
    func testRendersOutOfOrderChunksAndLeavesGapsSilent() {
        var buffer = TimelineRingBuffer(channelCount: 2)
        buffer.insert(startFrame: 4, samples: [4, 4, 5, 5])
        buffer.insert(startFrame: 0, samples: [0, 0, 1, 1])

        XCTAssertEqual(
            buffer.render(startFrame: 0, frameCount: 6),
            [0, 0, 1, 1, 0, 0, 0, 0, 4, 4, 5, 5]
        )
    }

    func testDiscardReleasesConsumedChunks() {
        var buffer = TimelineRingBuffer(channelCount: 2)
        buffer.insert(startFrame: 0, samples: [1, 1, 2, 2])
        buffer.insert(startFrame: 2, samples: [3, 3, 4, 4])
        buffer.discard(before: 2)

        XCTAssertEqual(buffer.earliestStartFrame, 2)
        XCTAssertEqual(buffer.render(startFrame: 0, frameCount: 4), [0, 0, 0, 0, 3, 3, 4, 4])
    }
}
