import AppKit
import ApplicationServices
import Foundation

/// Explicit setting that asks for live delivery while the user is still speaking.
enum StreamingMode {
    static let defaultsKey = "streamingMode"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
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
        defaults.set(false, forKey: defaultsKey)
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

/// List filter on the model page. Streaming when streaming mode is on;
/// Batch when the selected model is batch; otherwise All.
enum CatalogDecodeFilter: String, CaseIterable, Identifiable {
    case all
    case streaming
    case batch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .streaming: return "Streaming"
        case .batch: return "Batch"
        }
    }

    static func defaultFilter(
        streamingEnabled: Bool,
        selectedVariant: String = ""
    ) -> CatalogDecodeFilter {
        if streamingEnabled { return .streaming }
        if !selectedVariant.isEmpty, !StreamingMode.modelSupportsStreaming(selectedVariant) {
            return .batch
        }
        return .all
    }

    func includes(variant: String) -> Bool {
        let streaming = StreamingMode.modelSupportsStreaming(variant)
        switch self {
        case .all: return true
        case .streaming: return streaming
        case .batch: return !streaming
        }
    }
}

/// Stable prefix plus revisable hypothesis from a live engine.
struct LiveTranscriptSnapshot: Equatable, Sendable {
    var stable: String
    var revisable: String

    var fullText: String {
        if stable.isEmpty { return revisable }
        if revisable.isEmpty { return stable }
        if stable.last!.isWhitespace || revisable.first!.isWhitespace {
            return stable + revisable
        }
        return stable + " " + revisable
    }

    static let empty = LiveTranscriptSnapshot(stable: "", revisable: "")
}

/// How to read `AXValue` for a text splice. An empty Messages composer
/// reports `kAXErrorNoValue` even though `AXValue` is settable.
enum AXStringValue {
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
enum FieldSpan {
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
enum LiveWriteStrategy: Equatable {
    case accessibilityRewrite
    case keystrokesOnly

    static func choose(
        hasWebMarkers: Bool,
        axValue: String,
        bundleIdentifier: String? = nil
    ) -> LiveWriteStrategy {
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
        if electronBundleIdentifiers.contains(bundleIdentifier) { return true }
        return bundleIdentifier.hasPrefix("com.todesktop.")
            || bundleIdentifier.hasPrefix("notion.")
    }

    static let electronBundleIdentifiers: Set<String> = [
        "notion.id",
        "com.notion.Notion",
        "com.tinyspeck.slackmacgap",
        "com.superhuman.electron",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.hnc.Discord",
        "md.obsidian",
    ]
}

/// After the first keystroke burst, Notion / Slack often reset the caret to
/// the start of the block. Later suffixes then insert in front of the first
/// words (`This is` ends up at the end). Move to the end of the line before
/// typing the next delta — only once we have already typed.
enum CaretRestore: Equatable {
    static func shouldMoveToEndOfLine(alreadyTyped: Bool) -> Bool {
        alreadyTyped
    }

    /// Right-arrows from `caret` to `expected`. Zero when the caret is already
    /// at or past the end of what we typed.
    static func rightArrows(caret: Int, expected: Int) -> Int {
        max(0, expected - caret)
    }
}

/// HID plan for composers where AX set is a no-op.
/// Apple Speech and Whisper both replace a volatile phrase, then continue.
/// If the new snapshot is just a prefix of what we typed, hold. If it
/// diverges after a shared prefix, revise only that tail. A total rewrite
/// is held so we do not delete the take.
enum KeystrokeDelta: Equatable {
    case none
    case type(String)
    case delete(Int)
    case revise(delete: Int, type: String)

    static func livePlan(previous: String, next: String) -> KeystrokeDelta {
        if previous == next { return .none }
        let previousNS = previous as NSString
        let nextNS = next as NSString
        let shared = commonPrefixLength(previousNS, nextNS)
        if shared == previousNS.length {
            return nextNS.length > previousNS.length
                ? .type(nextNS.substring(from: shared))
                : .none
        }
        if shared == nextNS.length || shared == 0 { return .none }
        // "Hello there" → "Hi" shares "H" but is a new hypothesis, not a
        // tail edit. Hold so we do not delete the take at a drifted caret.
        if nextNS.length * 2 < previousNS.length { return .none }
        return .revise(
            delete: previousNS.length - shared,
            type: nextNS.substring(from: shared))
    }

    static func revertPlan(previous: String) -> KeystrokeDelta {
        let count = (previous as NSString).length
        return count == 0 ? .none : .delete(count)
    }

    static func commonPrefixLength(_ previous: NSString, _ next: NSString) -> Int {
        let limit = min(previous.length, next.length)
        var index = 0
        while index < limit {
            let left = previous.substring(with: NSRange(location: index, length: 1))
            let right = next.substring(with: NSRange(location: index, length: 1))
            if left.caseInsensitiveCompare(right) != .orderedSame { break }
            index += 1
        }
        return index
    }
}

/// `CGEventKeyboardSetUnicodeString` silently truncates; post in 20-unit chunks.
enum UnicodeTyping {
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

