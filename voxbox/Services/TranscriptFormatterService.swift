import Foundation
import FoundationModels

/// How aggressively the on-device model may edit a transcript. A discrete
/// scale rather than a free slider: each step has its own instructions and
/// its own guardrail budget, so behaviour stays predictable — turn it up or
/// down until the output suits how you dictate.
enum FormattingIntensity: Int, CaseIterable, Identifiable {
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

    /// Shared preamble for every intensity.
    private static let baseInstructions = """
        You clean up text dictated by voice. Reply with only the cleaned text — \
        no commentary, no labels, no quotation marks around it. Never write \
        phrases such as “here’s the clean text” or “cleaned text:”. Never add \
        information, never summarise, never reorder ideas.
        """

    /// Intensity body with optional stages omitted. Markdown lives in
    /// `FormattingPromptStage.markdownFormatting`, not here.
    private var intensityInstructions: String {
        switch self {
        case .formatting:
            return """
                Apply ONLY mechanical edits: fix spacing, capitalisation and \
                punctuation, and add sentence/paragraph breaks where the flow of \
                speech implies them. Do not add, remove or change any word.
                """
        case .lightCleanup:
            return """
                Apply these edits: remove filler words and false starts ("um", "uh", \
                "ah", "er", "you know", filler "like", repeated words); fix grammar, \
                punctuation, capitalisation and spacing; add sentence and paragraph \
                breaks where the flow of speech implies them. Preserve the speaker's \
                wording everywhere else.
                """
        case .polish:
            return """
                Remove filler words and false starts ("um", "uh", "ah", "er", "you know", filler "like", repeated words);\
                Fix grammar, punctuation, capitalisation and spacing; add sentence and paragraph breaks where the flow of speech implies them;\
                Where a word is semantically out of place, and phonetically similar to a more likely word (e.g. pacing and pasting), replace it with the correct word;\
                Where a small restructuing of a sentence or phrase is needed to improve the flow of speech, do so;\
                Preserve the speaker's meaning, vocabulary and tone — polish the delivery, never the message.
                """
        case .custom:
            // Only reached when Custom is selected but no usable ruleset
            // exists; behave like Light cleanup so the pass stays sensible.
            return FormattingIntensity.lightCleanup.intensityInstructions
        }
    }

    /// Model instructions for this level, including optional stages from
    /// the current Settings toggles.
    var instructions: String {
        instructions(
            includeMarkdownFormatting: TranscriptFormatterService.isMarkdownFormattingEnabled)
    }

    /// Instruction stages sent to the model: base + intensity body + optional
    /// markdown + always-on output-only. Never mixed into the transcript input.
    func instructionStages(includeMarkdownFormatting: Bool) -> [String] {
        var stages = [Self.baseInstructions, intensityInstructions]
        if includeMarkdownFormatting {
            stages.append(FormattingPromptStage.markdownFormatting)
        }
        stages.append(FormattingPromptStage.outputTranscriptOnly)
        return stages
    }

    /// Assembled instructions: base + intensity body + optional stages.
    func instructions(includeMarkdownFormatting: Bool) -> String {
        instructionStages(includeMarkdownFormatting: includeMarkdownFormatting)
            .joined(separator: "\n\n")
    }

    /// Maximum fraction of words the model may change/remove at this level
    /// before the output is rejected in favour of the raw transcript.
    /// `nil` means ungoverned: custom rulesets run without the guardrail so
    /// the user's instructions are honoured even when they rewrite heavily.
    var maximumChangeRatio: Double? {
        switch self {
        case .formatting: return 0.10
        case .lightCleanup: return 0.40
        case .polish: return 0.80
        case .custom: return nil
        }
    }
}

/// Prompt fragments appended after the intensity body. Settings-gated
/// stages are included only when the matching toggle is on; always-on
/// stages are appended every LLM pass.
enum FormattingPromptStage {
    /// Lifted from the Polish instructions. Do not rewrite — the Settings
    /// toggle includes or omits this exact line.
    static let markdownFormatting =
        "You can provide limited markdown formatting (bold, italic, bullet points, numbered lists, etc.) where it makes sense to do so;"

