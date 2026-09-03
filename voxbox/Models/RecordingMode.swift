import Foundation

/// Whether the hotkey records while held or flips recording on each press.
/// Stored as the legacy integer under `recordingMode` (0 hold, 1 toggle),
/// which the event tap in AppDelegate reads directly.
nonisolated enum RecordingMode: Int, CaseIterable, Identifiable, Sendable {
    case hold = 0
    case toggle = 1

    static let defaultsKey = "recordingMode"
    static let `default`: RecordingMode = .hold

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Hold to record"
        case .toggle: return "Toggle"
        }
    }

    var icon: String {
        switch self {
        case .hold: return "hand.tap.fill"
        case .toggle: return "repeat.1"
        }
    }

    /// One line, as shown under the Settings picker.
    var summary: String {
        switch self {
        case .hold: return "Hold the hotkey down to record, release when done."
        case .toggle: return "Press the hotkey to start recording, press again to stop."
        }
    }

    /// Longer explainer for onboarding.
    var detail: String {
        switch self {
        case .hold:
            return
                "Like a walkie-talkie: keep the key down while you speak and let go to send. Good for quick replies and short thoughts, and nothing is left recording by accident."
        case .toggle:
            return
                "Press once to start, speak for as long as you like, press again to finish. Suits longer dictation where holding a key down gets tiring."
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> RecordingMode {
        RecordingMode(rawValue: defaults.integer(forKey: defaultsKey)) ?? .default
    }

    static func set(_ mode: RecordingMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}
