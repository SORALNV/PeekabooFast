import ApplicationServices
import AXorcist
import Foundation

/// Some applications expose an empty AXWindows array while AXMainWindow/AXFocusedWindow remain valid.
/// Recover only owner-checked AXWindow references, never a title/bounds guess or a different process.
enum AXKnownWindowCandidates {
    static func isSuccessfullyEmptyInventory(error: AXError, value: CFTypeRef?) -> Bool {
        guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID(),
              let windows = value as? [Any]
        else { return false }
        return windows.isEmpty
    }

    static func supplement<Window>(
        listed: [Window],
        main: () -> Window?,
        focused: () -> Window?,
        isValid: (Window) -> Bool,
        equal: (Window, Window) -> Bool) -> [Window]
    {
        guard listed.isEmpty else { return listed }
        var result: [Window] = []
        for candidate in [main(), focused()].compactMap(\.self) where isValid(candidate) {
            if !result.contains(where: { equal($0, candidate) }) {
                result.append(candidate)
            }
        }
        return result
    }

    static func supplement(
        listed: [AXUIElement],
        application: AXUIElement,
        deadline: ContinuousClock.Instant) -> [AXUIElement]
    {
        guard listed.isEmpty else { return listed }
        var owner: pid_t = 0
        guard AXUIElementGetPid(application, &owner) == .success else { return listed }
        func read(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard seconds > 0 else { return nil }
            guard AXUIElementSetMessagingTimeout(element, Float(min(seconds, 0.2))) == .success else { return nil }
            defer { AXUIElementSetMessagingTimeout(element, 0) }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }
        // Some callers normalize an unsuccessful array read to []. Confirm that AXWindows
        // really is a successfully read empty array before consulting the main/focused handles.
        guard self.isSuccessfullyEmptyInventory(error: .success, value: read(kAXWindowsAttribute, from: application))
        else { return listed }
        func window(_ attribute: String) -> AXUIElement? {
            guard let value = read(attribute, from: application), CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        return self.supplement(
            listed: listed,
            main: { window(kAXMainWindowAttribute) },
            focused: { window(kAXFocusedWindowAttribute) },
            isValid: { candidate in
                var candidateOwner: pid_t = 0
                return AXUIElementGetPid(candidate, &candidateOwner) == .success && candidateOwner == owner &&
                    read(kAXRoleAttribute, from: candidate) as? String == kAXWindowRole
            },
            equal: { CFEqual($0, $1) })
    }

    @MainActor
    static func elements(application: Element, timeout: Float) -> [Element]? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(Double(timeout)))
        guard let listed = application.windowsWithTimeout(timeout: timeout) else { return nil }
        return self.supplement(
            listed: listed.map(\.underlyingElement), application: application.underlyingElement, deadline: deadline)
            .map { Element($0) }
    }
}
