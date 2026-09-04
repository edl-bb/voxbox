import AppKit
import ApplicationServices
import Foundation

/// Explicit setting that asks for live delivery while the user is still speaking.
enum StreamingMode {
    static let defaultsKey = "streamingMode"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        TranscriptDeliveryMode.current(in: defaults) == .streaming
    }

    /// Apple Speech and catalog WhisperKit models can stream. Parakeet stays batch until FluidAudio streaming ships.
    static func modelSupportsStreaming(_ variant: String) -> Bool {
        switch AIModel.engineKind(for: variant) {
        case .apple, .whisper:
            return !variant.isEmpty
        case .parakeet:
            return false
        }
    }

    /// Temporary alias while call sites move to `modelSupportsStreaming`.
    static func modelSupportsLive(_ variant: String) -> Bool {
        modelSupportsStreaming(variant)
    }

    /// Streaming is on and this model can only batch-decode.
    static func shouldRevertToBatch(for variant: String, streamingEnabled: Bool) -> Bool {
        streamingEnabled && !variant.isEmpty && !modelSupportsStreaming(variant)
    }

    /// Streaming is on but the selected model cannot stream — show the settings banner.
    static func needsStreamingModel(variant: String, streamingEnabled: Bool) -> Bool {
        streamingEnabled && !modelSupportsStreaming(variant)
    }

    /// Turns streaming off when the selected model cannot stream.
    /// Posts `.streamingRevertedToBatch` so the dashboard can toast and the model page can show Batch.
    @discardableResult
    static func disableIfIncompatible(
        with variant: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard shouldRevertToBatch(for: variant, streamingEnabled: isEnabled(in: defaults)) else {
            return false
        }
        TranscriptDeliveryMode.set(.autoPaste, in: defaults)
        NotificationCenter.default.post(name: .streamingRevertedToBatch, object: variant)
        return true
    }
}

enum StreamingModeCopy {
    static let revertedToBatch =
        "Streaming is off. This model is Batch, so VoxBox will paste after you stop."
    static let needsStreamingModel =
        "This setting needs a Streaming model. When you update your model choice, you can use live streaming."
}

/// Stable prefix plus revisable hypothesis from a live engine.
nonisolated struct LiveTranscriptSnapshot: Equatable, Sendable {
    var stable: String
    var revisable: String

    var fullText: String { Self.join(stable, revisable) }

    /// Seam rule shared by `fullText` and the engines' stable accumulation,
    /// so `stable` is always a prefix of `fullText`. Inserts one space unless
    /// either side already has whitespace at the seam.
    static func join(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        if head.last!.isWhitespace || tail.first!.isWhitespace {
            return head + tail
        }
        return head + " " + tail
    }

    static let empty = LiveTranscriptSnapshot(stable: "", revisable: "")
}

/// Snapshot stamped with the take it belongs to and its arrival order, so a
/// late hop from a finished take, or an older snapshot, can be dropped.
nonisolated struct SequencedSnapshot: Equatable, Sendable {
    let take: Int
    let seq: Int
    let snapshot: LiveTranscriptSnapshot
}

/// How to read `AXValue` for a text splice. An empty Messages composer
/// reports `kAXErrorNoValue` even though `AXValue` is settable.
nonisolated enum AXStringValue {
    static func read(error: AXError, value: CFTypeRef?) -> String? {
        switch error {
        case .success:
            return value as? String
        case .noValue:
            return ""
        default:
            return nil
        }
    }
}

/// Pure splice used by the Accessibility field writer — and by tests.
/// Indexes are UTF-16, matching `AXSelectedTextRange`.
nonisolated enum FieldSpan {
    static func splice(
        existing: String,
        start: Int,
        length: Int,
        replacement: String
    ) -> (value: String, newLength: Int) {
        let ns = existing as NSString
        let clampedStart = min(max(0, start), ns.length)
        let clampedEnd = min(clampedStart + max(0, length), ns.length)
        let next = ns.substring(to: clampedStart) + replacement + ns.substring(from: clampedEnd)
        return (next, (replacement as NSString).length)
    }

    /// UTF-16 slice used to confirm an Accessibility write actually landed.
    static func region(_ existing: String, start: Int, length: Int) -> String? {
        let ns = existing as NSString
        guard start >= 0, length >= 0, start + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: length))
    }
}

