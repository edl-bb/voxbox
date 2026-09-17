import Foundation

/// What the user asked the model to do with a transcript.
nonisolated enum CleanupOption: Sendable {
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
            if let ruleset, !ruleset.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
}

extension CleanupOption: nonisolated Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off), (.basic, .basic), (.light, .light), (.polish, .polish):
            return true
        case (.custom(let left), .custom(let right)):
            return left.id == right.id
                && left.name == right.name
                && left.instructions == right.instructions
                && left.temperature == right.temperature
        default:
            return false
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
}

/// Raw engine text and what the chain turned it into.
nonisolated struct CleanedTranscript: Equatable, Sendable {
    var raw: String
    var text: String
}
