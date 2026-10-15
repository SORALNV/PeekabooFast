import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct AXKnownWindowCandidatesTests {
    @Test func `failed or malformed window inventories cannot authorize fallback`() {
        #expect(AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .success, value: [] as CFArray))
        #expect(!AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .cannotComplete, value: [] as CFArray))
        #expect(!AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .noValue, value: nil))
        #expect(!AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .success, value: nil))
        #expect(!AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .success, value: "" as CFString))
        #expect(!AXKnownWindowCandidates.isSuccessfullyEmptyInventory(error: .success, value: [1] as CFArray))
    }

    @Test func `nonempty inventory avoids fallback reads`() {
        let windows = AXKnownWindowCandidates.supplement(
            listed: [7],
            main: { Issue.record("Must not query fallback"); return 8 },
            focused: { Issue.record("Must not query fallback"); return 9 },
            isValid: { _ in true },
            equal: ==)
        #expect(windows == [7])
    }

    @Test func `empty inventory recovers and deduplicates known windows`() {
        let same = AXKnownWindowCandidates.supplement(
            listed: [],
            main: { 7 },
            focused: { 7 },
            isValid: { _ in true },
            equal: ==)
        #expect(same == [7])
        let distinct = AXKnownWindowCandidates.supplement(
            listed: [],
            main: { 7 },
            focused: { 8 },
            isValid: { _ in true },
            equal: ==)
        #expect(distinct == [7, 8])
        let invalid = AXKnownWindowCandidates.supplement(
            listed: [],
            main: { 7 },
            focused: { 8 },
            isValid: { $0 == 8 },
            equal: ==)
        #expect(invalid == [8])
    }

    @Test func `off screen is not evidence of minimization`() {
        let identity = SystemWindowIdentity(
            windowID: 7,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            title: "Off-Space window",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0,
            alpha: 1,
            isOnScreen: false,
            sharingState: nil)
        let window = ObservationTargetResolver.serviceWindowInfo(identity, index: 0)
        #expect(!window.isMinimized)
        #expect(window.isOffScreen)
        #expect(window.mutationIdentity?.isMinimized == nil)
        #expect(WindowFiltering.disqualificationReason(for: window) == "window off-screen")
    }
}
