import Foundation
import FoundationModels

/// How aggressively the on-device model may edit a transcript. A discrete
/// scale rather than a free slider: each step has its own instructions and
/// its own guardrail budget (see `CleanupPromptSet`), so behaviour stays
/// predictable — turn it up or down until the output suits how you dictate.
nonisolated enum FormattingIntensity: Int, CaseIterable, Identifiable, Sendable {
    /// Mechanical only: spacing, capitalisation, punctuation, paragraph
    /// breaks. Words are never added, removed or changed.
    case formatting = 0
    /// Light cleanup: formatting plus filler-word removal ("um", "uh",
    /// false starts, repeated words) and obvious grammar fixes.
    case lightCleanup = 1
    /// Polish: light cleanup plus smoothing choppy dictated phrasing into
    /// fluent sentences — meaning, wording and tone preserved.
    case polish = 2
    /// Custom: the user's own ruleset (AI Models → Cleanup rulesets) is sent
    /// verbatim — no built-in preamble, no change-ratio governor, and the
    /// ruleset's own temperature.
    case custom = 3

    var id: Int { rawValue }

    /// The three built-in levels; `.custom` is driven by user rulesets.
    static var builtInCases: [FormattingIntensity] { [.formatting, .lightCleanup, .polish] }

    var displayName: String {
        switch self {
        case .formatting: return "Basic"
        case .lightCleanup: return "Light cleanup"
        case .polish: return "Polish"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .formatting:
            return "Basic: Fix capitals, commas, and paragraph breaks only. Does not add or drop words."
        case .lightCleanup:
            return "Light cleanup: Remove filler words and false starts, and fix obvious grammar and punctuation. (Usable with \"Markdown formatting\")"
        case .polish:
            return "Polish: Turns choppy dictation into fluent sentences and structured paragraphs. (Usable with \"Markdown formatting\")"
        case .custom:
            return "Custom: Your own cleanup instructions, sent to the model exactly as written. Manage rulesets in AI Models."
        }
    }

    /// Compiled instruction stages for this level (no DEBUG overlay).
    func instructionStages(includeMarkdownFormatting: Bool, language: String = "auto") -> [String] {
        CleanupPromptSet.compiled.instructionStages(
            for: self, includeMarkdown: includeMarkdownFormatting, language: language)
    }

    func instructions(includeMarkdownFormatting: Bool) -> String {
        instructionStages(includeMarkdownFormatting: includeMarkdownFormatting).joined(separator: "\n\n")
    }

    /// Compiled guardrail budget. `nil` means ungoverned (custom rulesets).
    var budget: GuardrailBudget? {
        CleanupPromptSet.compiled.budget(for: self)
    }

    /// Cost-ratio ceiling of the compiled budget; `nil` for Custom.
    var maximumChangeRatio: Double? { budget?.maxCostRatio }

    /// Polish → Light cleanup → Basic. Light-requested skips Polish. Raw is
    /// not in the list; the caller keeps the deterministic text after the
    /// last veto.
    var stepDownLadder: [FormattingIntensity] {
        switch self {
        case .polish: return [.polish, .lightCleanup, .formatting]
        case .lightCleanup: return [.lightCleanup, .formatting]
        case .formatting: return [.formatting]
        case .custom: return [.custom]
        }
    }
}

/// One on-device cleanup call: agent instructions vs the dictation to rewrite.
nonisolated struct FormattingRequest: Equatable, Sendable {
    /// Stages passed to `LanguageModelSession` as instructions, not as input.
    let instructionStages: [String]
    /// Original dictation only — never includes instruction fragments.
    let input: String
    /// The user turn: the dictation inside the wrap template plus any
    /// repeat suffix. This is what the engine sends.
    let userPrompt: String
    let intensity: FormattingIntensity
    /// Sampling temperature. Built-in levels stay deterministic at 0;
    /// custom rulesets carry their own value.
    var temperature: Double = 0.0
    /// Guardrail budget; nil disables it (custom rulesets).
    var budget: GuardrailBudget?

    var instructions: String {
        instructionStages.joined(separator: "\n\n")
    }

    var maximumChangeRatio: Double? { budget?.maxCostRatio }
}

/// Settings façade for on-device transcript cleanup. The chain itself lives
/// in `TranscriptCleanupPipeline`; this type owns the UserDefaults keys,
/// availability checks, and the last outcome for the DEBUG tuner.
final class TranscriptFormatterService {
    static let shared = TranscriptFormatterService()

