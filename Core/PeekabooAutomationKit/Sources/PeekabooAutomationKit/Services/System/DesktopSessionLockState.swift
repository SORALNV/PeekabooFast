import CoreGraphics
import Foundation
import PeekabooFoundation

enum DesktopSessionLockState {
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static func currentScreenIsLocked() -> Bool? {
        self.screenIsLocked(in: CGSessionCopyCurrentDictionary() as NSDictionary?)
    }

    static func requireUnlockedForAccessibility(_ isLocked: Bool?) throws {
        guard isLocked != true else {
            throw PeekabooError.operationError(
                message: "Accessibility observation is unavailable while the macOS GUI session is locked. " +
                    "Unlock the Mac manually before retrying; no focus or input workaround was attempted.")
        }
    }

    static func screenIsLocked(in session: NSDictionary?) -> Bool? {
        session?[self.screenIsLockedKey] as? Bool
    }
}
