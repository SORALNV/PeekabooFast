import ApplicationServices
import CoreGraphics
import Foundation

/// Chromium may retain an old serialized AX tree while hidden. A web-area AX hit test
/// requests a renderer round trip without clicking, moving the pointer, or activating a window.
/// The returned hit is deliberately discarded: it is neither a target nor proof of completion.
enum ElectronAXReadRefresh {
    /// Used by mutation readback, which starts at the retained editor rather than a whole tree.
    /// All references stay in the bounded AX worker; no hit reference becomes input authority.
    static func requestFromAncestor(
        of element: AXUIElement,
        expected: FocusedElementIdentity,
        deadline: ContinuousClock.Instant)
    {
        let point = CGPoint(x: expected.frame.midX, y: expected.frame.midY)
        guard !expected.frame.isEmpty, point.x.isFinite, point.y.isFinite else { return }
        var current = element
        var visited: [AXUIElement] = []
        for _ in 0..<128 {
            guard ContinuousClock.now < deadline,
                  !visited.contains(where: { CFEqual($0, current) })
            else { return }
            visited.append(current)
            var owner: pid_t = 0
            guard AXUIElementGetPid(current, &owner) == .success, owner == expected.processIdentifier else { return }
            let role = DetachedExactWindowFocusReader.attribute(
                kAXRoleAttribute,
                of: current,
                deadline: deadline) as? String
            if role == "AXWebArea" {
                guard let rawWindow = DetachedExactWindowFocusReader.attribute(
                    kAXWindowAttribute, of: current, deadline: deadline),
                    CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
                else { return }
                let window = unsafeDowncast(rawWindow, to: AXUIElement.self)
                guard self.prepare(window, deadline: deadline),
                      AXWindowIDResolver.windowID(of: window).map(Int.init) == expected.windowID,
                      self.prepare(current, deadline: deadline)
                else { return }
                var ignored: AXUIElement?
                _ = AXUIElementCopyElementAtPosition(current, Float(point.x), Float(point.y), &ignored)
                return
            }
            if role == "AXWindow" {
                return
            }
            guard let parent = DetachedExactWindowFocusReader.attribute(
                kAXParentAttribute, of: current, deadline: deadline),
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
    }

    private static func prepare(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        guard ContinuousClock.now < deadline else { return false }
        let parts = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard seconds > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.05, seconds))) == .success
    }

    static func request(
        role: String,
        bounds: (window: CGRect, element: CGRect),
        deadline: ContinuousClock.Instant,
        ownsExactWindow: () -> Bool,
        hitTest: (CGPoint) -> Void) -> Bool
    {
        guard role == "AXWebArea", ContinuousClock.now < deadline else { return false }
        let bounds = bounds.window.intersection(bounds.element)
        guard !bounds.isNull, !bounds.isEmpty,
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              ownsExactWindow(), ContinuousClock.now < deadline
        else { return false }
        hitTest(CGPoint(x: bounds.midX, y: bounds.midY))
        return true
    }
}
