import ApplicationServices
import AppKit
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

    static var bundleIdentifier: String? {
        guard let pid = processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Every Electron app ships `Electron Framework.framework` inside its
    /// bundle. Catches composers our bundle list has never heard of.
    static var isElectronApp: Bool {
        guard let pid = processIdentifier,
            let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
        else { return false }
        return isElectronBundle(at: url)
    }

    static func isElectronBundle(at bundleURL: URL) -> Bool {
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// The destination still owns the keyboard. Typing into anything else
    /// would put the take in the wrong app.
    static var isFrontmost: Bool {
        guard let pid = processIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
}

/// What one snapshot write did to the field.
nonisolated enum LiveWriteOutcome: Equatable {
    enum Kind: Equatable {
        case axReplace
        case append
    }

    case wrote(Kind, chars: Int)
    case held(AppendPlan.HoldReason)
    /// Field or focus changed under us; no further writes this take.
    case frozen(LiveFreezeReason)
    case notBound
}

nonisolated enum LiveFreezeReason: Equatable {
    /// The span no longer reads back as what we wrote.
    case drift
    /// AX set stopped landing after we had already written.
    case axRefused
    /// Destination app lost the keyboard.
    case notFrontmost
}

/// Where the transcript ended up at the end of a take.
nonisolated enum LiveDelivery: Equatable {
    /// Nothing of ours is in the field; the normal paste path delivers.
    case notWritten
    /// The field verifiably holds the cleaned transcript.
    case inField
    /// Keystroke target: the field holds the spoken words; the cleaned
    /// transcript differs and is on the clipboard.
    case rawInField
    /// Keystroke target: the field holds part of the take (stable words up
    /// to a revision we could not extend); full transcript on the clipboard.
    case partialInField
    /// Something of ours may be in the field but we cannot verify or fix it;
    /// transcript on the clipboard, no paste.
    case unverified
}

/// How live words reach the user during the take.
nonisolated enum LiveDeliveryMode: Equatable {
    case none
    /// AX rewrite: stable and revisable words both land in the field.
    case fullText
    /// Keystrokes: only stable words land; the revisable tail is HUD-only.
    case stableOnly
}

nonisolated struct LiveWriteInput: Equatable {
    var fullText: String
    var stable: String

    init(_ snapshot: LiveTranscriptSnapshot) {
        fullText = snapshot.fullText
        stable = snapshot.stable
    }

    init(fullText: String, stable: String) {
        self.fullText = fullText
        self.stable = stable
    }
}

/// Writes live dictation into another app’s focused field. Pure state
/// machine over a `FieldWriter`; production binds an `AXFieldWriter` in
/// `begin()`, tests call `bind(...)` with a fake.
///
/// Two strategies, fixed at bind:
/// - `.accessibilityRewrite`: replace our span with the full snapshot each
///   time, verified by read-back. Any drift freezes the take.
/// - `.keystrokesOnly`: append only the newly committed (stable) words.
///   Nothing is ever deleted mid-take.
final class TargetFieldInserter {
    private(set) var writer: FieldWriter?
    private(set) var strategy: LiveWriteStrategy = .accessibilityRewrite
    private(set) var bundleIdentifier: String?
    private(set) var isElectronApp = false
    /// Web content: never move the selection until a write has verified,
    /// because Chromium honours `AXSelectedTextRange` sets (jumping the
    /// caret) while ignoring `AXSelectedText` and `AXValue` sets.
    private(set) var isWebContent = false
    private var isTargetFrontmost: () -> Bool = { true }

    private var spanStart: Int?
    private var spanLength = 0
    /// The text we believe is in the field.
    private(set) var delivered = ""
    private(set) var hasTyped = false
    private(set) var frozen: LiveFreezeReason?

    var isActive: Bool { writer != nil && spanStart != nil }

    var deliveryMode: LiveDeliveryMode {
        guard isActive, frozen == nil else { return .none }
        return strategy == .keystrokesOnly ? .stableOnly : .fullText
    }

    // MARK: - Bind

    /// Bind to the focused field in the remembered destination app.
    @discardableResult
    func begin() async -> Bool {
        reset()
        guard AXIsProcessTrusted() else {
            log("bind skipped: Accessibility is off")
            return false
        }
        if DictationTarget.processIdentifier == nil {
            DictationTarget.rememberFrontmostIfNeeded()
        }
        DictationTarget.revealForFieldBind()
        var focused = resolveFocusedElement()
        if focused == nil {
            focused = await resolveFocusedElementAfterChromeWakes()
        }
        guard let focused else {
            log("bind skipped: no focused element")
            return false
        }
        guard let writable = resolveWritableElement(from: focused) else {
            let role = stringAttribute(focused, kAXRoleAttribute as CFString) ?? "unknown"
            log("bind skipped: focused role \(role) is not writable")
            return false
        }
        if isSecure(writable) {
            log("bind skipped: secure field")
            return false
        }

        let axWriter = AXFieldWriter(element: writable)
        let value = axWriter.readValue() ?? ""
        let caret = axWriter.readSelection() ?? CFRange(location: (value as NSString).length, length: 0)
        let bundle = DictationTarget.bundleIdentifier
        let electron = DictationTarget.isElectronApp
        let web = hasWebMarkers(writable)
        let chosen = LiveWriteStrategy.choose(
            hasWebMarkers: web,
            axValue: value,
            bundleIdentifier: bundle,
            isElectronApp: electron)
        bind(
            writer: axWriter,
            strategy: chosen,
            bundleIdentifier: bundle,
            spanStart: caret.location,
            isElectronApp: electron,
            isWebContent: web,
            isTargetFrontmost: { DictationTarget.isFrontmost })
        log(
            "bind strategy=\(chosen) spanStart=\(caret.location) valueLen=\((value as NSString).length) "
                + "bundle=\(bundle ?? "?") electron=\(electron) web=\(web) "
                + "caretRestore=\(String(describing: caretRestoreMove(hasTyped: true)))"
        )
        return true
    }

    /// Bind to an already-resolved writer. Used by `begin()` and by tests.
    func bind(
        writer: FieldWriter,
        strategy: LiveWriteStrategy,
        bundleIdentifier: String?,
        spanStart: Int,
        isElectronApp: Bool = false,
        isWebContent: Bool = false,
        isTargetFrontmost: @escaping () -> Bool = { true }
    ) {
        reset()
        self.writer = writer
        self.strategy = strategy
        self.bundleIdentifier = bundleIdentifier
        self.spanStart = spanStart
        self.isElectronApp = isElectronApp
        self.isWebContent = isWebContent
        self.isTargetFrontmost = isTargetFrontmost
    }

    private func caretRestoreMove(hasTyped: Bool) -> CaretMove? {
        CaretRestore.move(forBundle: bundleIdentifier, isElectronApp: isElectronApp, hasTyped: hasTyped)
    }

    func reset() {
        writer = nil
        strategy = .accessibilityRewrite
        bundleIdentifier = nil
        isElectronApp = false
        isWebContent = false
        isTargetFrontmost = { true }
        spanStart = nil
        spanLength = 0
        delivered = ""
        hasTyped = false
        frozen = nil
    }

    // MARK: - Streaming writes

    @discardableResult
    func update(_ input: LiveWriteInput) -> LiveWriteOutcome {
        guard let writer, let start = spanStart else { return .notBound }
        if let frozen { return .frozen(frozen) }

        switch strategy {
        case .accessibilityRewrite:
            return updateViaAccessibility(input, writer: writer, start: start)
        case .keystrokesOnly:
            return appendStable(input.stable, writer: writer)
        }
    }

    private func updateViaAccessibility(
        _ input: LiveWriteInput, writer: FieldWriter, start: Int
    ) -> LiveWriteOutcome {
        let text = input.fullText
        if text == delivered { return .held(.unchanged) }
        guard text.isEmpty == false else { return .held(.unchanged) }

        guard let before = writer.readValue() else {
            return freeze(.drift, detail: "value unreadable")
        }
        guard FieldSpan.region(before, start: start, length: spanLength) == delivered else {
            return freeze(
                .drift,
                detail: "expected=\((delivered as NSString).length) found=\(FieldSpan.region(before, start: start, length: spanLength).map { ($0 as NSString).length } ?? -1)"
            )
        }

        if writeViaAccessibility(text, writer: writer, start: start) {
            delivered = text
            log("write ax span=\(start)+\(spanLength) ok")
            return .wrote(.axReplace, chars: (text as NSString).length)
        }

        // Nothing of ours is in the field yet, and the field is unchanged:
        // this composer ignores AX sets (Chromium). Type instead, once.
        if delivered.isEmpty, !hasTyped, writer.readValue() == before {
            strategy = .keystrokesOnly
            log("write ax refused before first write; switching to keystrokes")
            return appendStable(input.stable, writer: writer)
        }
        return freeze(.axRefused, detail: "delivered=\((delivered as NSString).length)")
    }

    private func appendStable(_ stable: String, writer: FieldWriter) -> LiveWriteOutcome {
        switch AppendPlan.plan(typed: delivered, stable: stable) {
        case .hold(let reason):
            if reason == .stableDiverged {
                log("hold reason=stableDiverged typed=\((delivered as NSString).length) stable=\((stable as NSString).length)")
            }
            return .held(reason)
        case .append(let tail):
            guard isTargetFrontmost() else {
                log("hold reason=notFrontmost")
                return .held(.stableDiverged)
            }
            typeTail(tail, writer: writer)
            delivered = stable
            log("append typed=\((delivered as NSString).length) tail=\((tail as NSString).length)")
            return .wrote(.append, chars: (tail as NSString).length)
        }
    }

    private func typeTail(_ tail: String, writer: FieldWriter) {
        if let move = caretRestoreMove(hasTyped: hasTyped) {
            writer.moveCaret(move)
            writer.settle()
        }
        writer.type(tail)
        hasTyped = true
        spanLength = (delivered as NSString).length + (tail as NSString).length
        writer.settle()
    }

    // MARK: - Finish

    /// Put the final transcript in place. `raw` is what the engine heard;
    /// `cleaned` is what should end up in the field.
    func finalize(raw: String, cleaned: String) -> LiveDelivery {
        guard let writer, let start = spanStart else { return .notWritten }
        defer { reset() }

        if let frozen {
            let result: LiveDelivery = delivered.isEmpty && !hasTyped ? .notWritten : .unverified
            log("finalize frozen=\(frozen) result=\(result)")
            return result
        }

        switch strategy {
        case .accessibilityRewrite:
            return finalizeViaAccessibility(cleaned, writer: writer, start: start)
        case .keystrokesOnly:
            return finalizeViaKeystrokes(raw: raw, cleaned: cleaned, writer: writer)
        }
    }

    private func finalizeViaAccessibility(
        _ cleaned: String, writer: FieldWriter, start: Int
    ) -> LiveDelivery {
        if !delivered.isEmpty {
            guard let current = writer.readValue(),
                FieldSpan.region(current, start: start, length: spanLength) == delivered
            else {
                log("finalize ax drift result=unverified")
                return .unverified
            }
        }
        if cleaned == delivered {
            log("finalize ax unchanged result=inField")
            return .inField
        }
        if writeViaAccessibility(cleaned, writer: writer, start: start) {
            log("finalize ax replaced \((delivered as NSString).length)->\((cleaned as NSString).length) result=inField")
            return .inField
        }
        if delivered.isEmpty {
            log("finalize ax first write refused result=notWritten")
            return .notWritten
        }
        if writeViaAccessibility("", writer: writer, start: start) {
            log("finalize ax replace failed; span cleared result=notWritten")
            return .notWritten
        }
        log("finalize ax replace and clear failed result=unverified")
        return .unverified
    }

    private func finalizeViaKeystrokes(
        raw: String, cleaned: String, writer: FieldWriter
    ) -> LiveDelivery {
        guard hasTyped, !delivered.isEmpty else {
            log("finalize keys nothing typed result=notWritten")
            return .notWritten
        }
        guard isTargetFrontmost() else {
            log("finalize keys target not frontmost result=unverified")
            return .unverified
        }

        // First bring the field up to the complete spoken transcript.
        var completedRaw = false
        switch AppendPlan.plan(typed: delivered, stable: raw) {
        case .append(let tail):
            typeTail(tail, writer: writer)
            delivered = raw
            completedRaw = true
        case .hold(.unchanged):
            completedRaw = true
        case .hold(.stableDiverged):
            completedRaw = false
        }

        if cleaned == delivered {
            log("finalize keys cleaned==typed result=inField")
            return .inField
        }
        if cleaned.hasPrefix(delivered) {
            let tail = (cleaned as NSString).substring(from: (delivered as NSString).length)
            typeTail(tail, writer: writer)
            delivered = cleaned
            log("finalize keys typed cleaned tail=\((tail as NSString).length) result=inField")
            return .inField
        }
        let result: LiveDelivery = completedRaw ? .rawInField : .partialInField
        log(
            "finalize keys typed=\((delivered as NSString).length) raw=\((raw as NSString).length) "
                + "cleaned=\((cleaned as NSString).length) result=\(result)")
        return result
    }

    /// Remove what we wrote (cancelled take).
    func revert() {
        defer { reset() }
        guard let writer, let start = spanStart else { return }
        switch strategy {
        case .accessibilityRewrite:
            guard !delivered.isEmpty, frozen == nil else { return }
            if let current = writer.readValue(),
                FieldSpan.region(current, start: start, length: spanLength) == delivered
            {
                let ok = writeViaAccessibility("", writer: writer, start: start)
                log("revert ax ok=\(ok)")
            } else {
                log("revert ax skipped: drift")
            }
        case .keystrokesOnly:
            guard hasTyped, !delivered.isEmpty, isTargetFrontmost() else { return }
            if case .delete(let count) = KeystrokeDelta.revertPlan(previous: delivered) {
                if let move = caretRestoreMove(hasTyped: true) {
                    writer.moveCaret(move)
                    writer.settle()
                }
                writer.deleteBackward(count: count)
                log("revert keys backspaces=\(count)")
            }
        }
    }

    // MARK: - AX replace

    private func writeViaAccessibility(_ text: String, writer: FieldWriter, start: Int) -> Bool {
        // Web content: a value write can be verified before the selection is
        // touched. The selected-text path has to move the selection first,
        // and Chromium applies that even when it ignores the text set.
        if isWebContent {
            return replaceViaValue(text, writer: writer, start: start)
        }
        // Messages reports AXSelectedText unsettable; a set can still return
        // success without changing the field. Skip that path when the runtime
        // contract says it is not writable.
        if writer.isSelectedTextSettable(),
            replaceViaSelectedText(text, writer: writer, start: start)
        {
            return true
        }
        return replaceViaValue(text, writer: writer, start: start)
    }

    private func replaceViaSelectedText(_ text: String, writer: FieldWriter, start: Int) -> Bool {
        let span = CFRange(location: start, length: spanLength)
        guard writer.setSelection(span) else { return false }
        guard writer.setSelectedText(text) else { return false }
        let newLength = (text as NSString).length
        _ = writer.setSelection(CFRange(location: start + newLength, length: 0))
        guard regionReads(text, writer: writer, start: start, length: newLength) else { return false }
        spanLength = newLength
        return true
    }

    private func replaceViaValue(_ text: String, writer: FieldWriter, start: Int) -> Bool {
        guard let current = writer.readValue() else { return false }
        let spliced = FieldSpan.splice(
            existing: current, start: start, length: spanLength, replacement: text)
        guard writer.setValue(spliced.value) else { return false }
        // Verify before parking the caret: on a composer that ignored the
        // value set, a selection set would still move the user's caret.
        guard regionReads(text, writer: writer, start: start, length: spliced.newLength) else {
            return false
        }
        _ = writer.setSelection(CFRange(location: start + spliced.newLength, length: 0))
        spanLength = spliced.newLength
        return true
    }

    private func regionReads(_ text: String, writer: FieldWriter, start: Int, length: Int) -> Bool {
        guard let current = writer.readValue() else { return false }
        return FieldSpan.region(current, start: start, length: length) == text
    }

    private func freeze(_ reason: LiveFreezeReason, detail: String) -> LiveWriteOutcome {
        frozen = reason
        log("write frozen reason=\(reason) \(detail)")
        return .frozen(reason)
    }

    private func log(_ message: String) {
        AppLogger.debug("live field \(message)", category: AppLogger.transcription)
    }

    // MARK: - Resolve

    /// Chromium builds the AX tree a beat after `AXManualAccessibility` + activate.
    private func resolveFocusedElementAfterChromeWakes() async -> AXUIElement? {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(50))
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
        let probe = AXFieldWriter(element: element)
        return probe.readValue() != nil && probe.readSelection() != nil
    }

    private func hasWebMarkers(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let names = names as? [String]
        else { return false }
        return names.contains("AXStartTextMarker") || names.contains("AXDOMIdentifier")
    }

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
}
