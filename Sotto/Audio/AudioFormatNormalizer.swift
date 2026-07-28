import AVFAudio
import CoreMedia
import Foundation

enum AudioNormalizationError: LocalizedError {
    case missingFormat
    case unsupportedFormat
    case bufferList(OSStatus)
    case allocation
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .missingFormat:
            "音声サンプルにフォーマット情報がありません。"
        case .unsupportedFormat:
            "入力音声フォーマットを読み取れません。"
        case let .bufferList(status):
            "音声バッファを読み取れませんでした（OSStatus \(status)）。"
        case .allocation:
            "音声変換用バッファを確保できませんでした。"
        case let .conversion(message):
            "48 kHz / 2chへの音声変換に失敗しました: \(message)"
        }
    }
}

/// Copies a ScreenCaptureKit CMSampleBuffer and normalizes it to interleaved
/// Float32, 48 kHz, stereo PCM.
final class AudioFormatNormalizer {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    private let targetFormat: AVAudioFormat
    private var sourceFormatSignature: AudioFormatSignature?
    private var converter: AVAudioConverter?

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var wasSupplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private struct AudioFormatSignature: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let formatID: AudioFormatID
        let formatFlags: AudioFormatFlags
        let bytesPerFrame: UInt32

        init(_ format: AVAudioFormat) {
            let description = format.streamDescription.pointee
            sampleRate = description.mSampleRate
            channelCount = description.mChannelsPerFrame
            formatID = description.mFormatID
            formatFlags = description.mFormatFlags
            bytesPerFrame = description.mBytesPerFrame
        }
    }

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ) else {
            return nil
        }
        targetFormat = format
    }

    func normalize(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws -> CapturedAudioChunk {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioNormalizationError.missingFormat
        }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: streamDescription) else {
            throw AudioNormalizationError.unsupportedFormat
        }

        let inputFrameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inputFrameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: inputFrameCount
              ) else {
            throw AudioNormalizationError.allocation
        }
        // AVAudioPCMBuffer reports zero-sized mutable AudioBuffers while its
        // frameLength is zero. Set the intended length before copying, otherwise
        // mDataByteSize makes the copy below a silent zero-byte operation.
        sourceBuffer.frameLength = inputFrameCount

        var requiredBufferListSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, requiredBufferListSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioNormalizationError.bufferList(status)
        }
        let capturedListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { capturedListStorage.deallocate() }
        let capturedList = capturedListStorage.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: capturedList,
            bufferListSize: requiredBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw AudioNormalizationError.bufferList(status)
        }

        let capturedBuffers = UnsafeMutableAudioBufferListPointer(capturedList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        guard capturedBuffers.count == destinationBuffers.count else {
            throw AudioNormalizationError.unsupportedFormat
        }
        for index in 0..<capturedBuffers.count {
            let sourceAudioBuffer = capturedBuffers[index]
            var destinationAudioBuffer = destinationBuffers[index]
            guard let sourceData = sourceAudioBuffer.mData,
                  let destinationData = destinationAudioBuffer.mData else {
                throw AudioNormalizationError.unsupportedFormat
            }
            let byteCount = min(
                Int(sourceAudioBuffer.mDataByteSize),
                Int(destinationAudioBuffer.mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationAudioBuffer.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destinationAudioBuffer
        }

        let signature = AudioFormatSignature(sourceFormat)
        if sourceFormatSignature != signature {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioNormalizationError.unsupportedFormat
            }
            // The converter remains alive across chunks so fractional resampling state
            // is not discarded at every ScreenCaptureKit callback.
            newConverter.primeMethod = .none
            converter = newConverter
            sourceFormatSignature = signature
        }
        guard let converter else { throw AudioNormalizationError.unsupportedFormat }
        let rateRatio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(inputFrameCount) * rateRatio) + 64)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioNormalizationError.allocation
        }

        let converterInput = ConverterInput(buffer: sourceBuffer)
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            if converterInput.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            converterInput.wasSupplied = true
            inputStatus.pointee = .haveData
            return converterInput.buffer
        }
        guard conversionStatus == .haveData || conversionStatus == .inputRanDry else {
            throw AudioNormalizationError.conversion(
                conversionError?.localizedDescription ?? "\(conversionStatus.rawValue)"
            )
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let channels = outputBuffer.floatChannelData else {
            return CapturedAudioChunk(
                source: source,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                sampleRate: Self.sampleRate,
                channelCount: Int(Self.channelCount),
                samples: []
            )
        }
        var interleaved = [Float](repeating: 0, count: frameCount * Int(Self.channelCount))
        for frame in 0..<frameCount {
            for channel in 0..<Int(Self.channelCount) {
                interleaved[frame * Int(Self.channelCount) + channel] = channels[channel][frame]
            }
        }
        return CapturedAudioChunk(
            source: source,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sampleRate: Self.sampleRate,
            channelCount: Int(Self.channelCount),
            samples: interleaved
        )
    }
}
