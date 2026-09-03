import Foundation

/// Text a cleanup preview can run on: a built-in dictation, or a recent take
/// from History (the engine text when it was kept, otherwise the pasted text).
nonisolated enum CleanupSampleSource: Hashable, Identifiable, Sendable {
    case builtIn(CleanupSampleTranscripts)
    case history(id: UUID, title: String, text: String)

    var id: String {
        switch self {
        case .builtIn(let sample): return "builtin." + sample.id
        case .history(let id, _, _): return "history." + id.uuidString
        }
    }

    var title: String {
        switch self {
        case .builtIn(let sample): return sample.title
        case .history(_, let title, _): return title
        }
    }

    var text: String {
        switch self {
        case .builtIn(let sample): return sample.text
        case .history(_, _, let text): return text
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    static let builtIn: [CleanupSampleSource] = CleanupSampleTranscripts.allCases.map { .builtIn($0) }
    static let defaultSource: CleanupSampleSource = .builtIn(.onboardingDefault)

    /// Newest first, capped, and long enough for the model to run. Prefers
    /// the raw engine text so a ruleset is tested on what was actually said.
    static func recent(
        from items: [HistoryItem],
        limit: Int = 5,
        minimumWordCount: Int = TranscriptFormatterService.minimumWordCount
    ) -> [CleanupSampleSource] {
        var out: [CleanupSampleSource] = []
        for item in items where out.count < limit {
            let text = (item.rawTranscript ?? item.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
            guard CleanupGuardrail.legacyWords(in: text).count >= minimumWordCount else { continue }
            out.append(.history(id: item.id, title: title(for: item.date, text: text), text: text))
        }
        return out
    }

    /// "3 Sep, 2:14 pm · Um so hi Priya, just following…"
    static func title(for date: Date, text: String, maxWords: Int = 6) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var excerpt = words.prefix(maxWords).joined(separator: " ")
        if words.count > maxWords { excerpt += "…" }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(excerpt)"
    }
}

/// One-line status for a preview outcome, shared by onboarding and the
/// ruleset test panel.
nonisolated enum CleanupOutcomeSummary {
    static func statusLine(for outcome: TranscriptCleanupOutcome) -> String {
        if let reason = outcome.skippedReason { return reason }
        guard let landed = outcome.landed else {
            if let error = outcome.error { return "Cleanup failed: \(error)" }
            return "Every level changed too much, so the transcript is shown as dictated."
        }
        var parts: [String] = []
        if outcome.steppedDown {
            parts.append("Stepped down to \(landed.displayName)")
        } else {
            parts.append(outcome.requested.displayName)
        }
        if let engine = outcome.engineName { parts.append(engine) }
        parts.append("\(outcome.totalDurationMs) ms")
        return parts.joined(separator: " · ")
    }
}
