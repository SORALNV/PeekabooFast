import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
func exactWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let pid = CommandLine.arguments.dropFirst().first.flatMap(Int32.init) ?? 0
guard pid > 0 else { fatalError("Usage: window-diagnostic PID") }
let application = AXUIElementCreateApplication(pid)
var listed: CFTypeRef?
let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &listed)
print("AXWindows status=\(result.rawValue) count=\((listed as? [AXUIElement])?.count ?? -1)")
for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, attribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { continue }
    let window = unsafeDowncast(raw, to: AXUIElement.self)
    var windowID: CGWindowID = 0
    let idResult = exactWindowID(window, &windowID)
    var minimized: CFTypeRef?
    let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
    print("\(attribute): window_id=\(windowID) id_status=\(idResult.rawValue) " +
        "AXMinimized=\(String(describing: minimized)) status=\(minResult.rawValue)")
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        for window in content.windows where window.owningApplication?.processID == pid {
            print("SCWindow id=\(window.windowID) isOnScreen=\(window.isOnScreen) bounds=\(window.frame)")
        }
    } catch { print(error) }
    exit(0)
}

RunLoop.main.run()
