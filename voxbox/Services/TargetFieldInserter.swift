import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// The other app we should write into. System-wide focus often points at
/// VoxBox after the hotkey; the remembered destination PID does not.
enum DictationTarget {
    nonisolated(unsafe) static var processIdentifier: pid_t?

    /// Electron / Chromium hide the AX tree until a client sets this.
    /// VoiceOver’s `AXEnhancedUserInterface` is a different switch and moves windows.
    static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString

    static func remember(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        processIdentifier = app.processIdentifier
        enableManualAccessibility(for: app.processIdentifier)
    }

    static func rememberFrontmostIfNeeded() {
        remember(NSWorkspace.shared.frontmostApplication)
    }

    static func enableManualAccessibility(for pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, manualAccessibilityAttribute, kCFBooleanTrue)
    }

    /// Electron only reports the focused composer after accessibility is on
    /// and the app is frontmost.
    static func revealForFieldBind() {
        guard let pid = processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        enableManualAccessibility(for: pid)
        app.activate()
    }
}

/// Writes live dictation into another app’s focused AppKit field by replacing
/// only the span we inserted. Falls back to “not writable” so the HUD + paste
/// path can take over.
final class TargetFieldInserter: @unchecked Sendable {
    private var element: AXUIElement?
    private var spanStart: Int?
    private var spanLength = 0
    private var delivered = ""
    private var usedKeystrokes = false
    private var axRefused = false
    private var keystrokesOnly = false

    var isActive: Bool { element != nil && spanStart != nil }

    /// Bind to the focused field in the remembered destination app.
    @discardableResult
    func begin() -> Bool {
        reset()
        guard AXIsProcessTrusted() else {
            AppLogger.info("Live field bind skipped: Accessibility is off", category: AppLogger.transcription)
            return false
        }
        if DictationTarget.processIdentifier == nil {
            DictationTarget.rememberFrontmostIfNeeded()
        }
        DictationTarget.revealForFieldBind()
        guard let focused = resolveFocusedElement() ?? resolveFocusedElementAfterChromeWakes() else {
            AppLogger.info("Live field bind skipped: no focused element", category: AppLogger.transcription)
            return false
        }
        guard let writable = resolveWritableElement(from: focused) else {
            let role = stringAttribute(focused, kAXRoleAttribute as CFString) ?? "unknown"
            AppLogger.info(
                "Live field bind skipped: focused role \(role) is not writable",
                category: AppLogger.transcription)
            return false
        }
        if isSecure(writable) {
            AppLogger.info("Live field bind skipped: secure field", category: AppLogger.transcription)
            return false
        }

        let value = stringValue(of: writable) ?? ""
        let caret = selectedRange(of: writable)
            ?? CFRange(location: (value as NSString).length, length: 0)
        element = writable
        spanStart = caret.location
        spanLength = 0
        if LiveWriteStrategy.choose(
            hasWebMarkers: hasWebMarkers(writable),
            axValue: value,
            bundleIdentifier: destinationBundleIdentifier()
        ) == .keystrokesOnly {
            keystrokesOnly = true
            axRefused = true
            AppLogger.info(
                "Live field bind will type; AX rewrite is a no-op on this composer",
                category: AppLogger.transcription)
        }
        return true
    }

    /// Replace our span with `text`. Returns false if the field refused.
    @discardableResult
    func update(_ text: String) -> Bool {
        guard element != nil, spanStart != nil else { return false }
        if text == delivered, !text.isEmpty { return true }
        if !usedKeystrokes, !axRefused, writeViaAccessibility(text) {
            delivered = text
            return true
        }
        if !usedKeystrokes, !axRefused {
            axRefused = true
            // Do not re-select. Queued AXSelectedTextRange writes jump the
            // caret to the start; the next suffix then inserts in front of
            // the first words.
            settleEditor()
        }
        return writeViaKeystrokes(text)
    }

    /// True only when the bound field’s span reads back as `text`.
    func containsOurSpan(_ text: String) -> Bool {
        guard let element, let start = spanStart else { return false }
        guard let current = stringValue(of: element) else { return false }
        return FieldSpan.region(current, start: start, length: spanLength) == text
    }

    func revert() {
        if usedKeystrokes {
            perform(KeystrokeDelta.revertPlan(previous: delivered))
        } else if isActive {
            _ = writeViaAccessibility("")
        }
        reset()
    }

    func reset() {
        element = nil
        spanStart = nil
        spanLength = 0
        delivered = ""
        usedKeystrokes = false
        axRefused = false
        keystrokesOnly = false
    }

    // MARK: - Resolve

    /// Chromium builds the AX tree a beat after `AXManualAccessibility` + activate.
    private func resolveFocusedElementAfterChromeWakes() -> AXUIElement? {
        for _ in 0..<6 {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
            if let focused = resolveFocusedElement() { return focused }
        }
        return nil
    }

