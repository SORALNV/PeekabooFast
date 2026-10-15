import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopSessionLockStateTests {
    @Test
    func `locked AX observations report the session prerequisite instead of a focus timeout`() {
        #expect(throws: (any Error).self) {
            try DesktopSessionLockState.requireUnlockedForAccessibility(true)
        }
    }

    @Test
    func `unlocked and unavailable lock evidence preserve normal AX observation`() throws {
        try DesktopSessionLockState.requireUnlockedForAccessibility(false)
        try DesktopSessionLockState.requireUnlockedForAccessibility(nil)
    }

    @Test
    func `reports locked when the native session dictionary says locked`() {
        let session: NSDictionary = ["CGSSessionScreenIsLocked": true]

        #expect(DesktopSessionLockState.screenIsLocked(in: session) == true)
    }

    @Test
    func `reports unlocked when the native session dictionary says unlocked`() {
        let session: NSDictionary = ["CGSSessionScreenIsLocked": false]

        #expect(DesktopSessionLockState.screenIsLocked(in: session) == false)
    }

    @Test
    func `reports unknown when the native lock state is absent`() {
        #expect(DesktopSessionLockState.screenIsLocked(in: [:]) == nil)
        #expect(DesktopSessionLockState.screenIsLocked(in: nil) == nil)
    }
}
