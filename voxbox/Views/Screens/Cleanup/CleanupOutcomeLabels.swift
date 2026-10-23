import Foundation

/// What a preview should say about the level that actually produced its
/// text. A rejected Polish pass steps down to Light or to the instant pass,
/// and the preview must not label that output "Polish".
extension TranscriptCleanupOutcome {
    /// The level whose text is shown, for the card's label.
    var shownLevelName: String? {
        guard modelRan else { return nil }
        return landed?.displayName ?? "Instant cleanup"
    }

    /// Set when the requested level was rejected by its checks.
    var stepDownNote: String? {
        guard modelRan, let wanted = requested.intensity, landed != wanted, error == nil else { return nil }
        return "\(wanted.displayName) didn't pass its checks, so this is \(shownLevelName ?? "instant cleanup")."
    }
}
