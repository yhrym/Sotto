import Foundation

@MainActor
final class RecordingStorage {
    enum Error: LocalizedError {
        case musicFolderUnavailable

        var errorDescription: String? {
            "ミュージックフォルダを取得できませんでした。"
        }
    }

    private let fileManager: FileManager
    private let bookmarkStore: SecurityScopedBookmarkStore
    private var scopedURL: ResolvedSecurityScopedURL?

    init(
        fileManager: FileManager = .default,
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore()
    ) {
        self.fileManager = fileManager
        self.bookmarkStore = bookmarkStore
        scopedURL = try? bookmarkStore.resolve()
    }

    var currentFolderURL: URL {
        if let scopedURL {
            return scopedURL.url
        }
        return defaultFolderURL
    }

    var defaultFolderURL: URL {
        let musicURL = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Music", directoryHint: .isDirectory)
        return musicURL.appending(path: "Sotto", directoryHint: .isDirectory)
    }

    func selectFolder(_ url: URL) throws {
        try bookmarkStore.save(url: url)
        let resolved = try bookmarkStore.resolve()
        scopedURL = resolved
    }

    func restoreDefaultFolder() {
        scopedURL = nil
        bookmarkStore.clear()
    }

    func currentBookmarkData() -> Data? {
        bookmarkStore.storedBookmarkData()
    }

    func recordingFolder(for date: Date) throws -> URL {
        let day = Self.dayFormatter.string(from: date)
        let folder = currentFolderURL.appending(path: day, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func latestRecordingURL() throws -> URL? {
        let baseURL = currentFolderURL
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return nil
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var newest: (url: URL, modifiedAt: Date)?
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "m4a" {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else {
                continue
            }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if newest == nil || modifiedAt > newest!.modifiedAt {
                newest = (url, modifiedAt)
            }
        }
        return newest?.url
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