/// Electron composers report the web marker suite and a trivial `AXValue`
/// (`U+000A` or empty). AX set returns success and does not change the DOM;
/// queued `AXSelectedTextRange` writes then jump the caret to the start.
/// Skip AX entirely and type. AppKit (including empty Messages) and browser
/// fields with a real value still try the rewrite.
nonisolated enum LiveWriteStrategy: Equatable {
    case accessibilityRewrite
    case keystrokesOnly

    /// `isElectronApp` comes from the app bundle (an `Electron Framework`
    /// inside it), so apps missing from the bundle list still type.
    static func choose(
        hasWebMarkers: Bool,
        axValue: String,
        bundleIdentifier: String? = nil,
        isElectronApp: Bool = false
    ) -> LiveWriteStrategy {
        if isElectronApp { return .keystrokesOnly }
        if let bundleIdentifier, isElectronBundle(bundleIdentifier) {
            return .keystrokesOnly
        }
        if hasWebMarkers, isTrivialAXValue(axValue) { return .keystrokesOnly }
        return .accessibilityRewrite
    }

    static func isTrivialAXValue(_ value: String) -> Bool {
        value.isEmpty || value == "\n" || value == "\r" || value == "\r\n"
    }

    static func isElectronBundle(_ bundleIdentifier: String) -> Bool {
        isElectronComposer(bundleIdentifier) || isElectronEditor(bundleIdentifier)
    }

    /// Chat / note composers that reset the caret to the start of the block
    /// after a keystroke burst. Cmd+↓ (end of document) puts it back.
    static func isElectronComposer(_ bundleIdentifier: String) -> Bool {
        if electronComposers.contains(bundleIdentifier) { return true }
        return bundleIdentifier.hasPrefix("notion.")
    }

    /// Code / markdown editors. The caret stays where we left it, and
    /// end-of-document would be the wrong place, so no caret restore.
    static func isElectronEditor(_ bundleIdentifier: String) -> Bool {
        if electronEditors.contains(bundleIdentifier) { return true }
        return bundleIdentifier.hasPrefix("com.todesktop.")
    }

    static let electronComposers: Set<String> = [
        "notion.id",
        "com.notion.Notion",
        "com.tinyspeck.slackmacgap",
        "com.superhuman.electron",
        "com.hnc.Discord",
        "com.anthropic.claudefordesktop",
    ]

    static let electronEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "md.obsidian",
    ]

    static var electronBundleIdentifiers: Set<String> {
        electronComposers.union(electronEditors)
    }
}

/// How to put the caret back before typing the next delta.
nonisolated enum CaretMove: Equatable, Sendable {
    /// Cmd+→. End of the *visual line*: wrong once the take wraps, kept only
    /// so the test fake can reproduce the old mid-paragraph jump.
    case endOfLine
    /// Cmd+↓. End of the block / document. What Slack and Notion need after
    /// they reset the caret following a keystroke burst.
    case endOfDocument
}

/// Moving the caret before a burst. Off by default: the Notion / Slack
/// "caret jumps to the start after the first burst" seen in 1.1 came from
/// the `AXSelectedTextRange` writes that used to run before falling back to
/// typing, and those writes no longer reach Electron. A blind Cmd+↓ is also
/// wrong whenever the user dictates mid-text (Claude appended to the end).
/// `caretResettingComposers` is the escape hatch if an app really does
/// reset; the inserter logs when the caret is not where it was left.
nonisolated enum CaretRestore: Equatable {
    /// Bundles observed to move the caret on their own after typed input.
    static let caretResettingComposers: Set<String> = []

    static func move(
        forBundle bundleIdentifier: String?,
        isElectronApp: Bool = false,
        hasTyped: Bool
    ) -> CaretMove? {
        guard hasTyped, let bundleIdentifier else { return nil }
        return caretResettingComposers.contains(bundleIdentifier) ? .endOfDocument : nil
    }
}

/// Append-only plan for composers where AX set is a no-op. Only committed
/// (stable) words are typed; the revisable tail stays in the HUD. Nothing
/// is ever deleted mid-take, so a drifted caret can never eat the take.
nonisolated enum AppendPlan: Equatable {
    enum HoldReason: Equatable {
        case unchanged
        /// The stable text no longer starts with what we typed (engine
        /// revised a committed word). Wait for a snapshot we can extend.
        case stableDiverged
    }

    case append(String)
    case hold(HoldReason)

    /// Exact, case-sensitive prefix check on UTF-16 units.
    static func plan(typed: String, stable: String) -> AppendPlan {
        if stable == typed { return .hold(.unchanged) }
        guard stable.hasPrefix(typed) else { return .hold(.stableDiverged) }
        let typedNS = typed as NSString
        let stableNS = stable as NSString
        guard stableNS.length > typedNS.length else { return .hold(.unchanged) }
        return .append(stableNS.substring(from: typedNS.length))
    }

    /// After the stable text has diverged from what we typed (a promoted word
    /// was revised), keep the take flowing by typing the words the engine
    /// has beyond our word count. The wrong word stays until the finish
    /// replace corrects it; nothing is deleted mid-take.
    static func tailBeyondTypedWords(typed: String, stable: String) -> String? {
        let typedWords = typed.split(whereSeparator: \.isWhitespace).count
        let stableWords = stable.split(whereSeparator: \.isWhitespace)
        guard stableWords.count > typedWords else { return nil }
        return stableWords[typedWords...].joined(separator: " ")
    }
}

