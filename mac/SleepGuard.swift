import Foundation
import IOKit.pwr_mgt

/// Holds one power assertion that stops idle system sleep. The display can still dim and
/// sleep; the Mac itself stays up. Once released, the Mac sleeps on its own Energy settings.
@MainActor
final class SleepGuard {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isHolding = false

    /// Takes the assertion, or renames it when already held (the name shows in
    /// `pmset -g assertions`). False when macOS refused it.
    @discardableResult
    func hold(reason: String) -> Bool {
        if isHolding {
            IOPMAssertionSetProperty(assertionID, kIOPMAssertionNameKey as CFString, reason as CFString)
            return true
        }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
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
