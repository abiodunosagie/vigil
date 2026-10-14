import Foundation
import IOKit.pwr_mgt

/// Holds one power assertion of one kind. Once released, macOS goes back to its own settings.
@MainActor
final class SleepGuard {
    /// Stops idle system sleep; the screen can still dim, sleep and lock.
    static func system() -> SleepGuard { SleepGuard(kind: kIOPMAssertionTypePreventUserIdleSystemSleep) }
    /// Stops the screen dimming and sleeping, which also stops the lock that follows it.
    static func display() -> SleepGuard { SleepGuard(kind: kIOPMAssertionTypePreventUserIdleDisplaySleep) }

    private let kind: String
    private var assertionID = IOPMAssertionID(0)
    private(set) var isHolding = false

    private init(kind: String) { self.kind = kind }

    /// Takes the assertion, or renames it when already held (the name shows in
    /// `pmset -g assertions`). False when macOS refused it.
    @discardableResult
    func hold(reason: String) -> Bool {
        if isHolding {
            IOPMAssertionSetProperty(assertionID, kIOPMAssertionNameKey as CFString, reason as CFString)
            return true
        }
        let result = IOPMAssertionCreateWithName(kind as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &assertionID)
        isHolding = result == kIOReturnSuccess
        return isHolding
    }

    func release() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHolding = false
    }
}
