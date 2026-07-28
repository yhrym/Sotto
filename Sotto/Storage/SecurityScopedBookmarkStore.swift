import Foundation

enum SecurityScopedBookmarkError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "保存先フォルダへのアクセス権を復元できませんでした。設定で保存先を選び直すか、デフォルトに戻してください。"
        }
    }
}

final class SecurityScopedBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "storage.folderBookmark") {
        self.defaults = defaults
        self.key = key
    }

    func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key)
    }

    func resolve() throws -> ResolvedSecurityScopedURL? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        let resolved = try ResolvedSecurityScopedURL(url: url)
        if isStale {
            try save(url: url)
        }
        return resolved
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    func restoreStoredBookmarkData(_ data: Data?) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            clear()
        }
    }

    func storedBookmarkData() -> Data? {
        defaults.data(forKey: key)
    }
}

final class ResolvedSecurityScopedURL {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL) throws {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
        guard didStartAccessing else {
            throw SecurityScopedBookmarkError.accessDenied
        }
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
