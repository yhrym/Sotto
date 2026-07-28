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
    private var bookmarkResolutionError: (any Swift.Error)?

    init(
        fileManager: FileManager = .default,
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore()
    ) {
        self.fileManager = fileManager
        self.bookmarkStore = bookmarkStore
        do {
            scopedURL = try bookmarkStore.resolve()
        } catch {
            bookmarkResolutionError = error
        }
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
        let previousBookmark = bookmarkStore.storedBookmarkData()
        do {
            try bookmarkStore.save(url: url)
            let resolved = try bookmarkStore.resolve()
            scopedURL = resolved
            bookmarkResolutionError = nil
        } catch {
            bookmarkStore.restoreStoredBookmarkData(previousBookmark)
            throw error
        }
    }

    func restoreDefaultFolder() {
        scopedURL = nil
        bookmarkResolutionError = nil
        bookmarkStore.clear()
    }

    func currentBookmarkData() -> Data? {
        bookmarkStore.storedBookmarkData()
    }

    func accessibleFolderURL() throws -> URL {
        if let bookmarkResolutionError {
            throw bookmarkResolutionError
        }
        return currentFolderURL
    }

    func recordingFolder(for date: Date) throws -> URL {
        let baseURL = try accessibleFolderURL()
        let day = Self.dayFormatter.string(from: date)
        let folder = baseURL.appending(path: day, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func latestRecordingURL() throws -> URL? {
        let baseURL = try accessibleFolderURL()
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
