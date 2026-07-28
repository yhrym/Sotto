import AVFAudio
import AudioToolbox
import CoreMedia
import XCTest
@testable import Sotto

final class AudioFormatNormalizerTests: XCTestCase {
    func testCopiesNonSilentPCMBeforeConverting() throws {
        let frames = 256
        var samples = [Float]()
        samples.reserveCapacity(frames * 2)
        for _ in 0..<frames {
            samples.append(0.25)
            samples.append(-0.5)
        }

        let sampleBuffer = try makeSampleBuffer(samples: samples, frameCount: frames)
        let normalizer = try XCTUnwrap(AudioFormatNormalizer())
        let normalized = try normalizer.normalize(sampleBuffer, source: .system)

        XCTAssertEqual(normalized.frameCount, frames)
        XCTAssertEqual(normalized.channelCount, 2)
        XCTAssertEqual(normalized.samples[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(normalized.samples[1], -0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(normalized.samples.map(abs).max() ?? 0, 0.49)
    }

    private func makeSampleBuffer(
        samples: [Float],
        frameCount: Int
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        let createdBlockBuffer = try XCTUnwrap(blockBuffer)

        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: createdBlockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr)

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: createdBlockBuffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