    private func resolveFocusedElement() -> AXUIElement? {
        if let pid = DictationTarget.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            if let focused = copyElement(app, kAXFocusedUIElementAttribute as CFString) {
                return focused
            }
        }
        return copyElement(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString)
    }

    private func resolveWritableElement(from focused: AXUIElement) -> AXUIElement? {
        if isWritableText(focused) { return focused }
        if let child = findWritableDescendant(focused, depth: 12) { return child }
        if let parent = copyElement(focused, kAXParentAttribute as CFString) {
            if isWritableText(parent) { return parent }
            if let cousin = findWritableDescendant(parent, depth: 8) { return cousin }
        }
        return nil
    }

    private func findWritableDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in children(of: element) {
            if isWritableText(child) { return child }
            if let found = findWritableDescendant(child, depth: depth - 1) { return found }
        }
        return nil
    }

    private func isWritableText(_ element: AXUIElement) -> Bool {
        if isSecure(element) { return false }
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        if role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
        {
            return true
        }
        return stringValue(of: element) != nil && selectedRange(of: element) != nil
    }

    // MARK: - Write strategies

    private func writeViaAccessibility(_ text: String) -> Bool {
        guard let element, let start = spanStart else { return false }
        // Messages reports AXSelectedText unsettable; a set can still return
        // success without changing the field. Skip that path when the runtime
        // contract says it is not writable.
        if isAttributeSettable(element, kAXSelectedTextAttribute as CFString),
            replaceViaSelectedText(text, on: element, start: start),
            containsOurSpan(text)
        {
            return true
        }
        if replaceViaValue(text, on: element, start: start), containsOurSpan(text) {
            return true
        }
        return false
    }

    /// Chromium reports AX sets as success and leaves the composer unchanged.
    /// Unicode key events insert. Do not activate or re-select — that jumps
    /// the caret to the start and the next suffix replaces the whole take.
    /// Notion / Slack also reset the caret after the first burst; move to
    /// the end of the line before typing the next delta.
    private func writeViaKeystrokes(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        restoreKeystrokeCaretIfNeeded()
        switch KeystrokeDelta.livePlan(previous: delivered, next: text) {
        case .none:
            return !delivered.isEmpty
        case .type(let suffix):
            return applyKeystrokes(type: suffix, delivered: text)
        case .delete:
            return !delivered.isEmpty
        case .revise(let count, let suffix):
            typeDelete(times: count)
            return applyKeystrokes(type: suffix, delivered: text)
        }
    }

    private func restoreKeystrokeCaretIfNeeded() {
        guard keystrokesOnly, CaretRestore.shouldMoveToEndOfLine(alreadyTyped: usedKeystrokes)
        else { return }
        moveToEndOfLine()
        settleEditor()
    }

    private func applyKeystrokes(type suffix: String, delivered next: String) -> Bool {
        if !usedKeystrokes {
            AppLogger.info(
                "Live field write used keystrokes",
                category: AppLogger.transcription)
        }
        typeUnicode(suffix)
        delivered = next
        usedKeystrokes = true
        spanLength = (next as NSString).length
        settleEditor()
        return true
    }

    private func perform(_ delta: KeystrokeDelta) {
        switch delta {
        case .none:
            return
        case .type(let suffix):
            typeUnicode(suffix)
        case .delete(let count):
            typeDelete(times: count)
        case .revise(let count, let suffix):
            typeDelete(times: count)
            typeUnicode(suffix)
        }
    }

    private func typeUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in UnicodeTyping.chunks(text) {
            var unichars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            up.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func typeDelete(times: Int) {
        guard times > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<times {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Notion / Slack treat this as end of the current block. Safer than
    /// `AXSelectedTextRange`, which jumps the caret to the start.
    private func moveToEndOfLine() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let rightDown = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: true),
            let rightUp = CGEvent(keyboardEventSource: source, virtualKey: 0x7C, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else { return }
        cmdDown.flags = .maskCommand
        rightDown.flags = .maskCommand
        rightUp.flags = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        rightDown.post(tap: .cghidEventTap)
        rightUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }

    private func settleEditor() {
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }

    private func hasWebMarkers(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let names = names as? [String]
        else { return false }
        return names.contains("AXStartTextMarker") || names.contains("AXDOMIdentifier")
    }

    private func destinationBundleIdentifier() -> String? {
        guard let pid = DictationTarget.processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func replaceViaSelectedText(_ text: String, on element: AXUIElement, start: Int) -> Bool {
        let span = CFRange(location: start, length: spanLength)
        guard setSelectedRange(span, on: element) else { return false }
        guard setSelectedText(text, on: element) else { return false }
        let previousLength = spanLength
        spanLength = (text as NSString).length
        _ = setSelectedRange(CFRange(location: start + spanLength, length: 0), on: element)
        if containsOurSpan(text) { return true }
        spanLength = previousLength
        return false
    }

    private func replaceViaValue(_ text: String, on element: AXUIElement, start: Int) -> Bool {
        guard let current = stringValue(of: element) else { return false }
        let spliced = FieldSpan.splice(
            existing: current, start: start, length: spanLength, replacement: text)
        guard setStringValue(spliced.value, on: element) else { return false }
        let previousLength = spanLength
        spanLength = spliced.newLength
        _ = setSelectedRange(CFRange(location: start + spanLength, length: 0), on: element)
        if containsOurSpan(text) { return true }
        spanLength = previousLength
        return false
    }

    // MARK: - AX

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value)
        guard error == .success, let value else { return [] }
        let array = value as! NSArray
        return array.map { $0 as! AXUIElement }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXSubroleAttribute as CFString)
            == (kAXSecureTextFieldSubrole as String)
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return error == .success && settable.boolValue
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value)
        return AXStringValue.read(error: error, value: value)
    }

    private func setStringValue(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    private func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        var range = CFRange()
        if AXValueGetValue(value as! AXValue, .cfRange, &range) {
            return range
        }
        return nil
    }

    private func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutable = range
        guard let encoded = AXValueCreate(.cfRange, &mutable) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, encoded) == .success
    }
}
