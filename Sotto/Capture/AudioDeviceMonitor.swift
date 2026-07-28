import CoreAudio
import Foundation

/// Watches both default input and output routes. A route transition proactively
/// rolls the current part before ScreenCaptureKit can leave a damaged writer open.
final class AudioDeviceMonitor: @unchecked Sendable {
    typealias ChangeHandler = @Sendable () -> Void

    private let queue = DispatchQueue(label: "jp.sotto.audio-device-monitor")
    private let handler: ChangeHandler
    private let lock = NSLock()
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(handler: @escaping ChangeHandler) {
        self.handler = handler
    }

    func start() throws {
        try lock.withLock {
            guard registrations.isEmpty else { return }
            try register(selector: kAudioHardwarePropertyDefaultInputDevice)
            do {
                try register(selector: kAudioHardwarePropertyDefaultOutputDevice)
            } catch {
                removeAll()
                throw error
            }
        }
    }

    func stop() {
        lock.withLock {
            removeAll()
        }
    }

    private func register(selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let callback: AudioObjectPropertyListenerBlock = { [handler] _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            callback
        )
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "音声デバイス変更監視を開始できませんでした。"]
            )
        }
        registrations.append((address, callback))
    }

    private func removeAll() {
        for (storedAddress, callback) in registrations {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                callback
            )
        }
        registrations.removeAll()
    }

    deinit {
        stop()
    }
}
