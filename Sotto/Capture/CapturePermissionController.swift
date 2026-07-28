import AVFoundation
import CoreGraphics
import Foundation

enum CapturePermissionError: LocalizedError, Sendable {
    case screenRecordingDenied
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "画面とシステムオーディオ録音の許可が必要です。システム設定でSottoを許可してください。"
        case .microphoneDenied:
            "マイクの許可が必要です。システム設定でSottoを許可してください。"
        }
    }

    var systemSettingsURL: URL? {
        let anchor = switch self {
        case .screenRecordingDenied: "Privacy_ScreenCapture"
        case .microphoneDenied: "Privacy_Microphone"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )
    }
}

enum CapturePermissionController {
    /// ScreenCaptureKit authorization is checked first because it governs both the
    /// minimal video stream and system audio. No capture objects are created until
    /// both permissions have been granted.
    static func requestRequiredPermissions() async throws {
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw CapturePermissionError.screenRecordingDenied
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CapturePermissionError.microphoneDenied
            }
        case .denied, .restricted:
            throw CapturePermissionError.microphoneDenied
        @unknown default:
            throw CapturePermissionError.microphoneDenied
        }
    }
}
