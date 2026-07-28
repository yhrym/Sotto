import AVFAudio
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

enum ScreenCaptureSessionError: LocalizedError {
    case noDisplay
    case normalizerUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "録音対象にできるディスプレイが見つかりません。"
        case .normalizerUnavailable:
            "48 kHz / 2chの音声変換器を初期化できません。"
        }
    }
}

/// One SCStream supplies system audio, microphone audio, and a deliberately
/// discarded minimal video output.
final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias AudioHandler = @Sendable (CapturedAudioChunk) -> Void
    typealias StopHandler = @Sendable (Error) -> Void

    private let logger = Logger(subsystem: "jp.sotto.Sotto", category: "ScreenCapture")
    private let audioHandler: AudioHandler
    private let stopHandler: StopHandler
    private let systemNormalizer: AudioFormatNormalizer
    private let microphoneNormalizer: AudioFormatNormalizer
    private let systemQueue = DispatchQueue(label: "jp.sotto.capture.system-audio")
    private let microphoneQueue = DispatchQueue(label: "jp.sotto.capture.microphone")
    private let screenQueue = DispatchQueue(label: "jp.sotto.capture.discarded-video")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var stoppingNormally = false
    private var loggedSystemFormat = false
    private var loggedMicrophoneFormat = false

    init(audioHandler: @escaping AudioHandler, stopHandler: @escaping StopHandler) throws {
        guard let systemNormalizer = AudioFormatNormalizer(),
              let microphoneNormalizer = AudioFormatNormalizer() else {
            throw ScreenCaptureSessionError.normalizerUnavailable
        }
        self.audioHandler = audioHandler
        self.stopHandler = stopHandler
        self.systemNormalizer = systemNormalizer
        self.microphoneNormalizer = microphoneNormalizer
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw ScreenCaptureSessionError.noDisplay
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = Int(AudioFormatNormalizer.sampleRate)
        configuration.channelCount = Int(AudioFormatNormalizer.channelCount)
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        stateLock.withLock {
            stoppingNormally = false
            self.stream = stream
        }
        do {
            try await stream.startCapture()
        } catch {
            stateLock.withLock {
                self.stream = nil
            }
            throw error
        }
    }

    func stop() async throws {
        let currentStream: SCStream? = stateLock.withLock {
            stoppingNormally = true
            return stream
        }
        try await currentStream?.stopCapture()
        stateLock.withLock {
            stream = nil
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            // ScreenCaptureKit requires a video stream; never retain or copy it.
            return
        case .audio:
            logFormatOnce(sampleBuffer, source: .system)
            normalize(sampleBuffer, source: .system, with: systemNormalizer)
        case .microphone:
            logFormatOnce(sampleBuffer, source: .microphone)
            normalize(sampleBuffer, source: .microphone, with: microphoneNormalizer)
        @unknown default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let expected = stateLock.withLock {
            self.stream = nil
            return stoppingNormally
        }
        if !expected {
            stopHandler(error)
        }
    }

    private func normalize(
        _ sampleBuffer: CMSampleBuffer,
        source: AudioSource,
        with normalizer: AudioFormatNormalizer
    ) {
        do {
            let chunk = try normalizer.normalize(sampleBuffer, source: source)
            if chunk.frameCount > 0 {
                audioHandler(chunk)
            }
        } catch {
            stopHandler(error)
        }
    }

    private func logFormatOnce(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        let shouldLog: Bool
        switch source {
        case .system:
            shouldLog = !loggedSystemFormat
            loggedSystemFormat = true
        case .microphone:
            shouldLog = !loggedMicrophoneFormat
            loggedMicrophoneFormat = true
        }
        guard shouldLog,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return
        }
        logger.info(
            "\(source.rawValue, privacy: .public) input format: \(asbd.pointee.mSampleRate, privacy: .public) Hz, \(asbd.pointee.mChannelsPerFrame, privacy: .public) ch"
        )
    }
}
