import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// Side effects the live field writer needs from the destination app:
/// Accessibility reads and writes (UTF-16 offsets, matching
/// `AXSelectedTextRange`) and HID key events. `TargetFieldInserter` is a
/// pure state machine over this protocol so tests can drive it with a fake
/// editor that models caret resets and visual-line wrapping.
protocol FieldWriter: AnyObject {
    /// `nil` means the read failed. An empty field reads as `""`.
    func readValue() -> String?
    func readSelection() -> CFRange?
    func isSelectedTextSettable() -> Bool
    func setSelection(_ range: CFRange) -> Bool
    func setSelectedText(_ text: String) -> Bool
    func setValue(_ text: String) -> Bool

    /// Unicode key events at the caret.
    func type(_ text: String)
    /// Backspace `count` times. One Backspace deletes one grapheme cluster.
    func deleteBackward(count: Int)
    func moveCaret(_ move: CaretMove)
    /// Give the destination a beat between a caret move and the next burst.
    /// Never spins the run loop: that is what let the next snapshot re-enter
    /// a half-finished write.
    func settle()
}

/// Production writer over one `AXUIElement`.
final class AXFieldWriter: FieldWriter {
    let element: AXUIElement
    /// Error code of the last failed AX call, for diagnostics.
    private(set) var lastError: AXError = .success

    init(element: AXUIElement) {
        self.element = element
    }

    // MARK: Accessibility

    func readValue() -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if error != .success && error != .noValue { lastError = error }
        return AXStringValue.read(error: error, value: value)
    }

    func readSelection() -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value else {
            lastError = error
            return nil
        }
        var range = CFRange()
        if AXValueGetValue(value as! AXValue, .cfRange, &range) {
            return range
        }
        return nil
    }

    func isSelectedTextSettable() -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    func setSelection(_ range: CFRange) -> Bool {
        var mutable = range
        guard let encoded = AXValueCreate(.cfRange, &mutable) else { return false }
        return record(
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, encoded))
    }

    func setSelectedText(_ text: String) -> Bool {
        record(
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef))
    }

    func setValue(_ text: String) -> Bool {
        record(
            AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, text as CFTypeRef))
    }

    private func record(_ error: AXError) -> Bool {
        if error != .success { lastError = error }
        return error == .success
    }

    // MARK: HID

    /// `CGEventKeyboardSetUnicodeString` silently truncates; post in chunks.
    ///
    /// Flags are cleared on every event. Events created from the HID state
    /// inherit whatever modifiers are live at that instant (the user's
    /// held hotkey, or a Cmd we just pressed for a caret move), and a
    /// Unicode event rides on virtual key 0 (`A`), so an inherited Cmd
    /// becomes Cmd+A / Cmd+Space in the destination.
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in UnicodeTyping.chunks(text) {
            var unichars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            up.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            else { continue }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Cmd+→ (end of visual line) or Cmd+↓ (end of document). Slack and
    /// Notion treat Cmd+↓ as end of the current block, which is where our
    /// text is after they reset the caret.
    func moveCaret(_ move: CaretMove) {
        let arrow: CGKeyCode
        switch move {
        case .endOfLine: arrow = 0x7C  // right arrow
        case .endOfDocument: arrow = 0x7D  // down arrow
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let arrowDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true),
            let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else { return }
        cmdDown.flags = .maskCommand
        arrowDown.flags = .maskCommand
        arrowUp.flags = .maskCommand
        cmdUp.flags = []
        cmdDown.post(tap: .cghidEventTap)
        arrowDown.post(tap: .cghidEventTap)
        arrowUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }

    /// Key events are queued in order by the destination, and the write
    /// pipeline already leaves a gap between snapshots, so nothing to do.
    func settle() {}
}
