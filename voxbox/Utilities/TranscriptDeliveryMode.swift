import Foundation

/// How a finished transcript is delivered to the user.
///
/// Default is Auto paste transcription. Clipboard copies only — VoxBox does
/// not Cmd+V or write into the focused app. Streaming writes into the
/// destination as tokens appear.
enum TranscriptDeliveryMode: String, CaseIterable, Identifiable {
    case clipboard
    case autoPaste
    case streaming

    static let defaultsKey = "transcriptDeliveryMode"
    static let defaultMode: TranscriptDeliveryMode = .autoPaste

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clipboard: return "Copy transcription to clipboard"
        case .autoPaste: return "Auto paste transcription"
        case .streaming: return "Stream transcription"
        }
    }

    /// Short labels for the Settings segmented picker.
    var segmentLabel: String {
        switch self {
        case .clipboard: return "Copy to clipboard"
        case .autoPaste: return "Auto-paste"
        case .streaming: return "Stream"
        }
    }

    var summary: String {
        switch self {
        case .clipboard:
            return
                "Copies the finished transcript to the clipboard."
        case .autoPaste:
            return
                "Waits until you stop, then pastes the finished transcript into the app you were in."
        case .streaming:
            return
                "The transcription is streamed into the destination text area as it appears and is processed."
        }
    }

    /// Migrates once from the old toggles when the new key is absent, then persists.
    static func current(in defaults: UserDefaults = .standard) -> TranscriptDeliveryMode {
        if let raw = defaults.string(forKey: defaultsKey),
            let mode = TranscriptDeliveryMode(rawValue: raw)
        {
            return mode
        }
        let migrated = migrate(from: defaults)
        defaults.set(migrated.rawValue, forKey: defaultsKey)
        return migrated
    }

    static func set(_ mode: TranscriptDeliveryMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }

    /// Only used when `transcriptDeliveryMode` has never been written.
    private static func migrate(from defaults: UserDefaults) -> TranscriptDeliveryMode {
        if defaults.bool(forKey: StreamingMode.defaultsKey) {
            return .streaming
        }
        if defaults.bool(forKey: TranscriptClipboardPreference.defaultsKey) {
            return .clipboard
        }
        return .autoPaste
    }
}

/// Pure commit decision so tests do not have to drive the window controller.
enum TranscriptCommitAction: Equatable {
    case copyOnly
    case paste(restoreClipboard: Bool)
}

enum TranscriptCommitPlanner {
    static func plan(
        mode: TranscriptDeliveryMode,
        canPaste: Bool,
        restoreClipboard: Bool
    ) -> TranscriptCommitAction {
        if mode == .clipboard {
            return .copyOnly
        }
        guard canPaste else {
            return .copyOnly
        }
        return .paste(restoreClipboard: restoreClipboard)
    }
}
