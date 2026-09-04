import Foundation

/// What the user asked the model to do with a transcript.
nonisolated enum CleanupOption: Hashable, Sendable {
    case off
    case basic
    case light
    case polish
    case custom(CustomCleanupRuleset)

    /// Settings mapping. Custom with no usable ruleset degrades to Light
    /// cleanup, governor included, so the pass never runs instruction-less.
    init(intensity: FormattingIntensity, ruleset: CustomCleanupRuleset?) {
        switch intensity {
        case .formatting: self = .basic
        case .lightCleanup: self = .light
        case .polish: self = .polish
        case .custom:
            if let ruleset, ruleset.isUsable {
                self = .custom(ruleset)
            } else {
                self = .light
            }
        }
    }

    /// The intensity that governs this option; nil for `.off`.
    var intensity: FormattingIntensity? {
        switch self {
        case .off: return nil
        case .basic: return .formatting
        case .light: return .lightCleanup
        case .polish: return .polish
        case .custom: return .custom
        }
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .basic: return FormattingIntensity.formatting.displayName
        case .light: return FormattingIntensity.lightCleanup.displayName
        case .polish: return FormattingIntensity.polish.displayName
        case .custom(let ruleset):
            return ruleset.name.isEmpty ? FormattingIntensity.custom.displayName : ruleset.name
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(intensity?.rawValue ?? -1)
        if case .custom(let ruleset) = self {
            hasher.combine(ruleset.id)
            hasher.combine(ruleset.instructions)
            hasher.combine(ruleset.temperature)
        }
    }
}

/// One run of the cleanup chain. The real transcription path builds it from
/// Settings; previews build it explicitly (no enabled gate, no minimum
/// word count, optional single attempt).
nonisolated struct CleanupPlan: Sendable {
    var option: CleanupOption
    var includeMarkdown: Bool
    var language: String
    var autoEditEnabled: Bool
    var applyDictionary: Bool = true
    var smartTrailingPunctuation: Bool = true
    /// Below this many words the model stage is skipped.
    var minimumWordCount: Int
    /// Polish → Light → Basic → raw when a rung is vetoed.
    var allowStepDown: Bool = true
    /// Real takes record `lastOutcome` and post `.transcriptCleanupFinished`.
    var isPreview: Bool = false
    var promptSet: CleanupPromptSet = .resolved()

    static func fromSettings(language: String) -> CleanupPlan {
        CleanupPlan(
            option: TranscriptFormatterService.isEnabled
                ? CleanupOption(
                    intensity: TranscriptFormatterService.intensity,
                    ruleset: CustomRulesetStore.shared.usableActiveRuleset)
                : .off,
            includeMarkdown: TranscriptFormatterService.isMarkdownFormattingEnabled,
            language: language,
            autoEditEnabled: AutoEdit.isEnabled,
            smartTrailingPunctuation: SmartTrailingPunctuation.isEnabled,
            minimumWordCount: TranscriptFormatterService.minimumWordCount,
            promptSet: .resolved())
    }
}

/// Raw engine text and what the chain turned it into.
nonisolated struct CleanedTranscript: Equatable, Sendable {
    var raw: String
    var text: String
}