    static let enabledKey = "formatTranscriptWithOnDeviceAI"
    static let intensityKey = "formatTranscriptIntensity"
    static let markdownFormattingKey = "formatTranscriptMarkdown"

    /// Opt-in; default off.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Default on: the Polish prompt already asked for markdown, so an
    /// unset key keeps existing output.
    static var isMarkdownFormattingEnabled: Bool {
        UserDefaults.standard.object(forKey: markdownFormattingKey) as? Bool ?? true
    }

    static var intensity: FormattingIntensity {
        // integer(forKey:) returns 0 when unset, which would silently select
        // .formatting — read the raw object so "never set" falls back to the
        // documented default of .lightCleanup.
        guard let raw = UserDefaults.standard.object(forKey: intensityKey) as? Int else {
            return .lightCleanup
        }
        return FormattingIntensity(rawValue: raw) ?? .lightCleanup
    }

    /// Whether the system model can run on this machine right now (it can be
    /// unavailable on low battery, unsupported hardware, or while downloading
    /// system assets). Used by Settings to explain a disabled toggle.
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Whether any cleanup engine can run: the system model, or a selected
    /// local model that is downloaded. Gates the cleanup toggles and pass.
    static var isCleanupAvailable: Bool {
        CleanupEngineFactory.engine(for: PostProcessingModelManager.shared.selectedModel)
            .isAvailable || isModelAvailable
    }

    /// Dictations shorter than this many words skip the model entirely.
    static let minimumWordCount = 8

    /// Result of the most recent real (non-preview) take this launch.
    private(set) var lastOutcome: TranscriptCleanupOutcome?
    private let lock = NSLock()

    private init() {}

    static func shouldFormat(_ text: String) -> Bool {
        guard isEnabled, isCleanupAvailable else { return false }
        return CleanupGuardrail.legacyWords(in: text).count >= minimumWordCount
    }

    // MARK: - Requests (compiled prompt set)

    static func request(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdownFormatting: Bool
    ) -> FormattingRequest {
        CleanupRequestBuilder.request(
            for: text, intensity: intensity, includeMarkdown: includeMarkdownFormatting)
    }

    static func request(for text: String, ruleset: CustomCleanupRuleset) -> FormattingRequest {
        CleanupRequestBuilder.request(for: text, ruleset: ruleset)
    }

    /// The request the pipeline will run first for the given settings.
    static func effectiveRequest(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdownFormatting: Bool,
        customRuleset: CustomCleanupRuleset?
    ) -> FormattingRequest {
        let option = CleanupOption(intensity: intensity, ruleset: customRuleset)
        let plan = CleanupPlan(
            option: option, includeMarkdown: includeMarkdownFormatting, language: "auto",
            autoEditEnabled: false, minimumWordCount: 0, promptSet: .compiled)
        return CleanupRequestBuilder.request(
            for: text, intensity: option.intensity ?? .lightCleanup, plan: plan)
    }

    // MARK: - Running

    /// Model stage only (no spelling, dictionary, Auto Edit or trailing
    /// punctuation), for callers that have already run those. Returns the
    /// input unchanged whenever the feature is off, the model is
    /// unavailable, the text is too short, or every rung is vetoed.
    func format(_ text: String, language: String = "auto") async -> String {
        guard Self.isEnabled else { return text }
        var plan = CleanupPlan.fromSettings(language: language)
        plan.applyDictionary = false
        plan.autoEditEnabled = false
        plan.smartTrailingPunctuation = false
        plan.language = "auto"
        let outcome = await TranscriptCleanupPipeline.shared.clean(raw: text, plan: plan)
        return outcome.landed == nil ? text : outcome.output
    }

    func record(_ outcome: TranscriptCleanupOutcome) {
        lock.lock()
        lastOutcome = outcome
        lock.unlock()
        Task { @MainActor in
            NotificationCenter.default.post(name: .transcriptCleanupFinished, object: outcome)
        }
    }

    // MARK: - Compatibility shims

    /// The 1.2.0 symmetric ratio. Reporting only; the pipeline uses
    /// `CleanupGuardrail.evaluate`.
    static func changeRatio(from original: String, to revised: String) -> Double {
        CleanupGuardrail.legacyChangeRatio(from: original, to: revised)
    }

    static func stripModelPreamble(_ text: String) -> String {
        CleanupPostPass.stripModelPreamble(text)
    }

    static func words(in text: String) -> [String] {
        CleanupGuardrail.legacyWords(in: text)
    }
}
