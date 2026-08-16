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

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .formatting: return "Formatting"
        case .lightCleanup: return "Light cleanup"
        case .polish: return "Polish"
        }
    }

    var summary: String {
        switch self {
        case .formatting:
            return "Capitals, commas, and paragraph breaks only. Does not add or drop words."
        case .lightCleanup:
            return "Drops false starts and repeated words, and fixes obvious grammar. Not the same as the filler-word toggle above — this can rewrite a phrase."
        case .polish:
            return "Turns choppy dictation into fluent sentences. Meaning and tone stay the same; wording may change."
        }
    }

    /// Model instructions for this level.
    var instructions: String {
        let base = """
            You clean up text dictated by voice. Reply with only the cleaned text — \
            no commentary, no labels, no quotation marks around it. Never write \
            phrases such as “here’s the clean text” or “cleaned text:”. Never add \
            information, never summarise, never reorder ideas.
            """
        switch self {
        case .formatting:
            return base + """

                Apply ONLY mechanical edits: fix spacing, capitalisation and \
                punctuation, and add sentence/paragraph breaks where the flow of \
                speech implies them. Do not add, remove or change any word.
                """
        case .lightCleanup:
            return base + """

                Apply these edits: remove filler words and false starts ("um", "uh", \
                "ah", "er", "you know", filler "like", repeated words); fix grammar, \
                punctuation, capitalisation and spacing; add sentence and paragraph \
                breaks where the flow of speech implies them. Preserve the speaker's \
                wording everywhere else.
                """
        case .polish:
            return base + """

                Apply these edits: remove filler words and false starts ("um", "uh", \
                "ah", "er", "you know", filler "like", repeated words); replace words \
                that don't make sense in the context of the wider text, the text is \
                a transcription so it's likely the correct word is phonetically similar. \
                Next, fix grammar, punctuation, capitalisation and spacing; add sentence \
                and paragraph breaks; where dictated phrasing is choppy or fragmented, \
                smooth it into fluent sentences. Keep the speaker's meaning, vocabulary \
                and tone — polish the delivery, never the message.
                """
        }
    }

    /// Maximum fraction of words the model may change/remove at this level
    /// before the output is rejected in favour of the raw transcript.
    var maximumChangeRatio: Double {
        switch self {
        case .formatting: return 0.10
        case .lightCleanup: return 0.35
        case .polish: return 0.70
        }
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

    /// Opt-in; default off.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
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

        let intensity = Self.intensity
        do {
            let session = LanguageModelSession(instructions: intensity.instructions)
            let response = try await session.respond(
                to: trimmed,
                options: GenerationOptions(temperature: 0.0)
            )
            let cleaned = Self.stripModelPreamble(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines))

            let ratio = Self.changeRatio(from: trimmed, to: cleaned)
            let accepted = !cleaned.isEmpty && ratio <= intensity.maximumChangeRatio
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
        return Double(distance) / Double(max(a.count, b.count))
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

    /// Drops labels the model sometimes prepends despite the instructions.
    static func stripModelPreamble(_ text: String) -> String {
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "here's the cleaned-up text:",
            "here is the cleaned-up text:",
            "here's the cleaned text:",
            "here is the cleaned text:",
            "here's the clean text:",
            "here is the clean text:",
            "cleaned-up text:",
            "cleaned text:",
            "clean text:",
        ]
        let lower = next.lowercased()
        if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
            next = String(next.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
