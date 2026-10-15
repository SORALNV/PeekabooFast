import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func nativeWindowID(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_CGSDefaultConnection")
func monitorConnection() -> UInt32
@_silgen_name("CGSCopyManagedDisplaySpaces")
func monitorDisplays(_ connection: UInt32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows")
func monitorWindowSpaces(_ connection: UInt32, _ mask: Int, _ windows: CFArray) -> CFArray?

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let targetPID = Int32(args[0]), let targetWindowID = Int(args[1]) else {
    fatalError("Usage: focus-monitor PID WINDOW_ID [SAMPLES]")
}

let samples = args.count > 2 ? Int(args[2]) ?? 3000 : 3000
var spaceChanges = 0
let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main)
{ _ in MainActor.assumeIsolated { spaceChanges += 1 } }
defer { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
let system = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(system, 0.05)
var previousInventoryDigest: String?
for _ in 0..<samples {
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused)
    var focusedPID: pid_t = 0
    if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
        AXUIElementGetPid(unsafeDowncast(focused, to: AXUIElement.self), &focusedPID)
    }
    var receiver: CFTypeRef?
    var receiverPID: pid_t = 0
    var receiverWindowID: CGWindowID = 0
    var receiverHash: CFHashCode = 0
    if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &receiver) == .success,
       let receiver, CFGetTypeID(receiver) == AXUIElementGetTypeID()
    {
        let element = unsafeDowncast(receiver, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.05)
        AXUIElementGetPid(element, &receiverPID)
        receiverHash = CFHash(element)
        var owningWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &owningWindow) == .success,
           let owningWindow, CFGetTypeID(owningWindow) == AXUIElementGetTypeID()
        {
            _ = nativeWindowID(unsafeDowncast(owningWindow, to: AXUIElement.self), &receiverWindowID)
        }
    }
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let targetIndex = windows.firstIndex {
        ($0[kCGWindowNumber as String] as? Int) == targetWindowID &&
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(targetPID)
    }
    let window = targetIndex.map { windows[$0] }
    let nonTargetWindows = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) != Int(targetPID) }
    let order = nonTargetWindows.map {
        "\($0[kCGWindowOwnerPID as String] as? Int ?? 0):\($0[kCGWindowNumber as String] as? Int ?? 0)"
    }.joined(separator: ",")
    let orderDigest = SHA256.hash(data: Data(order.utf8)).map { String(format: "%02x", $0) }.joined()
    let nonTargetWindowsAbove = targetIndex.map { index in
        windows[..<index].filter { ($0[kCGWindowOwnerPID as String] as? Int) != Int(targetPID) }.count
    } ?? -1
    let visibleWindows = windows.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }
    let visibleNonTargetWindows = visibleWindows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) != Int(targetPID)
    }
    let visibleOrder = visibleNonTargetWindows.map {
        "\($0[kCGWindowOwnerPID as String] as? Int ?? 0):\($0[kCGWindowNumber as String] as? Int ?? 0)"
    }.joined(separator: ",")
    let visibleOrderDigest = SHA256.hash(data: Data(visibleOrder.utf8))
        .map { String(format: "%02x", $0) }.joined()
    let visibleTargetIndex = visibleWindows.firstIndex {
        ($0[kCGWindowNumber as String] as? Int) == targetWindowID &&
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(targetPID)
    }
    let visibleAbove = visibleTargetIndex.map { index in
        visibleWindows[..<index].filter { ($0[kCGWindowOwnerPID as String] as? Int) != Int(targetPID) }.count
    } ?? -1
    // Numeric inventory explains all-window churn without retaining titles or UI contents.
    let inventory = windows.map { info -> [String: Any] in
        [
            "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
            "id": info[kCGWindowNumber as String] as? Int ?? 0,
            "onscreen": info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "layer": info[kCGWindowLayer as String] as? Int ?? 0,
        ]
    }
    let connection = monitorConnection()
    let displayInfo = monitorDisplays(connection) as? [[String: Any]] ?? []
    let activeSpaceIDs = displayInfo.compactMap {
        ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64
    }.sorted()
    let targetSpaceIDs = (monitorWindowSpaces(connection, 7, [targetWindowID] as CFArray) as? [UInt64] ?? []).sorted()
    let targetOnActiveSpace: Any = activeSpaceIDs.isEmpty || targetSpaceIDs.isEmpty
        ? NSNull() : !Set(activeSpaceIDs).isDisjoint(with: targetSpaceIDs)
    let targetApp = NSRunningApplication(processIdentifier: targetPID)
    let lockedSession = CGSessionCopyCurrentDictionary() as? [String: Any]
    let locked: Any = lockedSession.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false } ?? NSNull()
    let geometry = visibleNonTargetWindows.map { info -> [String: Any] in
        [
            "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
            "id": info[kCGWindowNumber as String] as? Int ?? 0,
            "bounds": info[kCGWindowBounds as String] as? [String: Any] ?? [:],
        ]
    }
    let geometryData = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
    let geometryDigest = SHA256.hash(data: geometryData).map { String(format: "%02x", $0) }.joined()
    let bounds = window?[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let pointer = CGEvent(source: nil)?.location ?? .zero
    var sample: [String: Any] = [
        "monitor_schema": 3,
        "time": Date().timeIntervalSince1970,
        "ax_front_pid": focusedPID,
        "front_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
        "target_present": window != nil,
        "target_hidden": targetApp.map { $0.isHidden as Any } ?? NSNull(),
        "target_space_ids": targetSpaceIDs.map(String.init).joined(separator: ","),
        "active_space_ids": activeSpaceIDs.map(String.init).joined(separator: ","),
        "target_on_active_space": targetOnActiveSpace,
        "session_locked": locked,
        "visible_non_target_geometry_sha256": geometryDigest,
        "target_x": bounds["X"] as? Double ?? 0,
        "target_y": bounds["Y"] as? Double ?? 0,
        "target_onscreen": window?[kCGWindowIsOnscreen as String] as? Bool ?? false,
        "target_width": bounds["Width"] as? Double ?? 0,
        "target_height": bounds["Height"] as? Double ?? 0,
        "receiver_hash": receiverHash,
        "receiver_window_id": receiverWindowID,
        "receiver_pid": receiverPID,
        "space_change_count": spaceChanges,
        "visible_non_target_order_sha256": visibleOrderDigest,
        "visible_non_target_windows_above": visibleAbove,
        "non_target_order_sha256": orderDigest,
        "non_target_windows_above": nonTargetWindowsAbove,
        "pointer_x": pointer.x,
        "pointer_y": pointer.y,
    ]
    let inventoryData = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
    let inventoryDigest = SHA256.hash(data: inventoryData).map { String(format: "%02x", $0) }.joined()
    if inventoryDigest != previousInventoryDigest {
        sample["window_inventory"] = inventory
        previousInventoryDigest = inventoryDigest
    }
    let data = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
