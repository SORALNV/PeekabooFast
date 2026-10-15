import Foundation
import Testing
@testable import PeekabooAutomationKit

struct UIStateDiffTests {
    private func element(_ id: String, identifier: String? = "field", value: String = "") -> UIElement {
        UIElement(
            id: id,
            elementId: id,
            role: "AXTextField",
            value: value,
            identifier: identifier,
            frame: .zero,
            isActionable: true)
    }

    @Test func `reused local hierarchy IDs cannot prove unchanged topology`() {
        let field = UIElement(
            id: "field",
            elementId: "field",
            role: "AXTextField",
            identifier: "stable-field",
            frame: .zero,
            isActionable: true,
            parentId: "local-parent")
        let unidentifiedParent = self.element("local-parent", identifier: nil)
        let diff = UIStateDiff.compare(before: [field, unidentifiedParent], after: [field, unidentifiedParent])
        #expect(diff.unchangedCount == 0)
        #expect(diff.changed.count == 1)
        #expect(diff.added.count == 1)
        #expect(diff.removed.count == 1)
    }

    @Test func `stable hierarchy survives ordinal ID changes`() {
        func tree(_ prefix: String) -> [UIElement] {
            [
                UIElement(
                    id: "\(prefix)-parent",
                    elementId: "\(prefix)-parent",
                    role: "AXGroup",
                    identifier: "parent",
                    frame: .zero,
                    isActionable: false,
                    children: ["\(prefix)-child"]),
                UIElement(
                    id: "\(prefix)-child",
                    elementId: "\(prefix)-child",
                    role: "AXTextField",
                    identifier: "child",
                    frame: .zero,
                    isActionable: true,
                    parentId: "\(prefix)-parent"),
            ]
        }
        let diff = UIStateDiff.compare(before: tree("old"), after: tree("new"))
        #expect(diff.unchangedCount == 2)
        #expect(diff.changed.isEmpty)
    }

    @Test func `values and local IDs`() {
        let original = self.element("1")
        let same = UIStateDiff.compare(before: [original], after: [self.element("9")])
        #expect(same.unchangedCount == 1)
        #expect(same.changed.isEmpty)
        let changed = UIStateDiff.compare(before: [original], after: [self.element("9", value: "hello")])
        #expect(changed.changed.count == 1)
        #expect(changed.changed.first?.before.id == "1")
        #expect(changed.changed.first?.after.id == "9")
    }

    @Test func `ambiguous I ds are never guessed`() {
        let duplicate = [self.element("1"), self.element("2")]
        let diff = UIStateDiff.compare(before: duplicate, after: duplicate)
        #expect(diff.added.count == 2)
        #expect(diff.removed.count == 2)
        #expect(diff.changed.isEmpty)
        let missing = UIStateDiff.compare(
            before: [self.element("1", identifier: nil)],
            after: [self.element("1", identifier: nil, value: "other")])
        #expect(missing.added.count == 1)
        #expect(missing.removed.count == 1)
    }

    @Test func `additions removals and empty trees`() {
        let a = self.element("1", identifier: "a")
        let b = self.element("2", identifier: "b")
        let diff = UIStateDiff.compare(before: [a], after: [b])
        #expect(diff.added.map(\.id) == ["2"])
        #expect(diff.removed.map(\.id) == ["1"])
        #expect(UIStateDiff.compare(before: [], after: []).unchangedCount == 0)
    }

    @Test func `payload benchmark`() throws {
        guard let output = ProcessInfo.processInfo.environment["PEEKABOO_DIFF_BENCHMARK_OUTPUT"] else { return }
        let before = (0..<1000).map { self.element("old-\($0)", identifier: "field-\($0)", value: "unchanged") }
        let after = (0..<1000).map {
            self.element("new-\($0)", identifier: "field-\($0)", value: $0 == 500 ? "changed" : "unchanged")
        }
        let encoder = JSONEncoder()
        var fullTimes: [Double] = []
        var diffTimes: [Double] = []
        var fullBytes = 0
        var diffBytes = 0
        for iteration in 0..<105 {
            let start = ContinuousClock.now
            fullBytes = try encoder.encode(after).count
            let fullDuration = start.duration(to: .now)
            let diffStart = ContinuousClock.now
            let diff = UIStateDiff.compare(before: before, after: after)
            diffBytes = try encoder.encode(diff).count
            let diffDuration = diffStart.duration(to: .now)
            #expect(diff.changed.count == 1)
            #expect(diff.unchangedCount == 999)
            if iteration >= 5 {
                fullTimes.append(Double(fullDuration.components.attoseconds) / 1e15 +
                    Double(fullDuration.components.seconds) * 1000)
                diffTimes.append(Double(diffDuration.components.attoseconds) / 1e15 +
                    Double(diffDuration.components.seconds) * 1000)
            }
        }
        #expect(diffBytes < fullBytes)
        let results: [String: Any] = [
            "elements": 1000,
            "changed": 1,
            "rounds": 100,
            "full_bytes": fullBytes,
            "diff_bytes": diffBytes,
            "full_samples_ms": fullTimes,
            "diff_samples_ms": diffTimes,
            "includes_ax_capture": false,
            "includes_llm": false,
        ]
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }
}
