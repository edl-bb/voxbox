import Foundation

@testable import voxbox

/// In-memory editor standing in for the destination app. Offsets are UTF-16
/// (like `AXSelectedTextRange`); Backspace deletes grapheme clusters (like
/// the real key). Flags reproduce the composers we have met in the wild.
final class FakeFieldWriter: FieldWriter {
    var text: String
    /// UTF-16 caret / selection start.
    var caret: Int
    var selectionLength = 0

    /// Chromium: AX sets report success and change nothing.
    var axSetIsNoop = false
    /// Sets with non-empty text are ignored; clearing works. Lets a test
    /// reach the "final write failed, span cleared" branch.
    var rejectNonEmptySets = false
    /// Messages: `AXSelectedText` reports unsettable.
    var axSelectedTextUnsettable = false
    /// AX reads fail outright.
    var axReadFails = false
    /// Notion / Slack: after a keystroke burst the caret jumps to the start.
    var resetCaretToStartAfterType = false
    /// Wrap width for `.endOfLine` (Cmd+→). `nil` means a single line.
    var visualLineWidth: Int?

    private(set) var ops: [String] = []

    init(text: String = "", caret: Int? = nil) {
        self.text = text
        self.caret = caret ?? (text as NSString).length
    }

    private var length: Int { (text as NSString).length }

    // MARK: FieldWriter

    func readValue() -> String? {
        ops.append("readValue")
        return axReadFails ? nil : text
    }

    func readSelection() -> CFRange? {
        axReadFails ? nil : CFRange(location: caret, length: selectionLength)
    }

    func isSelectedTextSettable() -> Bool { !axSelectedTextUnsettable }

    func setSelection(_ range: CFRange) -> Bool {
        ops.append("setSelection(\(range.location),\(range.length))")
        if axSetIsNoop { return true }
        caret = min(max(0, range.location), length)
        selectionLength = min(max(0, range.length), length - caret)
        return true
    }

    func setSelectedText(_ replacement: String) -> Bool {
        ops.append("setSelectedText(\((replacement as NSString).length))")
        if axSetIsNoop { return true }
        if rejectNonEmptySets, !replacement.isEmpty { return true }
        replaceSelection(with: replacement)
        return true
    }

    func setValue(_ value: String) -> Bool {
        ops.append("setValue(\((value as NSString).length))")
        if axSetIsNoop { return true }
        if rejectNonEmptySets, (value as NSString).length > length { return true }
        text = value
        caret = min(caret, length)
        selectionLength = 0
        return true
    }

    func type(_ typed: String) {
        ops.append("type(\((typed as NSString).length))")
        replaceSelection(with: typed)
        if resetCaretToStartAfterType {
            caret = 0
            selectionLength = 0
        }
    }

    func deleteBackward(count: Int) {
        ops.append("deleteBackward(\(count))")
        guard count > 0 else { return }
        var characters = Array(text)
        // Map the UTF-16 caret to a Character index.
        var utf16 = 0
        var charIndex = 0
        while charIndex < characters.count, utf16 < caret {
            utf16 += characters[charIndex].utf16.count
            charIndex += 1
        }
        let removeCount = min(count, charIndex)
        let keepBefore = charIndex - removeCount
        characters.removeSubrange(keepBefore..<charIndex)
        text = String(characters)
        caret = String(characters[0..<keepBefore]).utf16.count
        selectionLength = 0
    }

    func moveCaret(_ move: CaretMove) {
        ops.append("moveCaret(\(move))")
        selectionLength = 0
        switch move {
        case .endOfDocument:
            caret = length
        case .endOfLine:
            guard let width = visualLineWidth, width > 0 else {
                caret = length
                return
            }
            caret = min(length, (caret / width + 1) * width)
        }
    }

    func settle() {
        ops.append("settle")
    }

    // MARK: Helpers

    private func replaceSelection(with replacement: String) {
        let ns = text as NSString
        let start = min(max(0, caret), ns.length)
        let end = min(start + selectionLength, ns.length)
        text = ns.substring(to: start) + replacement + ns.substring(from: end)
        caret = start + (replacement as NSString).length
        selectionLength = 0
    }
}
