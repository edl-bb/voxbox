import Foundation

/// How the hotkey drives a take. Stored as the same `recordingMode` integer
/// 1.2 used, so existing preferences carry over untouched.
nonisolated enum RecordingMode: Int, CaseIterable, Identifiable, Sendable {
    case hold = 0
    case toggle = 1

    static let defaultsKey = "recordingMode"

    var id: Int { rawValue }

    /// Unset or unknown values mean hold, exactly as `integer(forKey:)` did.
    static func current(in defaults: UserDefaults = .standard) -> RecordingMode {
        guard let raw = defaults.object(forKey: defaultsKey) as? Int else { return .hold }
        return RecordingMode(rawValue: raw) ?? .hold
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    // MARK: - Copy

    /// Settings › Recording Mode segmented control.
    var settingsTitle: String {
        switch self {
        case .hold: return "Hold to record"
        case .toggle: return "Toggle"
        }
    }

    var settingsCaption: String {
        switch self {
        case .hold: return "Hold the hotkey down to record, release when done."
        case .toggle: return "Press the hotkey to start recording, press again to stop."
        }
    }

    /// Recorder pill menu.
    var menuTitle: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Toggle on / off"
        }
    }

    var chipLabel: String {
        switch self {
        case .hold: return "Hold"
        case .toggle: return "Toggle"
        }
    }

    var icon: String {
        switch self {
        case .hold: return "hand.tap.fill"
        case .toggle: return "repeat.1"
        }
    }

    /// Onboarding card.
    var onboardingTitle: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Toggle on and off"
        }
    }

    func onboardingDescription(hotkey: String) -> String {
        switch self {
        case .hold:
            return "Hold \(hotkey) while you speak and let go when you're done. Quick and natural for short messages."
        case .toggle:
            return "Press \(hotkey) once to start and again to stop. Hands-free for longer dictation."
        }
    }

    static func onboardingSubtitle(hotkey: String) -> String {
        "VoxBox listens while you use the \(hotkey) key. Pick the style that suits you. You can switch any time from the recorder pill or Settings."
    }

    static let onboardingTip =
        "Not sure? Hold to talk is the default, and the pill shows a Hold / Toggle switch whenever you record."
}
