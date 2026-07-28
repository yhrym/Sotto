import AVFoundation
import XCTest
@testable import Sotto

final class FragmentedAssetWriterTests: XCTestCase {
    func testWriterProducesReadableStereoM4A() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appendingPathComponent("test.m4a")
        let writer = try AssetWriterSink(url: fileURL, bitRate: 128_000) { error in
            XCTFail(error.localizedDescription)
        }

        let frames = 48_000
        let chunk = CapturedAudioChunk(
            source: .system,
            presentationTimeStamp: .zero,
            sampleRate: 48_000,
            channelCount: 2,
            samples: [Float](repeating: 0.05, count: frames * 2)
        )
        XCTAssertTrue(writer.append(chunk))
        try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.9)
        XCTAssertEqual(tracks.count, 1)
    }
}
