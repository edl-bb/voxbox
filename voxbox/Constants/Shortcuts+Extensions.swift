import Foundation
import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.space, modifiers: [.control, .option]))
    /// Copies the most recent transcript. Independent of the recording hotkey
    /// so it still works when the primary shortcut is a single modifier (Fn).
    static let copyLastTranscript = Self(
        "copyLastTranscript", default: .init(.c, modifiers: [.control, .option]))
}

extension Notification.Name {
    static let hotkeyTriggered = Notification.Name("hotkeyTriggered") // Legacy, can be removed
    static let recordingStartRequested = Notification.Name("recordingStartRequested")
    static let recordingStopRequested = Notification.Name("recordingStopRequested")
    static let recordingCancelRequested = Notification.Name("recordingCancelRequested")
    /// Posted when the "always show recorder pill" preference changes so the
    /// window controller can show/hide the idle pill immediately.
    static let recorderIdleVisibilityChanged = Notification.Name("recorderIdleVisibilityChanged")
    /// Posted when the user picks a new "recorder pill position" in Settings so
    /// the window controller can move the pill without touching visibility.
    static let recorderPillPositionChanged = Notification.Name("recorderPillPositionChanged")
    /// Posted when on-device AI cleanup is about to run, so the pill can
    /// switch from “Transcribing…” to “Tidying up…”.
    static let transcriptCleanupStarted = Notification.Name("transcriptCleanupStarted")
    /// Posted after the copy-last-transcript shortcut writes the clipboard.
    static let lastTranscriptCopied = Notification.Name("lastTranscriptCopied")
    /// Posted when the shortcut fired but history has no transcript yet.
    static let lastTranscriptCopyFailed = Notification.Name("lastTranscriptCopyFailed")
    /// Posted by ⌘, / Settings… so the dashboard can select the Settings page.
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    /// Posted when any dashboard sidebar route is requested (Settings, AI Models).
    static let dashboardRouteRequested = Notification.Name("dashboardRouteRequested")
    /// Posted when picking a batch model turns streaming mode off.
    static let streamingRevertedToBatch = Notification.Name("streamingRevertedToBatch")
}
