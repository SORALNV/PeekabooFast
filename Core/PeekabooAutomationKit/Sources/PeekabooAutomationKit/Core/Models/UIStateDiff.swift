import Foundation

/// Read-only comparison of two observed AX element tables. IDs remain local to each snapshot.
/// Unique AX identifiers provide correspondence. Ambiguous or unidentified nodes are emitted
/// as removed/added rather than guessing that an ordinal ID still identifies the same control.
public enum UIStateDiff {
    public struct Change: Codable, Sendable {
        public let before: UIElement
        public let after: UIElement
    }

    public struct Result: Codable, Sendable {
        public let added: [UIElement]
        public let removed: [UIElement]
        public let changed: [Change]
        public let unchangedCount: Int
    }

    public static func compare(before: [UIElement], after: [UIElement]) -> Result {
        func key(_ element: UIElement) -> String? {
            guard let identifier = element.identifier, !identifier.isEmpty else { return nil }
            // Length-prefix the role so arbitrary identifiers cannot collide with a delimiter.
            return "\(element.role.utf8.count):\(element.role)\(identifier)"
        }
        let oldGroups = Dictionary(grouping: before, by: key)
        let newGroups = Dictionary(grouping: after, by: key)
        func topology(_ element: UIElement, in elements: [String: [UIElement]], snapshot: String) -> [String] {
            func reference(_ id: String) -> String {
                guard let candidates = elements[id], candidates.count == 1,
                      let node = candidates.first, let stableKey = key(node), matchedKeys.contains(stableKey)
                else { return "unmatched:\(snapshot):\(id)" }
                return "stable:\(stableKey)"
            }
            return [element.parentId.map(reference) ?? "root"] + element.children.map(reference)
        }
        let oldIDs = Dictionary(grouping: before, by: \.id)
        let newIDs = Dictionary(grouping: after, by: \.id)
        var changed: [Change] = []
        var added: [UIElement] = []
        var removed: [UIElement] = []
        var unchangedCount = 0
        let matchedKeys = Set(oldGroups.keys.compactMap(\.self)).intersection(newGroups.keys.compactMap(\.self))
            .filter { oldGroups[$0]?.count == 1 && newGroups[$0]?.count == 1 }
        for element in before where key(element).map({ !matchedKeys.contains($0) }) ?? true {
            removed.append(element)
        }
        for element in after {
            guard let elementKey = key(element), matchedKeys.contains(elementKey),
                  let previous = oldGroups[elementKey]?.first
            else {
                added.append(element)
                continue
            }
            // Compare hierarchy using stable identities wherever correspondence is proven.
            if previous.role == element.role, previous.title == element.title,
               previous.label == element.label, previous.value == element.value,
               previous.description == element.description, previous.help == element.help,
               previous.roleDescription == element.roleDescription, previous.identifier == element.identifier,
               previous.confidence == element.confidence, previous.frame == element.frame,
               previous.isActionable == element.isActionable, previous.isEnabled == element.isEnabled,
               previous.isSelected == element.isSelected, previous.isValueSettable == element.isValueSettable,
               previous.keyboardShortcut == element.keyboardShortcut,
               topology(previous, in: oldIDs, snapshot: "before") ==
               topology(element, in: newIDs, snapshot: "after")
            {
                unchangedCount += 1
            } else {
                changed.append(Change(before: previous, after: element))
            }
        }
        return Result(added: added, removed: removed, changed: changed, unchangedCount: unchangedCount)
    }
}