    /// Always-on. Last so it counters a markdown-bold “here is the cleaned text” wrap.
    static let outputTranscriptOnly =
        "Return only the rewritten transcript — no preamble, no “here is the cleaned text”, no wrapping quotes."
}

/// One on-device cleanup call: agent instructions vs the dictation to rewrite.
struct FormattingRequest: Equatable {
    /// Stages passed to `LanguageModelSession` as instructions, not as input.
    let instructionStages: [String]
    /// Original dictation only — never includes instruction fragments.
    let input: String
    /// Sampling temperature. Built-in levels stay deterministic at 0;
    /// custom rulesets carry their own value.
    var temperature: Double = 0.0
    /// Change-ratio budget for the guardrail; nil disables it (custom rulesets).
    var maximumChangeRatio: Double?

    var instructions: String {
        instructionStages.joined(separator: "\n\n")
    }
}

/// Optional on-device AI cleanup for finished transcripts, powered by Apple's
/// Foundation Models framework (the ~3B system model that ships with macOS 26
/// — zero download, zero network, runs on the Neural Engine).
///
/// Guardrails (see docs/local-llm-formatting-options.md):
/// - Opt-in toggle, default off (Settings → Transcript Cleanup), with a
///   three-step intensity scale (`FormattingIntensity`).
/// - Skipped for very short dictations, where the existing punctuation and
///   Auto Edit passes are already the right tool.
/// - The output is diff-checked against the input: if the word-level change
///   ratio exceeds the level's budget, the raw transcript is used instead —
///   the model can never silently rewrite meaning.
/// - Any error (model busy, unavailable, guardrail veto) falls back to the
///   raw transcript. Formatting is best-effort, never load-bearing.
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

    /// Dictations shorter than this many words skip the model entirely.
    static let minimumWordCount = 8

    private init() {}

    static func shouldFormat(_ text: String) -> Bool {
        guard isEnabled, isModelAvailable else { return false }
        return words(in: text).count >= minimumWordCount
    }

    /// Split `text` into model instructions vs dictation input. Markdown
    /// belongs only in `instructions`; the transcript body stays dictation.
    static func request(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdownFormatting: Bool
    ) -> FormattingRequest {
        FormattingRequest(
            instructionStages: intensity.instructionStages(
                includeMarkdownFormatting: includeMarkdownFormatting),
            input: text.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumChangeRatio: intensity.maximumChangeRatio
        )
    }

    /// Request for a user ruleset: the instructions go to the model exactly
    /// as written — no built-in preamble, no markdown stage — with the
    /// ruleset's temperature and no change-ratio governor.
    static func request(
        for text: String,
        ruleset: CustomCleanupRuleset
    ) -> FormattingRequest {
        FormattingRequest(
            instructionStages: [
                ruleset.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            ],
            input: text.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: ruleset.temperature.clamped(to: CustomRulesetStore.temperatureRange),
            maximumChangeRatio: nil
        )
    }

    /// The request the formatter will actually run for the current settings:
    /// the active custom ruleset when Custom is selected and usable, else a
    /// built-in level (Custom with no usable ruleset degrades to the built-in
    /// fallback instructions so the pass never goes out instruction-less).
    static func effectiveRequest(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdownFormatting: Bool,
        customRuleset: CustomCleanupRuleset?
    ) -> FormattingRequest {
        if intensity == .custom, let ruleset = customRuleset, ruleset.isUsable {
            return request(for: text, ruleset: ruleset)
        }
        // Custom with no usable ruleset degrades to Light cleanup, governor
        // included — the ungoverned path is only for the user's own rules.
        let effective: FormattingIntensity = intensity == .custom ? .lightCleanup : intensity
        return request(
            for: text,
            intensity: effective,
            includeMarkdownFormatting: includeMarkdownFormatting)
    }

    /// Clean up `text` at the user's chosen intensity, returning the input
    /// unchanged whenever the feature is off, the model is unavailable, the
    /// text is too short, the model errors, or the guardrail rejects the
    /// output.
    func format(_ text: String) async -> String {
        guard Self.isEnabled else { return text }
        guard Self.isModelAvailable else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = Self.words(in: trimmed).count
        guard wordCount >= Self.minimumWordCount else { return text }

        let request = Self.effectiveRequest(
            for: trimmed,
            intensity: Self.intensity,
            includeMarkdownFormatting: Self.isMarkdownFormattingEnabled,
            customRuleset: CustomRulesetStore.shared.usableActiveRuleset)
        do {
            let session = LanguageModelSession {
                request.instructionStages
            }
            let response = try await session.respond(
                to: request.input,
                options: GenerationOptions(temperature: request.temperature)
            )
            let cleaned = Self.stripModelPreamble(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines))

            let withinBudget: Bool
            if let budget = request.maximumChangeRatio {
                withinBudget = Self.changeRatio(from: trimmed, to: cleaned) <= budget
            } else {
                withinBudget = true
            }
            let accepted = !cleaned.isEmpty && withinBudget
            guard accepted else {
                AppLogger.debug(
                    "On-device formatting rejected by guardrail; keeping raw transcript",
                    category: AppLogger.transcription)
                return text
            }
            return cleaned
        } catch {
            AppLogger.warning(
                "On-device formatting failed; keeping raw transcript",
                category: AppLogger.transcription)
            return text
        }
    }

    // MARK: - Guardrail

    /// Fraction of word-level edits (insert/delete/substitute) between the two
    /// texts, relative to the longer one. Case- and punctuation-insensitive so
    /// pure formatting edits score 0. Spoken fillers and immediate false-start
    /// repeats are stripped first so a legitimate Light/Polish pass is not
    /// charged for the cleanup those levels are asked to do.
    static func changeRatio(from original: String, to revised: String) -> Double {
        let a = contentWords(in: original)
        let b = contentWords(in: revised)
        guard !a.isEmpty || !b.isEmpty else { return 0 }

        let distance = levenshtein(a, b)
        let outcome = Double(distance) / Double(max(a.count, b.count))
        AppLogger.debug(
            "On-device formatting change ratio: \(outcome)",
            category: AppLogger.transcription)
        return outcome
    }

    /// Tokens the guardrail treats as cleanup, not meaning. Matches the filler
    /// list in Light cleanup / Polish instructions and Auto Edit's um/uh family.
    private static let fillerTokens: Set<String> = [
        "um", "uh", "umm", "uhm", "erm", "hmm", "ah", "er",
    ]

    static func contentWords(in text: String) -> [String] {
        let raw = dropFillerPhrases(words(in: text))
        let withoutFillers = raw.filter { !fillerTokens.contains($0) }
        return collapseImmediateRepeats(withoutFillers)
    }

    /// Drops "you know" as a pair so those words are not treated as content.
    private static func dropFillerPhrases(_ words: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < words.count {
            if index + 1 < words.count, words[index] == "you", words[index + 1] == "know" {
                index += 2
                continue
            }
            out.append(words[index])
            index += 1
        }
        return out
    }

    /// "I was I was going" → "I was going". Unigram then bigram runs.
    private static func collapseImmediateRepeats(_ words: [String]) -> [String] {
        collapseRuns(collapseRuns(words, length: 2), length: 1)
    }

    private static func collapseRuns(_ words: [String], length: Int) -> [String] {
        guard length > 0, words.count >= length * 2 else { return words }
        var out: [String] = []
        var index = 0
        while index < words.count {
            let next = index + 2 * length
            if next <= words.count,
                Array(words[index..<(index + length)])
                    == Array(words[(index + length)..<next])
            {
                out.append(contentsOf: words[index..<(index + length)])
                index = next
                continue
            }
            out.append(words[index])
            index += 1
        }
        return out
    }

    /// Drops labels the model sometimes prepends despite the instructions,
    /// and instruction fragments it copies into the transcript.
    static func stripModelPreamble(_ text: String) -> String {
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leakedInstructions = [
            FormattingPromptStage.markdownFormatting,
            FormattingPromptStage.outputTranscriptOnly,
        ]
        for leak in leakedInstructions {
            let needle = leak.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, next.hasPrefix(needle) else { continue }
            next = String(next.dropFirst(needle.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        next = stripLeadingWrapperParagraph(next)
        if next.count >= 2 {
            let wrappedQuotes =
                (next.hasPrefix("\"") && next.hasSuffix("\""))
                || (next.hasPrefix("“") && next.hasSuffix("”"))
            if wrappedQuotes {
                next = String(next.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return next
    }

    /// Drops one leading conversational wrapper line. Real dictation is kept.
    static func stripLeadingWrapperParagraph(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let firstLine: String
        let remainder: String
        if let newline = trimmed.firstIndex(of: "\n") {
            firstLine = String(trimmed[..<newline])
            remainder = String(trimmed[trimmed.index(after: newline)...])
        } else {
            firstLine = trimmed
            remainder = ""
        }

        guard let afterWrapper = droppingWrapperPrefix(from: firstLine) else {
            return trimmed
        }
        let pieces = [afterWrapper, remainder]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "\n")
    }

    /// Known LLM labels, longest first so “cleaned-up” wins over “cleaned”.
    private static let wrapperPrefixes = [
        "here's the cleaned-up transcript:",
        "here is the cleaned-up transcript:",
        "here's the cleaned transcript:",
        "here is the cleaned transcript:",
        "here's the cleaned-up text:",
        "here is the cleaned-up text:",
        "here's the clean transcript:",
        "here is the clean transcript:",
        "here's the cleaned text:",
        "here is the cleaned text:",
        "here's the clean text:",
        "here is the clean text:",
        "here's the transcript:",
        "here is the transcript:",
        "cleaned-up transcript:",
        "cleaned transcript:",
        "cleaned-up text:",
        "cleaned text:",
        "clean text:",
    ]

    private static let courtesyOpeners = [
        "sure, ",
        "sure. ",
        "sure ",
        "okay, ",
        "okay. ",
        "ok, ",
        "ok. ",
    ]

    /// If `line` starts with a wrapper (optional markdown bold/italic, optional
    /// “Sure, ”), returns the rest of the line; otherwise nil.
    private static func droppingWrapperPrefix(from line: String) -> String? {
        var candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var openingWidth = 0
        if candidate.hasPrefix("**") {
            candidate = String(candidate.dropFirst(2))
            openingWidth = 2
        } else if candidate.hasPrefix("*") {
            candidate = String(candidate.dropFirst())
            openingWidth = 1
        }

        let comparable = candidate.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        var search = comparable
        var dropCount = 0
        if let opener = courtesyOpeners.first(where: { search.hasPrefix($0) }) {
            dropCount += opener.count
            search = String(search.dropFirst(opener.count))
        }
        guard let prefix = wrapperPrefixes.first(where: { search.hasPrefix($0) }) else {
            return nil
        }
        dropCount += prefix.count
        var rest = String(candidate.dropFirst(dropCount))
            .trimmingCharacters(in: .whitespaces)
        if openingWidth == 2, rest.hasPrefix("**") {
            rest = String(rest.dropFirst(2))
        } else if openingWidth == 1, rest.hasPrefix("*") {
            rest = String(rest.dropFirst())
        } else if rest.hasPrefix("**") {
            rest = String(rest.dropFirst(2))
        } else if rest.hasPrefix("*") {
            rest = String(rest.dropFirst())
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein distance. Transcripts are at most a few hundred
    /// words, so the O(n·m) table is cheap.
    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
