import Foundation

// MARK: - Case files

/// evals/cleanup/cases.json (synthetic, committed) or a *.local.json gold
/// file built from private History takes (gitignored).
nonisolated struct EvalSuite: Decodable, Sendable {
    var language: String?
    var contexts: [String: EvalContext]?
    var cases: [EvalCase]
}

nonisolated struct EvalContext: Decodable, Sendable {
    var about: String
    var vocabulary: [String]

    var speaker: SpeakerContext { SpeakerContext(about: about, vocabulary: vocabulary) }
}

nonisolated struct EvalCase: Decodable, Sendable {
    var id: String
    var tags: [String]?
    var raw: String
    /// Key into the suite's `contexts`.
    var context: String?
    var language: String?
    /// Run with the Markdown toggle on (list cases).
    var markdown: Bool?
    /// Reference output per level: "basic", "light", "polish". Levels
    /// without a reference are not run for this case.
    var expected: [String: String]
    /// Phrases that must survive at every level.
    var keep: [String]?
    /// Phrases Light and Polish must remove.
    var drop: [String]?
    /// Phrases that must never appear (hallucinations, answers, echoes).
    var forbid: [String]?
    /// Corrections a level should make (misheard words, vocabulary).
    var fix: [EvalFix]?
    /// Case-sensitive substrings that must never appear (". it's").
    var forbidText: [String]?
    /// The output must end with these words: a take cut off mid-sentence
    /// must not be finished by the model.
    var endsWith: String?
    var note: String?
}

nonisolated struct EvalFix: Decodable, Sendable {
    /// Case-sensitive phrase that should appear in the output.
    var to: String
    /// Only expected when the speaker context is supplied.
    var needsContext: Bool?
    /// Levels that should make the fix; default Polish only, or Light and
    /// Polish for vocabulary fixes.
    var levels: [String]?

    func applies(level: EvalLevel, contextOn: Bool) -> Bool {
        if needsContext == true, !contextOn { return false }
        if let levels { return levels.contains(level.rawValue) }
        return needsContext == true ? level != .basic : level == .polish
    }
}

nonisolated enum EvalLevel: String, CaseIterable, Codable, Sendable {
    case basic, light, polish

    var option: CleanupOption {
        switch self {
        case .basic: return .basic
        case .light: return .light
        case .polish: return .polish
        }
    }

    var intensity: FormattingIntensity {
        switch self {
        case .basic: return .formatting
        case .light: return .lightCleanup
        case .polish: return .polish
        }
    }
}

// MARK: - Results

nonisolated struct EvalCheck: Codable, Sendable {
    var name: String
    var passed: Bool
    var detail: String?
}

nonisolated struct EvalRow: Codable, Sendable {
    var caseId: String
    var tags: [String]
    var promptSet: String
    var level: EvalLevel
    var contextOn: Bool
    var raw: String
    var expected: String
    var output: String
    var landed: String
    var verdicts: [String]
    /// Raw model text per attempt, before the post-pass.
    var attemptOutputs: [String]
    var error: String?
    var totalMs: Int
    var modelMs: Int
    var attempts: Int
    var wordErrorRate: Double
    var charSimilarity: Double
    var exact: Bool
    var checks: [EvalCheck]
    var fixesWanted: Int
    var fixesMade: Int
    var contractionsWanted: Int
    var contractionsKept: Int
    /// Longest the main actor went without running during this row.
    var mainThreadGapMs: Int

    var passed: Bool { checks.allSatisfy(\.passed) }
}

// MARK: - Scoring

