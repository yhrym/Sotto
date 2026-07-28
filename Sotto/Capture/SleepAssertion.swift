import Foundation
import IOKit.pwr_mgt

final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID = IOPMAssertionID(0)

    func acquire() throws {
        try lock.withLock {
            guard assertionID == 0 else { return }
            var createdID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Sottoで会議を録音中" as CFString,
                &createdID
            )
            guard result == kIOReturnSuccess else {
                throw NSError(
                    domain: "jp.sotto.sleep-assertion",
                    code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: "録音中のシステムスリープ抑止に失敗しました。"]
                )
            }
            assertionID = createdID
        }
    }

    func release() {
        lock.withLock {
            guard assertionID != 0 else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit {
        release()
    }
}
