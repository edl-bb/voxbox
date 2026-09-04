import Foundation

/// The first-run walkthrough, in order.
nonisolated enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case globeKey
    case recordingMode
    case permissions
    case cleanup
    case model

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var isLast: Bool { next == nil }

    /// Outer padding around the page content.
    var contentPadding: CGFloat {
        switch self {
        case .model: return 16
        case .cleanup: return 24
        default: return 40
        }
    }

    /// Welcome has no progress row; every later step does.
    var showsStepDots: Bool { self != .welcome }

    static var dotSteps: [OnboardingStep] { allCases.filter(\.showsStepDots) }
}

/// Replaying the walkthrough from Settings uses its own flag so the pill and
/// the recorder, which read `hasCompletedOnboarding`, behave as usual while
/// the guide is open.
nonisolated enum OnboardingReplay {
    static let requestedKey = "onboardingReplayRequested"

    static func request(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: requestedKey)
    }

    static func finish(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: requestedKey)
    }

    static func isRequested(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: requestedKey)
    }
}

/// The five cards on the cleanup step, mapped onto the formatter settings.
nonisolated enum OnboardingCleanupChoice: Int, CaseIterable, Identifiable, Sendable {
    case off
    case basic
    case lightCleanup
    case polish
    case custom

    static let defaultRulesetName = "My ruleset"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .basic: return FormattingIntensity.formatting.displayName
        case .lightCleanup: return FormattingIntensity.lightCleanup.displayName
        case .polish: return FormattingIntensity.polish.displayName
        case .custom: return FormattingIntensity.custom.displayName
        }
    }

    var summary: String {
        switch self {
        case .off: return "Paste exactly what the engine heard. No AI pass."
        case .basic: return "Capitals, punctuation and paragraph breaks. Never changes a word."
        case .lightCleanup: return "Drops ums, false starts and repeats, fixes obvious grammar. Keeps your words."
        case .polish: return "Smooths choppy dictation into fluent sentences. Keeps your meaning."
        case .custom: return "Your own instructions, in your own words."
        }
    }

    var intensity: FormattingIntensity? {
        switch self {
        case .off: return nil
        case .basic: return .formatting
        case .lightCleanup: return .lightCleanup
        case .polish: return .polish
        case .custom: return .custom
        }
    }

    /// What the card previews. Custom needs a usable ruleset; nil means the
    /// card explains that rules come after setup.
    func previewOption(rulesetStore: CustomRulesetStore) -> CleanupOption? {
        switch self {
        case .off: return .off
        case .basic: return .basic
        case .lightCleanup: return .light
        case .polish: return .polish
        case .custom: return rulesetStore.usableActiveRuleset.map { .custom($0) }
        }
    }

    /// The card that matches the stored settings. Fresh installs land on Off.
    static func current(in defaults: UserDefaults = .standard) -> OnboardingCleanupChoice {
        guard defaults.bool(forKey: TranscriptFormatterService.enabledKey) else { return .off }
        let raw = defaults.object(forKey: TranscriptFormatterService.intensityKey) as? Int
        switch raw.flatMap(FormattingIntensity.init(rawValue:)) ?? .lightCleanup {
        case .formatting: return .basic
        case .lightCleanup: return .lightCleanup
        case .polish: return .polish
        case .custom: return .custom
        }
    }

    /// Writes the formatter keys. Custom with no ruleset creates
    /// "My ruleset" and makes it active. Returns true when the ruleset
    /// editor should open after setup because there are no instructions yet.
    @discardableResult
    func apply(defaults: UserDefaults = .standard, rulesetStore: CustomRulesetStore) -> Bool {
        switch self {
        case .off:
            defaults.set(false, forKey: TranscriptFormatterService.enabledKey)
            return false
        case .basic, .lightCleanup, .polish:
            defaults.set(true, forKey: TranscriptFormatterService.enabledKey)
            defaults.set(intensity!.rawValue, forKey: TranscriptFormatterService.intensityKey)
            return false
        case .custom:
            defaults.set(true, forKey: TranscriptFormatterService.enabledKey)
            defaults.set(FormattingIntensity.custom.rawValue, forKey: TranscriptFormatterService.intensityKey)
            if rulesetStore.rulesets.isEmpty, var created = rulesetStore.addRuleset() {
                created.name = Self.defaultRulesetName
                rulesetStore.update(created)
                rulesetStore.activeRulesetID = created.id
            }
            return rulesetStore.usableActiveRuleset == nil
        }
    }
}