nonisolated enum EvalScorer {
    /// Lowercased words with surrounding punctuation and list markers
    /// removed. Contractions are kept as written, so "I'm" → "I am" counts
    /// as an edit: the speaker said "I'm".
    static func words(_ text: String, caseSensitive: Bool = false) -> [String] {
        var t = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        t = t.replacingOccurrences(of: #"(?m)^\s*(?:[-*•]|\d+[.)])\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: " ")
        t = t.replacingOccurrences(of: #"(\d) ?([ap])\.?m\b\.?"#, with: "$1$2m", options: [.regularExpression, .caseInsensitive])
        if !caseSensitive { t = t.lowercased() }
        let strip = CharacterSet(charactersIn: ".,!?;:\"'()[]…*_")
        return t.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: strip) }
            .filter { !$0.isEmpty }
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func wordErrorRate(output: String, expected: String) -> Double {
        let reference = words(expected)
        return Double(editDistance(words(output), reference)) / Double(max(1, reference.count))
    }

    /// 1 − normalised character edit distance on the whitespace-collapsed
    /// text, so punctuation and capitals count.
    static func charSimilarity(output: String, expected: String) -> Double {
        let a = Array(collapse(output))
        let b = Array(collapse(expected))
        let longest = max(1, max(a.count, b.count))
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func containsRun(_ phrase: String, in text: String, caseSensitive: Bool = false) -> Bool {
        let needle = words(phrase, caseSensitive: caseSensitive)
        let hay = words(text, caseSensitive: caseSensitive)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    static let firstPerson: Set<String> = ["i", "me", "my", "mine", "myself", "i'm", "i've", "i'll", "i'd"]
    static let secondPerson: Set<String> = ["you", "your", "yours", "yourself", "you're", "you've", "you'll", "you'd"]
    static let hesitations: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "umm", "uhh"]

    static func count(_ set: Set<String>, in text: String) -> Int {
        words(text).filter(set.contains).count
    }

    static func hasList(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let items = lines.filter { $0.range(of: #"^\s*(?:[-*•]|\d+[.)])\s+\S"#, options: .regularExpression) != nil }
        return items.count >= 2
    }

    static func hasMarkdown(_ text: String) -> Bool {
        hasList(text) || text.contains("**") || text.range(of: #"(?m)^#+\s"#, options: .regularExpression) != nil
    }

    static func contractions(in text: String) -> [String] {
        let pattern = #"\b[A-Za-z]+'(?:m|s|re|ve|ll|d|t)\b"#
        let normalised = text.replacingOccurrences(of: "’", with: "'")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = normalised as NSString
        return regex.matches(in: normalised, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    static let answerOpeners = [
        "here is", "here's", "sure", "certainly", "of course", "i can help", "i'd be happy", "i would be happy",
        "cleaned", "edited", "the edited", "the cleaned", "as an ai",
    ]

    /// Sentence ends: . ? ! followed by whitespace or the end, so URLs,
    /// emails and decimals do not count.
    static func sentenceCount(_ text: String) -> Int {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
        guard let regex = try? NSRegularExpression(pattern: #"[.?!]+(?=\s|$)"#) else { return 1 }
        return max(1, regex.numberOfMatches(in: flat, range: NSRange(location: 0, length: (flat as NSString).length)))
    }

    static func score(
        evalCase: EvalCase, level: EvalLevel, contextOn: Bool, output: String, expected: String,
        instructions: String
    ) -> (checks: [EvalCheck], fixesWanted: Int, fixesMade: Int, contractionsWanted: Int, contractionsKept: Int) {
        var checks: [EvalCheck] = []

        let lostKeeps = (evalCase.keep ?? []).filter { !containsRun($0, in: output) }
        checks.append(EvalCheck(name: "keep", passed: lostKeeps.isEmpty, detail: lostKeeps.isEmpty ? nil : lostKeeps.joined(separator: " | ")))

        if level != .basic {
            let leftovers = (evalCase.drop ?? []).filter { containsRun($0, in: output) }
            let hesitationCount = count(hesitations, in: output)
            var detail = leftovers
            if hesitationCount > 0 { detail.append("\(hesitationCount) hesitation(s)") }
            checks.append(EvalCheck(name: "drop", passed: detail.isEmpty, detail: detail.isEmpty ? nil : detail.joined(separator: " | ")))
        } else {
            let lost = words(evalCase.raw).count - words(output).count
            checks.append(EvalCheck(name: "words", passed: words(output) == words(evalCase.raw), detail: lost == 0 ? nil : "\(lost) word(s) fewer"))
        }

        let forbidden = (evalCase.forbid ?? []).filter { containsRun($0, in: output) }
            + (evalCase.forbidText ?? []).filter { output.contains($0) }
        checks.append(EvalCheck(name: "forbid", passed: forbidden.isEmpty, detail: forbidden.isEmpty ? nil : forbidden.joined(separator: " | ")))

        if let ending = evalCase.endsWith {
            let tail = words(ending)
            let ok = words(output).suffix(tail.count).elementsEqual(tail)
            checks.append(EvalCheck(name: "ending", passed: ok, detail: ok ? nil : "does not end with \"\(ending)\""))
        }

        let wantQuestions = expected.filter { $0 == "?" }.count
        let gotQuestions = output.filter { $0 == "?" }.count
        checks.append(EvalCheck(name: "questions", passed: wantQuestions == gotQuestions,
            detail: wantQuestions == gotQuestions ? nil : "\(gotQuestions) ? (want \(wantQuestions))"))

        // Run-ons (comma splices) and choppy fragments both move the count.
        let wantSentences = sentenceCount(expected), gotSentences = sentenceCount(output)
        let sentencesOK = abs(wantSentences - gotSentences) <= max(1, wantSentences / 4)
        checks.append(EvalCheck(name: "sentences", passed: sentencesOK,
            detail: sentencesOK ? nil : "\(gotSentences) sentence(s) (want \(wantSentences))"))

        let firstWant = count(firstPerson, in: expected), firstGot = count(firstPerson, in: output)
        let secondWant = count(secondPerson, in: expected), secondGot = count(secondPerson, in: output)
        let personOK = abs(firstWant - firstGot) <= 1 && abs(secondWant - secondGot) <= 1
        checks.append(EvalCheck(name: "person", passed: personOK,
            detail: personOK ? nil : "I/me \(firstGot) (want \(firstWant)), you \(secondGot) (want \(secondWant))"))

        let wantList = hasList(expected)
        let markdownOK = wantList ? hasList(output) : !hasMarkdown(output)
        checks.append(EvalCheck(name: "markdown", passed: markdownOK,
            detail: markdownOK ? nil : (wantList ? "no list" : "unwanted markdown")))

        let echo = CleanupGuardrail.echoedInstruction(output: output, input: evalCase.raw, instructions: instructions)
        checks.append(EvalCheck(name: "echo", passed: echo == nil, detail: echo))

        let opening = output.lowercased().trimmingCharacters(in: .whitespaces)
        let rawOpening = evalCase.raw.lowercased()
        let answered = answerOpeners.first { opening.hasPrefix($0) && !rawOpening.hasPrefix($0) }
        checks.append(EvalCheck(name: "answer", passed: answered == nil && !output.isEmpty,
            detail: output.isEmpty ? "empty" : answered.map { "opens with \"\($0)\"" }))

        let fixes = (evalCase.fix ?? []).filter { $0.applies(level: level, contextOn: contextOn) }
        let made = fixes.filter { containsRun($0.to, in: output, caseSensitive: true) }.count

        let wanted = Set(contractions(in: expected))
        let kept = wanted.intersection(Set(contractions(in: output)))

        return (checks, fixes.count, made, wanted.count, kept.count)
    }
}
