import Foundation

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

        if isStale {
            try save(url: url)
        }
        return ResolvedSecurityScopedURL(url: url)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    func storedBookmarkData() -> Data? {
        defaults.data(forKey: key)
    }
}

final class ResolvedSecurityScopedURL {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
