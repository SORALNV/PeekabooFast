import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct DetachedExactWindowFocusWindowTests {
    private let first = AXUIElementCreateApplication(-101)
    private let second = AXUIElementCreateApplication(-102)
    private let third = AXUIElementCreateApplication(-103)

    @Test func `empty successful inventory uses exact known window fallback`() throws {
        let result = DetachedExactWindowFocusReader.targetWindow(
            expectedWindowID: 42,
            inventory: .init(error: .success, value: []),
            fallbackWindows: { [self.first, self.second] },
            copyWindowID: { element, id in id = CFEqual(element, self.second) ? 42 : 99; return .success })
        #expect(try CFEqual(result.get(), self.second))
    }

    @Test func `nonempty or failed inventory never calls fallback`() {
        for error in [AXError.success, .cannotComplete] {
            _ = DetachedExactWindowFocusReader.targetWindow(
                expectedWindowID: 42,
                inventory: .init(error: error, value: [self.first]),
                fallbackWindows: { Issue.record("Unexpected fallback"); return [] },
                copyWindowID: { _, id in id = 42; return .success })
        }
    }

    @Test func `live focus shortcut preserves exact receiver checks`() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 30)
        let expected = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 7,
            role: "AXTextArea",
            title: "Input",
            identifier: "composer",
            frame: frame)
        func snapshot(
            pid: Int32 = 42,
            window: Int? = 7,
            role: String = "AXTextArea",
            identifier: String = "composer",
            bounds: CGRect? = nil) -> ExactWindowFocusSnapshot
        {
            ExactWindowFocusSnapshot(
                processIdentifier: pid,
                windowID: window,
                frame: bounds ?? frame,
                role: role,
                title: "Input",
                identifier: identifier,
                nativeElement: RetainedFocusElement(element: self.first))
        }
        #expect(DetachedExactWindowFocusReader.matchesLiveReceiver(snapshot(), expected: expected, phase: .initial))
        for invalid in [
            snapshot(pid: 43),
            snapshot(window: 8),
            snapshot(window: nil),
            snapshot(role: "AXButton"),
            snapshot(identifier: "other"),
            snapshot(bounds: .zero),
        ] {
            #expect(!DetachedExactWindowFocusReader.matchesLiveReceiver(invalid, expected: expected, phase: .initial))
        }
        let moved = snapshot(bounds: CGRect(x: 10, y: 15, width: 100, height: 35))
        #expect(!DetachedExactWindowFocusReader.matchesLiveReceiver(moved, expected: expected, phase: .initial))
        #expect(DetachedExactWindowFocusReader.matchesLiveReceiver(moved, expected: expected, phase: .continuation))
    }

    @Test(arguments: [
        AXError.cannotComplete,
        .invalidUIElement,
        .apiDisabled,
        .noValue,
        .attributeUnsupported,
        .failure,
    ])
    func `inventory errors retain native status without probing identifiers`(error: AXError) {
        let result = DetachedExactWindowFocusReader.targetWindow(
            expectedWindowID: 42,
            inventory: .init(error: error, value: [self.first]),
            copyWindowID: { _, _ in Issue.record("Failed inventory must not trigger ID reads"); return .success })
        #expect(throws: FocusedElementReceiptError.windowObservationFailed(
            stage: .inventory,
            errorCode: error.rawValue))
        {
            try result.get()
        }
    }

    @Test
    func `missing and malformed inventories are not reported as different windows`() {
        let observations: [AXDescriptorReader.SingleAttributeRead?] = [
            nil,
            .init(error: .success, value: nil),
            .init(error: .success, value: "not an array"),
            .init(error: .success, value: [self.first, "not a window"] as [Any]),
        ]
        for inventory in observations {
            let result = DetachedExactWindowFocusReader.targetWindow(
                expectedWindowID: 42,
                inventory: inventory,
                copyWindowID: { _, _ in
                    Issue.record("Malformed inventory must not trigger ID reads"); return .success
                })
            #expect(throws: FocusedElementReceiptError.windowObservationFailed(stage: .inventory, errorCode: nil)) {
                try result.get()
            }
        }
    }

    @Test(arguments: [false, true])
    func `fully readable inventory distinguishes target absence`(empty: Bool) {
        var reads = 0
        let result = DetachedExactWindowFocusReader.targetWindow(
            expectedWindowID: 42,
            inventory: .init(error: .success, value: empty ? [] : [self.first, self.second]),
            copyWindowID: { _, id in reads += 1; id = CGWindowID(50 + reads); return .success })
        #expect(throws: FocusedElementReceiptError.windowNotFound) { try result.get() }
        #expect(reads == (empty ? 0 : 2))
    }

    @Test(arguments: [AXError.cannotComplete, .success])
    func `unresolved inventory identifiers are retained only when target is not found`(error: AXError) throws {
        for hasTarget in [false, true] {
            var readElements: [AXUIElement] = []
            let result = DetachedExactWindowFocusReader.targetWindow(
                expectedWindowID: 42,
                inventory: .init(error: .success, value: [self.first, self.second, self.third]),
                copyWindowID: { element, id in
                    readElements.append(element)
                    if CFEqual(element, self.first) {
                        return error
                    }
                    if CFEqual(element, self.second) {
                        id = hasTarget ? 42 : 43; return .success
                    }
                    return .invalidUIElement
                })
            if hasTarget {
                #expect(try CFEqual(result.get(), self.second))
                #expect(readElements.count == 2)
            } else {
                #expect(throws: FocusedElementReceiptError.windowObservationFailed(
                    stage: .inventoryWindowID, errorCode: error == .success ? nil : error.rawValue))
                {
                    try result.get()
                }
                #expect(readElements.count == 3)
            }
            #expect(CFEqual(readElements[0], self.first))
            #expect(CFEqual(readElements[1], self.second))
        }
    }

    @Test(arguments: [
        AXError.cannotComplete,
        .invalidUIElement,
        .apiDisabled,
        .noValue,
        .attributeUnsupported,
        .failure,
    ])
    func `owning window read failures retain native status without ID lookup`(error: AXError) {
        let result = DetachedExactWindowFocusReader.validateOwningWindow(
            .init(error: error, value: self.first),
            expectedWindowID: 42,
            copyWindowID: { _, _ in Issue.record("Failed AXWindow read must not query ID"); return .success })
        #expect(throws: FocusedElementReceiptError.windowObservationFailed(
            stage: .owningWindow,
            errorCode: error.rawValue))
        {
            try result.get()
        }
    }

    @Test
    func `missing and malformed owning windows are not compared with expected identity`() {
        let observations: [AXDescriptorReader.SingleAttributeRead?] = [
            nil, .init(error: .success, value: nil), .init(error: .success, value: "not a window"),
            .init(error: .success, value: [self.first]), .init(error: .success, value: NSNumber(value: 42)),
        ]
        for observation in observations {
            let result = DetachedExactWindowFocusReader.validateOwningWindow(
                observation,
                expectedWindowID: 42,
                copyWindowID: { _, _ in Issue.record("Malformed AXWindow must not query ID"); return .success })
            #expect(throws: FocusedElementReceiptError.windowObservationFailed(stage: .owningWindow, errorCode: nil)) {
                try result.get()
            }
        }
    }

    @Test(arguments: [AXError.cannotComplete, .success])
    func `failed and zero owning IDs remain unreadable rather than mismatched`(error: AXError) {
        var reads = 0
        let result = DetachedExactWindowFocusReader.validateOwningWindow(
            .init(error: .success, value: self.first),
            expectedWindowID: 42,
            copyWindowID: { element, _ in
                #expect(CFEqual(element, self.first))
                reads += 1
                return error
            })
        #expect(throws: FocusedElementReceiptError.windowObservationFailed(
            stage: .owningWindowID, errorCode: error == .success ? nil : error.rawValue))
        {
            try result.get()
        }
        #expect(reads == 1)
    }

    @Test(arguments: [CGWindowID(42), 99])
    func `only positive owning IDs establish a match or mismatch`(actual: CGWindowID) throws {
        var reads = 0
        let result = DetachedExactWindowFocusReader.validateOwningWindow(
            .init(error: .success, value: self.first),
            expectedWindowID: 42,
            copyWindowID: { element, id in
                #expect(CFEqual(element, self.first))
                reads += 1
                id = actual
                return .success
            })
        if actual == 42 {
            try result.get()
        } else {
            #expect(throws: FocusedElementReceiptError.windowMismatch) { try result.get() }
        }
        #expect(reads == 1)
    }

    @Test(arguments: [
        FocusedElementReceiptError.WindowObservationStage.inventory, .inventoryWindowID, .owningWindow, .owningWindowID,
    ])
    func `public diagnostic names only the AX stage and optional native error`(
        stage: FocusedElementReceiptError.WindowObservationStage)
    {
        for code: Int32? in [nil, AXError.cannotComplete.rawValue] {
            let message = FocusedElementReceiptError.windowObservationFailed(stage: stage, errorCode: code)
                .localizedDescription
            #expect(message.contains(stage.rawValue))
            #expect(!message.contains("belongs to a different window"))
            if let code {
                #expect(message.contains("AX error \(code)"))
            }
        }
    }
}
