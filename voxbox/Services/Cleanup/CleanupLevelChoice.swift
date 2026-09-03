import Foundation

/// The cleanup options onboarding offers, flattened so "Off" sits beside the
/// four intensities. Maps to the two Settings keys the rest of the app reads.
nonisolated enum CleanupLevelChoice: String, CaseIterable, Identifiable, Sendable {
    case off
    case basic
    case light
    case polish
    case custom

    var id: String { rawValue }

    static let recommended: CleanupLevelChoice = .light

    init(enabled: Bool, intensity: FormattingIntensity) {
        guard enabled else {
            self = .off
            return
        }
        switch intensity {
        case .formatting: self = .basic
        case .lightCleanup: self = .light
        case .polish: self = .polish
        case .custom: self = .custom
        }
    }

    /// The intensity this choice selects; nil for Off.
    var intensity: FormattingIntensity? {
        switch self {
        case .off: return nil
        case .basic: return .formatting
        case .light: return .lightCleanup
        case .polish: return .polish
        case .custom: return .custom
        }
    }

    var isEnabled: Bool { self != .off }

    /// The option a preview should run to show this choice. Custom has no
    /// ruleset yet during onboarding, so it previews as Light.
    var previewOption: CleanupOption {
        switch self {
        case .off: return .off
        case .basic: return .basic
        case .light, .custom: return .light
        case .polish: return .polish
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .basic: return "Basic"
        case .light: return "Light cleanup"
        case .polish: return "Polish"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .off: return "waveform"
        case .basic: return "textformat"
        case .light: return "sparkle"
        case .polish: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }

    var blurb: String {
        switch self {
        case .off:
            return "No model runs. You get the transcript as dictated, with instant rule-based tidying only."
        case .basic:
            return "Fixes capitals, punctuation, spacing and paragraph breaks. Never adds, drops or changes a word."
        case .light:
            return "Drops um, uh, false starts and repeated words, and fixes obvious grammar. Everything else stays in your words."
        case .polish:
            return "Light cleanup plus smoothing choppy phrases into fluent sentences and fixing words that were misheard. Your meaning and tone stay put."
        case .custom:
            return "Write your own instructions later in AI Models. Until you add a ruleset, Light cleanup runs."
        }
    }

    /// Writes the choice to the two settings keys.
    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: TranscriptFormatterService.enabledKey)
        if let intensity {
            defaults.set(intensity.rawValue, forKey: TranscriptFormatterService.intensityKey)
        }
    }
}
