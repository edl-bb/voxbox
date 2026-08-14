import ApplicationServices
import Cocoa

class ClipboardService {
    static let shared = ClipboardService()

    struct ClipboardSnapshot {
        fileprivate let items: [ClipboardItemSnapshot]
    }

    fileprivate struct ClipboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private init() {}

    /// Pasteboard managers treat this type as "do not record" (nspasteboard.org).
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // Copy text to system clipboard.
    // `concealed` marks the entry so clipboard-history utilities skip it —
    // used for transient auto-paste copies that will be restored right after.
    func copy(text: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            pasteboard.setString("", forType: Self.concealedType)
        }

        // Verify write — never log the clipboard content itself.
        if pasteboard.string(forType: .string) != text {
            AppLogger.warning("Clipboard write verification failed", category: AppLogger.clipboard)
        }
    }

    @discardableResult
    func copyForTemporaryPaste(text: String) -> ClipboardSnapshot {
        let snapshot = currentSnapshot()
        copy(text: text, concealed: true)
        return snapshot
    }

    func restore(_ snapshot: ClipboardSnapshot, ifCurrentStringMatches expectedText: String) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) == expectedText else {
            print("Skipping clipboard restore because pasteboard changed after paste")
            return
        }

        restore(snapshot)
    }

    private func currentSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items: [ClipboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }

            return ClipboardItemSnapshot(dataByType: dataByType)
        } ?? []

        return ClipboardSnapshot(items: items)
    }

    private func restore(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            print("Restored empty clipboard")
            return
        }

        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
        print("Restored previous clipboard contents")
    }

    // Paste content (Simulate Cmd+V)
    func paste() {
        // Create a concurrent task to avoid blocking main thread if needed,
        // though CGEvent is fast.
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)

            // Command key down
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
            cmdDown?.flags = .maskCommand

            // 'V' key down
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            vDown?.flags = .maskCommand

            // 'V' key up
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vUp?.flags = .maskCommand

            // Command key up
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

            // Post events
            cmdDown?.post(tap: .cghidEventTap)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)

            print("Simulated Cmd+V")
        }
    }

    // Check if we have permission to send keystrokes
    var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    // Request permission via system prompt
    func requestAccessibilityPermission() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
