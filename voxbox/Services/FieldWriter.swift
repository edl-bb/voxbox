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
    /// Put `text` on the clipboard and press Cmd+V. Composers treat pasted
    /// newlines as soft breaks, where a typed Return would send.
    /// Paste `text` at the caret, then move the caret `offset` graphemes
    /// (positive = right). When `caretAt` is given, the caret is placed at
    /// that UTF-16 offset immediately before the paste: composers snap the
    /// caret to the start after a synthetic key burst, and a deferred paste
    /// must not land there. The move is sequenced after the paste even when
    /// the paste is deferred.
    func paste(_ text: String, thenMoveCaretBy offset: Int, caretAt location: Int?)
    /// Left/Right arrow `abs(offset)` times.
    func moveCaret(by offset: Int)
    func moveCaret(_ move: CaretMove)
    /// Give the destination a beat between a caret move and the next burst.
    /// Never spins the run loop: that is what let the next snapshot re-enter
    /// a half-finished write.
    func settle()
}

extension FieldWriter {
    func paste(_ text: String) {
        paste(text, thenMoveCaretBy: 0, caretAt: nil)
    }
}

/// Production writer over one `AXUIElement`.
final class AXFieldWriter: FieldWriter {
    let element: AXUIElement
    /// Error code of the last failed AX call, for diagnostics.
    private(set) var lastError: AXError = .success

    /// A busy renderer (Electron mid-layout) can hold an AX request for the
    /// default six seconds; that would stall the main thread per write.
    static let messagingTimeout: Float = 0.25

    init(element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
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
            keystrokesSinceLastPaste += 1
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

    /// Key events posted since the last paste; sets the settle time before
    /// the next Cmd+V.
    private var keystrokesSinceLastPaste = 0

    func deleteBackward(count: Int) {
        guard count > 0 else { return }
        keystrokesSinceLastPaste += count
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

    func moveCaret(by offset: Int) {
        Self.postArrows(by: offset)
        keystrokesSinceLastPaste += abs(offset)
    }

    private static func postArrows(by offset: Int) {
        guard offset != 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = offset < 0 ? 0x7B : 0x7C
        for _ in 0..<abs(offset) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { continue }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Same clipboard contract as auto-paste: the previous clipboard comes
    /// back after the destination has read ours, when the user has that on.
    /// The text goes on the pasteboard now; Cmd+V waits out the key burst
    /// that preceded it so the composer is idle when the paste arrives, and
    /// any caret move requested for after the paste is posted right behind it.
    func paste(_ text: String, thenMoveCaretBy offset: Int, caretAt location: Int?) {
        let restore = UserDefaults.standard.object(forKey: "restoreClipboardAfterAutoPaste") as? Bool ?? true
        let previous: ClipboardService.ClipboardSnapshot?
        if restore {
            previous = ClipboardService.shared.copyForTemporaryPaste(text: text)
        } else {
            previous = nil
            ClipboardService.shared.copy(text: text)
        }
        let delay = ClipboardRestorePolicy.pasteDelay(afterKeystrokes: keystrokesSinceLastPaste)
        AppLogger.debug(
            "paste after \(keystrokesSinceLastPaste) key events; waiting \(Int(delay * 1000)) ms",
            category: AppLogger.clipboard)
        keystrokesSinceLastPaste = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Something else may have taken the pasteboard during the wait.
            if NSPasteboard.general.string(forType: .string) != text {
                ClipboardService.shared.copy(text: text, concealed: previous != nil)
            }
            // Chrome, Notion and Slack snap the caret to the start of the
            // composer after a key burst; put it back where the paste belongs.
            // Chromium honours a selection-range set as a caret jump.
            if let location, let self {
                let placed = self.setSelection(CFRange(location: location, length: 0))
                AppLogger.debug("paste caret re-placed at \(location) ok=\(placed)", category: AppLogger.clipboard)
            }
            ClipboardService.shared.paste()
            if offset != 0 {
                // Cmd+V itself is posted on the next main-queue turn; queue the
                // arrows behind it the same way.
                DispatchQueue.main.async { Self.postArrows(by: offset) }
            }
            guard let previous else { return }
            self?.scheduleRestore(previous, pasted: text, attempt: 0)
        }
    }

    /// Restore the previous clipboard once the field shows the pasted text,
    /// or after `ClipboardRestorePolicy.maxAttempts` polls when the field
    /// cannot be read (Chromium contenteditable reports an empty AXValue).
    private func scheduleRestore(_ previous: ClipboardService.ClipboardSnapshot, pasted: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardRestorePolicy.pollInterval) { [weak self] in
            let value = self?.readValue()
            switch ClipboardRestorePolicy.decide(fieldValue: value, pasted: pasted, attempt: attempt) {
            case .restoreNow:
                AppLogger.debug("paste verified in field after \(attempt + 1) polls; restoring clipboard", category: AppLogger.clipboard)
                ClipboardService.shared.restore(previous, ifCurrentStringMatches: pasted)
            case .restoreUnverified:
                AppLogger.debug("paste not verifiable; restoring clipboard after timeout", category: AppLogger.clipboard)
                ClipboardService.shared.restore(previous, ifCurrentStringMatches: pasted)
            case .checkAgain:
                self?.scheduleRestore(previous, pasted: pasted, attempt: attempt + 1)
            }
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
