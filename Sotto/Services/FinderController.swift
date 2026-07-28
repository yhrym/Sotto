import AppKit

@MainActor
struct FinderController {
    enum Error: LocalizedError {
        case folderUnavailable
        case recordingNotFound

        var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                "保存フォルダを開けませんでした。"
            case .recordingNotFound:
                "直前の録音が見つかりません。"
            }
        }
    }

    func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw Error.folderUnavailable
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
