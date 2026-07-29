import AVFoundation
import Foundation

struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    static func connected() -> [MicrophoneDevice] {
        AVCaptureDevice.devices(for: .audio)
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
