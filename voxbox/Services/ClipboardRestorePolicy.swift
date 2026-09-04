import ApplicationServices
import Foundation

/// Reads the text of whatever element has keyboard focus system-wide, so a
/// paste can be verified without knowing the destination up front.
nonisolated enum FocusedFieldReader {
    static func focusedValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused
        else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }
}

/// When it is safe to put the user's previous clipboard back after a
/// temporary paste. An Electron composer reads the pasteboard on its own
/// schedule, sometimes well after Cmd+V lands (a long backspace burst is
/// still being digested), and restoring an image before that read pastes
/// the image. So: restore as soon as the field visibly contains what we
/// pasted, otherwise only after a generous timeout. Restoring late costs a
/// stale clipboard; restoring early costs the transcript.
nonisolated enum ClipboardRestorePolicy {
    /// Seconds between checks.
    static let pollInterval: TimeInterval = 0.25
    /// Give up verifying and restore anyway after this many checks (≈3 s).
    static let maxAttempts = 12
    /// How much of the pasted text has to be visible to count as landed.
    static let probeLength = 40

    /// How long to wait between a burst of synthetic key events and Cmd+V.
    /// An Electron composer still digesting a burst drops a paste that lands
    /// on top of it (seen in Slack), so the wait grows with the burst. Kept
    /// short: the finish edit now selects rather than deletes, so a dropped
    /// paste leaves the text highlighted, not gone. 0.12 s floor, 2 ms per
    /// key, 0.6 s ceiling.
    static func pasteDelay(afterKeystrokes count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(0.6, 0.12 + Double(count) * 0.002)
    }

    enum Decision: Equatable {
        case restoreNow
        case checkAgain
        case restoreUnverified
    }

    /// The tail of the pasted text, which is what a field shows last.
    static func probe(for pasted: String) -> String {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > probeLength else { return trimmed }
        return String(trimmed.suffix(probeLength))
    }

    static func decide(fieldValue: String?, pasted: String, attempt: Int) -> Decision {
        let probe = probe(for: pasted)
        if let fieldValue, !probe.isEmpty, fieldValue.contains(probe) {
            return .restoreNow
        }
        return attempt + 1 >= maxAttempts ? .restoreUnverified : .checkAgain
    }
}
