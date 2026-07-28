import Foundation
import XCTest
@testable import Sotto

@MainActor
final class RecordingStorageSecurityTests: XCTestCase {
    func testInvalidStoredBookmarkDoesNotSilentlyFallBackToDefaultFolder() throws {
        let suiteName = "RecordingStorageSecurityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("テスト用UserDefaultsを作成できませんでした。")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(Data("invalid bookmark".utf8), forKey: "storage.folderBookmark")

        let bookmarkStore = SecurityScopedBookmarkStore(defaults: defaults)
        let storage = RecordingStorage(bookmarkStore: bookmarkStore)

        XCTAssertThrowsError(try storage.accessibleFolderURL())

        storage.restoreDefaultFolder()
        XCTAssertNoThrow(try storage.accessibleFolderURL())
        XCTAssertNil(bookmarkStore.storedBookmarkData())
    }
}
