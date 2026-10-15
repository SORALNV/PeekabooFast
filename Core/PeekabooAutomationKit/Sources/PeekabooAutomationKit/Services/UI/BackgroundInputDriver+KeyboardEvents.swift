import CoreGraphics
import Foundation
import PeekabooFoundation

extension BackgroundInputDriver {
    static func postKeyboardStroke(
        _ stroke: (keyCode: CGKeyCode, flags: CGEventFlags),
        targetProcessIdentifier: pid_t,
        windowID: Int? = nil) throws
    {
        let plan = try self.keyboardEventPlan(
            keyCode: stroke.keyCode,
            flags: stroke.flags,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)

        for event in plan.modifierKeyDownEvents {
            self.postEvent(event, to: targetProcessIdentifier)
            usleep(1000)
        }

        self.postEvent(plan.primaryKeyDownEvent, to: targetProcessIdentifier)
        usleep(1000)
        self.postEvent(plan.primaryKeyUpEvent, to: targetProcessIdentifier)

        for event in plan.modifierKeyUpEvents {
            usleep(1000)
            self.postEvent(event, to: targetProcessIdentifier)
        }
    }

    static func keyboardEventPlan(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetProcessIdentifier: pid_t,
        windowID: Int? = nil) throws -> KeyboardEventPlan
    {
        let source = CGEventSource(stateID: .privateState)
        let modifiers = self.modifierKeys(for: flags)
        var activeFlags: CGEventFlags = []

        let modifierDownEvents = try modifiers.map { modifier in
            activeFlags.insert(modifier.flag)
            return try self.makeKeyboardEvent(
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: activeFlags,
                source: source,
                targetProcessIdentifier: targetProcessIdentifier,
                windowID: windowID)
        }

        let primaryKeyDownEvent = try self.makeKeyboardEvent(
            keyCode: keyCode,
            keyDown: true,
            flags: flags,
            source: source,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)
        let primaryKeyUpEvent = try self.makeKeyboardEvent(
            keyCode: keyCode,
            keyDown: false,
            flags: flags,
            source: source,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)

        let modifierUpEvents = try modifiers.reversed().map { modifier in
            activeFlags.remove(modifier.flag)
            return try self.makeKeyboardEvent(
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: activeFlags,
                source: source,
                targetProcessIdentifier: targetProcessIdentifier,
                windowID: windowID)
        }

        return KeyboardEventPlan(
            modifierKeyDownEvents: modifierDownEvents,
            primaryKeyDownEvent: primaryKeyDownEvent,
            primaryKeyUpEvent: primaryKeyUpEvent,
            modifierKeyUpEvents: modifierUpEvents)
    }

    private static func makeKeyboardEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?,
        targetProcessIdentifier: pid_t,
        windowID: Int? = nil) throws -> CGEvent
    {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw PeekabooError.operationError(message: "Failed to create background keyboard events")
        }

        event.flags = flags
        try self.stampKeyboardRoutingFields(
            on: event,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)
        return event
    }

    private static func modifierKeys(for flags: CGEventFlags) -> [(keyCode: CGKeyCode, flag: CGEventFlags)] {
        var modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)] = []

        if flags.contains(.maskCommand) {
            modifiers.append((keyCode: 0x37, flag: .maskCommand))
        }
        if flags.contains(.maskShift) {
            modifiers.append((keyCode: 0x38, flag: .maskShift))
        }
        if flags.contains(.maskAlternate) {
            modifiers.append((keyCode: 0x3A, flag: .maskAlternate))
        }
        if flags.contains(.maskControl) {
            modifiers.append((keyCode: 0x3B, flag: .maskControl))
        }
        if flags.contains(.maskSecondaryFn) {
            modifiers.append((keyCode: 0x3F, flag: .maskSecondaryFn))
        }

        return modifiers
    }

    static func postUnicodeCharacter(
        _ character: Character,
        targetProcessIdentifier: pid_t,
        windowID: Int? = nil) throws
    {
        let events = try self.unicodeKeyboardEvents(
            for: character,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)
        self.postEvent(events.keyDown, to: targetProcessIdentifier)
        usleep(1000)
        self.postEvent(events.keyUp, to: targetProcessIdentifier)
    }

    static func unicodeKeyboardEvents(
        for character: Character,
        targetProcessIdentifier: pid_t,
        windowID: Int? = nil,
        makeEvent: (CGEventSource?, Bool) -> CGEvent? = {
            CGEvent(keyboardEventSource: $0, virtualKey: 0, keyDown: $1)
        }) throws -> (keyDown: CGEvent, keyUp: CGEvent)
    {
        let string = String(character)
        let source = CGEventSource(stateID: .privateState)

        guard let keyDown = makeEvent(source, true),
              let keyUp = makeEvent(source, false)
        else {
            throw PeekabooError.operationError(message: "Failed to create background unicode keyboard events")
        }

        let chars = Array(string.utf16)
        chars.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress!)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress!)
        }

        // Literal text must not inherit held user modifiers and become a shortcut.
        keyDown.flags = []
        keyUp.flags = []

        try self.stampKeyboardRoutingFields(
            on: keyDown,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)
        try self.stampKeyboardRoutingFields(
            on: keyUp,
            targetProcessIdentifier: targetProcessIdentifier,
            windowID: windowID)
        return (keyDown, keyUp)
    }

    static func stampKeyboardRoutingFields(
        on event: CGEvent, targetProcessIdentifier: pid_t, windowID: Int? = nil) throws
    {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetProcessIdentifier))
        if let windowID {
            guard windowID > 0, CGWindowID(exactly: windowID) != nil,
                  let windowField = CGEventField(rawValue: 51)
            else { throw PeekabooError.invalidInput("Keyboard routing requires a valid exact window ID") }
            event.setIntegerValueField(windowField, value: Int64(windowID))
        }
    }
}