/// Promotes words from the engine's revisable tail to "typed" once they
/// have sat unchanged for a while. Engines commit in sentence-sized blocks,
/// which is why live text used to arrive in lumps; they also almost only
/// revise the last word or two, which is why this is safe enough. A wrong
/// promotion is corrected by the finish replace.
nonisolated enum StablePromotion {
    struct Sample: Equatable, Sendable {
        var time: Date
        var revisable: String
    }

    /// A word must be unchanged for this long.
    static let window: TimeInterval = 1.0
    /// The newest words are never promoted, whatever their age.
    static let holdBackWords = 2

    /// The leading words of `current` that every sample covering the last
    /// `window` seconds agrees on, minus the last `holdBackWords` words of
    /// `current`. Empty when the history does not reach back a full window.
    static func promotedPrefix(
        samples: [Sample], current: String, now: Date,
        window: TimeInterval = window, holdBackWords: Int = holdBackWords
    ) -> String {
        let cutoff = now.addingTimeInterval(-window)
        // The newest sample from before the cutoff describes the text during
        // the gap up to the window; without one we have not watched long enough.
        guard let anchor = samples.last(where: { $0.time < cutoff }) else { return "" }
        var agreed = Array(anchor.revisable)
        for sample in samples where sample.time >= cutoff {
            let chars = Array(sample.revisable)
            var index = 0
            while index < agreed.count, index < chars.count, agreed[index] == chars[index] { index += 1 }
            agreed.removeSubrange(index...)
        }
        let currentChars = Array(current)
        var index = 0
        while index < agreed.count, index < currentChars.count, agreed[index] == currentChars[index] { index += 1 }
        agreed.removeSubrange(index...)

        let agreedText = String(agreed)
        var words = agreedText.split(whereSeparator: \.isWhitespace).map(String.init)
        // A prefix that stops mid-word has not proven that word.
        if let last = agreedText.last, !last.isWhitespace, !words.isEmpty { words.removeLast() }
        let currentWords = current.split(whereSeparator: \.isWhitespace).count
        let allowed = min(words.count, currentWords - holdBackWords)
        guard allowed > 0 else { return "" }
        return words[..<allowed].joined(separator: " ")
    }
}

/// The smallest keystroke edit that turns the typed text into the cleaned
/// one: step left over the shared suffix, select the divergent middle,
/// paste its replacement, step back right. Word-aligned so a replacement
/// never splits a word.
nonisolated struct KeystrokeReplacePlan: Equatable {
    /// Graphemes shared at the end; the caret steps left over them first.
    var suffixGraphemes: Int
    /// Graphemes to select (Shift+Left) before pasting.
    var selectGraphemes: Int
    /// Text pasted over the selection; empty means plain deletion.
    var replacement: String

    var isNoOp: Bool { selectGraphemes == 0 && replacement.isEmpty }

    static func plan(typed: String, cleaned: String) -> KeystrokeReplacePlan {
        let t = Array(typed)
        let c = Array(cleaned)

        var prefix = 0
        while prefix < t.count, prefix < c.count, t[prefix] == c[prefix] { prefix += 1 }
        // Back up to a word boundary unless the whole typed text matched.
        if prefix < t.count {
            while prefix > 0, !t[prefix - 1].isWhitespace { prefix -= 1 }
        }

        var suffix = 0
        while suffix < t.count - prefix, suffix < c.count - prefix, t[t.count - 1 - suffix] == c[c.count - 1 - suffix] {
            suffix += 1
        }
        // The suffix must start at a word boundary in both texts.
        while suffix > 0, t.count - suffix > prefix,
            !(t[t.count - suffix - 1].isWhitespace || t[t.count - suffix].isWhitespace)
        {
            suffix -= 1
        }
        while suffix > 0, c.count - suffix > prefix,
            !(c[c.count - suffix - 1].isWhitespace || c[c.count - suffix].isWhitespace)
        {
            suffix -= 1
        }

        return KeystrokeReplacePlan(
            suffixGraphemes: suffix,
            selectGraphemes: t.count - prefix - suffix,
            replacement: String(c[prefix..<(c.count - suffix)]))
    }
}

/// HID plan used by cancel-revert. Counts are grapheme clusters, because
/// one Backspace deletes one grapheme, not one UTF-16 unit.
nonisolated enum KeystrokeDelta: Equatable {
    case none
    case type(String)
    case delete(Int)

    static func revertPlan(previous: String) -> KeystrokeDelta {
        let count = previous.count
        return count == 0 ? .none : .delete(count)
    }
}

/// `CGEventKeyboardSetUnicodeString` silently truncates; post in 20-unit chunks.
nonisolated enum UnicodeTyping {
    static let maxEventLength = 20

    static func chunks(_ text: String) -> [String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var start = 0
        var parts: [String] = []
        while start < ns.length {
            let length = min(maxEventLength, ns.length - start)
            parts.append(ns.substring(with: NSRange(location: start, length: length)))
            start += length
        }
        return parts
    }
}

