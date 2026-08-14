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
            return "Fixes spacing, capitalisation, punctuation and paragraph breaks. Never touches your words."
        case .lightCleanup:
            return "Also removes fillers like “um” and “uh”, false starts and repeated words, and fixes obvious grammar slips."
        case .polish:
            return "Also smooths choppy dictated phrasing into fluent sentences. Meaning and tone are preserved."
        }
    }

    /// Model instructions for this level.
    var instructions: String {
        let base = """
            You clean up text dictated by voice. Reply with only the cleaned text — \
            no commentary, no quotation marks around it. Never add information, \
            never summarise, never reorder ideas.
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

                Apply these edits: remove filler words and false starts; fix grammar, \
                punctuation, capitalisation and spacing; add sentence and paragraph \
                breaks; where dictated phrasing is choppy or fragmented, smooth it \
                into fluent sentences. Keep the speaker's meaning, vocabulary and \
                tone — polish the delivery, never the message.
                """
        }
    }

    /// Maximum fraction of words the model may change/remove at this level
    /// before the output is rejected in favour of the raw transcript.
    var maximumChangeRatio: Double {
        switch self {
        case .formatting: return 0.10
        case .lightCleanup: return 0.35
        case .polish: return 0.50
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
        FormattingIntensity(rawValue: UserDefaults.standard.integer(forKey: intensityKey))
            ?? .lightCleanup
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

    /// Clean up `text` at the user's chosen intensity, returning the input
    /// unchanged whenever the feature is off, the model is unavailable, the
    /// text is too short, the model errors, or the guardrail rejects the
    /// output.
    func format(_ text: String) async -> String {
        guard Self.isEnabled else { return text }
        guard Self.isModelAvailable else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.words(in: trimmed).count >= Self.minimumWordCount else { return text }

        let intensity = Self.intensity
        do {
            let session = LanguageModelSession(instructions: intensity.instructions)
            let response = try await session.respond(
                to: trimmed,
                options: GenerationOptions(temperature: 0.0)
            )
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleaned.isEmpty,
                Self.changeRatio(from: trimmed, to: cleaned) <= intensity.maximumChangeRatio
            else {
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
    /// pure formatting edits score 0.
    static func changeRatio(from original: String, to revised: String) -> Double {
        let a = words(in: original)
        let b = words(in: revised)
        guard !a.isEmpty || !b.isEmpty else { return 0 }

        let distance = levenshtein(a, b)
        return Double(distance) / Double(max(a.count, b.count))
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
