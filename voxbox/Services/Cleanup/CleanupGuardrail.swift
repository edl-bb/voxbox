import Foundation

/// Budget for one intensity. `cost` is the weighted edit count from
/// `CleanupGuardrail`; the pass is accepted when
/// `cost <= max(minFreeEdits, maxCostRatio * inputContentTokens)` and the
/// output retains at least `minRetention` of the input's content tokens.
nonisolated struct GuardrailBudget: Equatable, Sendable {
    var maxCostRatio: Double
    /// Absolute floor so a short take can still afford a few real edits.
    var minFreeEdits: Int
    /// Fraction of input content tokens that must survive (kept, substituted,
    /// or deleted for free as a filler, repeat or false start). Catches a
    /// summary whose deletions each fit the budget.
    var minRetention: Double
}

/// Words the built-in levels are told to delete. Deleting them is free.
nonisolated struct FillerLexicon: Equatable, Sendable {
    /// Pure fillers: invisible to the guardrail on both sides.
    var pureTokens: Set<String>
    /// Multi-word fillers, also invisible on both sides.
    var phrases: [[String]]
    /// Words that are fillers in speech but content elsewhere ("like",
    /// "so", "right"). Deleting one is free; inserting or replacing one is
    /// charged normally.
    var deletableTokens: Set<String>

    static let compiled = FillerLexicon(
        pureTokens: ["um", "uh", "umm", "uhm", "erm", "hmm", "ah", "er", "mm", "mhm"],
        phrases: [["you", "know"], ["i", "mean"], ["sort", "of"], ["kind", "of"], ["kinda"], ["sorta"]],
        deletableTokens: [
            "like", "so", "basically", "actually", "literally", "right", "okay", "ok", "yeah",
            "well", "just", "anyway",
        ]
    )

    /// Comma-separated form for the DEBUG tuner.
    var pureTokensText: String { pureTokens.sorted().joined(separator: ", ") }
    var deletableTokensText: String { deletableTokens.sorted().joined(separator: ", ") }
}

nonisolated enum GuardrailVerdict: Equatable, Sendable {
    case accepted
    /// Custom ruleset or off: nothing to check.
    case notGoverned
    case changeRatioExceeded(ratio: Double, budget: Double)
    case retentionTooLow(kept: Double, floor: Double)
    /// An email, URL, or number from the dictation did not survive.
    case protectedTokenAltered(String)
    case emptyOutput
    /// The model answered with a refusal instead of the text.
    case refusal
    /// Apple's content filter rejected the request itself.
    case appleContentFilter
    case engineError(String)

    var isAccepted: Bool { self == .accepted || self == .notGoverned }
}

nonisolated struct GuardrailEvaluation: Equatable, Sendable {
    var verdict: GuardrailVerdict
    /// Weighted edits divided by input content tokens.
    var costRatio: Double
    var retention: Double
    var cost: Double
    var inputTokens: Int
}

/// One aligned edit between the input and output token streams.
nonisolated enum TokenEdit: Equatable, Sendable {
    case keep(String)
    case delete(String)
    case insert(String)
    case substitute(String, String)
}

nonisolated enum ProtectedToken: Equatable, Hashable, Sendable {
    case email(String)
    case url(String)
    /// Digits only, separators removed: `12,500` and `12500` are the same.
    case number(String)

    var display: String {
        switch self {
        case .email(let s), .url(let s), .number(let s): return s
        }
    }
}

/// Asymmetric edit budget. The old symmetric word-Levenshtein ratio charged
/// full price for exactly the edits Light cleanup is told to make (dropping
/// filler "like", "sort of", non-adjacent false starts), so Light tripped
/// the guardrail and the raw transcript shipped. Here fillers and false
/// starts are free, grammar normalisation is free (contractions expand
/// before comparing), function words and near-spelling fixes are half
/// price, and everything else costs one.
nonisolated enum CleanupGuardrail {
    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "and", "or", "is", "are", "was", "be", "it",
        "that", "at", "for", "with",
    ]

    // MARK: - Evaluate

    static func evaluate(
        input: String,
        output: String,
        budget: GuardrailBudget,
        lexicon: FillerLexicon = .compiled
    ) -> GuardrailEvaluation {
        let a = contentTokens(in: input, lexicon: lexicon)
        let b = contentTokens(in: output, lexicon: lexicon)
        let n = max(1, a.count)

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GuardrailEvaluation(
                verdict: .emptyOutput, costRatio: 1, retention: 0, cost: Double(n), inputTokens: a.count)
        }
        if CleanupPostPass.looksLikeRefusal(output) {
            return GuardrailEvaluation(
                verdict: .refusal, costRatio: 1, retention: 0, cost: Double(n), inputTokens: a.count)
        }

        let edits = alignedEdits(a, b)
        let breakdown = costBreakdown(of: edits, lexicon: lexicon)
        let cost = breakdown.total
        // Free deletions (fillers, repeats, false starts) are exactly what
        // Light cleanup is told to make, so they do not count against
        // retention; only deletions that cost something can signal a summary.
        let retention = a.isEmpty ? 1 : Double(a.count - breakdown.costlyDeletions) / Double(a.count)
        let ratio = cost / Double(n)
        let allowance = max(Double(budget.minFreeEdits), budget.maxCostRatio * Double(n))

        let verdict: GuardrailVerdict
        if let altered = firstAlteredProtectedToken(input: input, output: output) {
            verdict = .protectedTokenAltered(altered.display)
        } else if cost > allowance {
            verdict = .changeRatioExceeded(ratio: ratio, budget: budget.maxCostRatio)
        } else if retention < budget.minRetention {
            verdict = .retentionTooLow(kept: retention, floor: budget.minRetention)
        } else {
            verdict = .accepted
        }
        return GuardrailEvaluation(
            verdict: verdict, costRatio: ratio, retention: retention, cost: cost, inputTokens: a.count)
    }

    // MARK: - Tokens

    /// Lowercased word tokens with contractions expanded and thousands
    /// separators removed, so `I'm gonna` and `I am going to` compare equal
    /// and `12,500` is one token.
    static func tokens(_ text: String) -> [String] {
        var normalised = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        normalised = normalised.replacingOccurrences(
            of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)

        let rawWords = normalised.components(separatedBy: wordSeparators).filter { !$0.isEmpty }
        var out: [String] = []
        out.reserveCapacity(rawWords.count + 4)
        for word in rawWords {
            out.append(contentsOf: expandContraction(word))
        }
        return out
    }

    private static let wordSeparators: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert("'")
        return set.inverted
    }()

    private static let contractionMap: [String: [String]] = [
        "i'm": ["i", "am"], "can't": ["can", "not"], "cannot": ["can", "not"], "won't": ["will", "not"],
        "it's": ["it", "is"], "that's": ["that", "is"], "there's": ["there", "is"],
        "here's": ["here", "is"], "what's": ["what", "is"], "let's": ["let", "us"],
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "y'all": ["you", "all"], "ain't": ["is", "not"],
    ]

    static func expandContraction(_ word: String) -> [String] {
        if let mapped = contractionMap[word] { return mapped }
        guard word.contains("'") else { return [word] }
        if word.hasSuffix("n't") { return [String(word.dropLast(3)), "not"] }
        if word.hasSuffix("'re") { return [String(word.dropLast(3)), "are"] }
        if word.hasSuffix("'ve") { return [String(word.dropLast(3)), "have"] }
        if word.hasSuffix("'ll") { return [String(word.dropLast(3)), "will"] }
        if word.hasSuffix("'d") { return [String(word.dropLast(2)), "would"] }
        if word.hasSuffix("'s") { return [String(word.dropLast(2))] }  // possessive
        let stripped = word.replacingOccurrences(of: "'", with: "")
        return stripped.isEmpty ? [] : [stripped]
    }

    /// Tokens with pure fillers and filler phrases removed. Both sides are
    /// filtered, so deleting them is free and keeping them is neutral.
    static func contentTokens(in text: String, lexicon: FillerLexicon) -> [String] {
        let words = tokens(text)
        var out: [String] = []
        var index = 0
        outer: while index < words.count {
            for phrase in lexicon.phrases where !phrase.isEmpty {
                if index + phrase.count <= words.count,
                    Array(words[index..<(index + phrase.count)]) == phrase
                {
                    index += phrase.count
                    continue outer
                }
            }
            if !lexicon.pureTokens.contains(words[index]) {
                out.append(words[index])
            }
            index += 1
        }
        return out
    }

    // MARK: - Alignment

    /// Word-level Levenshtein with backtrace. Inputs are a few hundred
    /// tokens, so the O(n·m) table is cheap.
    static func alignedEdits(_ a: [String], _ b: [String]) -> [TokenEdit] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { table[i][0] = i }
        for j in 0...m { table[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let substitution = table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                table[i][j] = Swift.min(table[i - 1][j] + 1, table[i][j - 1] + 1, substitution)
            }
        }

        var edits: [TokenEdit] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], table[i][j] == table[i - 1][j - 1] {
                edits.append(.keep(a[i - 1]))
                i -= 1
                j -= 1
            } else if i > 0, j > 0, table[i][j] == table[i - 1][j - 1] + 1 {
                edits.append(.substitute(a[i - 1], b[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0, table[i][j] == table[i - 1][j] + 1 {
                edits.append(.delete(a[i - 1]))
                i -= 1
            } else {
                edits.append(.insert(b[j - 1]))
                j -= 1
            }
        }
        edits.reverse()
        return edits
    }

    // MARK: - Cost

    struct CostBreakdown: Equatable {
        var total: Double
        /// Deleted input tokens that were not free (content words, function words).
        var costlyDeletions: Int
    }

    static func cost(of edits: [TokenEdit], lexicon: FillerLexicon) -> Double {
        costBreakdown(of: edits, lexicon: lexicon).total
    }

    static func costBreakdown(of edits: [TokenEdit], lexicon: FillerLexicon) -> CostBreakdown {
        var total = 0.0
        var costlyDeletions = 0
        var index = 0
        while index < edits.count {
            switch edits[index] {
            case .keep:
                index += 1
            case .insert(let token):
                total += functionWords.contains(token) ? 0.5 : 1
                index += 1
            case .substitute(let from, let to):
                total += areSimilarWords(from, to) ? 0.5 : 1
                index += 1
            case .delete:
                // Gather the whole deletion run and the kept run after it.
                var run: [String] = []
                var cursor = index
                while cursor < edits.count, case .delete(let token) = edits[cursor] {
                    run.append(token)
                    cursor += 1
                }
                let following = keptTokens(in: edits, from: cursor, count: run.count)
                if run == following {
                    // "I was I was going": the whole run repeats.
                    index = cursor
                    continue
                }
                let nextKept = following.first
                for token in run {
                    let tokenCost = deletionCost(token, nextKept: nextKept, lexicon: lexicon)
                    total += tokenCost
                    if tokenCost > 0 { costlyDeletions += 1 }
                }
                index = cursor
            }
        }
        return CostBreakdown(total: total, costlyDeletions: costlyDeletions)
    }

    private static func deletionCost(_ token: String, nextKept: String?, lexicon: FillerLexicon) -> Double {
        if lexicon.pureTokens.contains(token) || lexicon.deletableTokens.contains(token) { return 0 }
        if let nextKept {
            if nextKept == token { return 0 }  // false start: "want... wanted"
            if sharedPrefixLength(token, nextKept) >= 4 { return 0 }
        }
        if functionWords.contains(token) { return 0.5 }
        return 1
    }

    private static func keptTokens(in edits: [TokenEdit], from start: Int, count: Int) -> [String] {
        var out: [String] = []
        var cursor = start
        while cursor < edits.count, out.count < count {
            switch edits[cursor] {
            case .keep(let token): out.append(token)
            case .substitute(_, let to): out.append(to)
            case .insert(let token): out.append(token)
            case .delete: break
            }
            cursor += 1
        }
        return out
    }

    static func areSimilarWords(_ a: String, _ b: String) -> Bool {
        if sharedPrefixLength(a, b) >= 4 { return true }
        guard min(a.count, b.count) >= 5 else { return false }
        return characterDistance(a, b) <= 2
    }

    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }

    private static func characterDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: - Protected tokens

    private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let urlPattern = #"(?:https?://|www\.)[^\s<>"']+"#
    private static let numberPattern = #"\d(?:[\d,.]*\d)?"#

    static func protectedTokens(in text: String) -> [ProtectedToken] {
        var out: [ProtectedToken] = []
        for match in matches(of: emailPattern, in: text) { out.append(.email(match)) }
        for match in matches(of: urlPattern, in: text) {
            out.append(.url(match.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))))
        }
        let withoutEmailsAndURLs = text
            .replacingOccurrences(of: emailPattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: urlPattern, with: " ", options: .regularExpression)
        for match in matches(of: numberPattern, in: withoutEmailsAndURLs) {
            let digits = match.filter(\.isNumber)
            if !digits.isEmpty { out.append(.number(digits)) }
        }
        return out
    }

    /// Ranges of emails and URLs, so text passes can leave them alone.
    static func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        for pattern in [emailPattern, urlPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges.append(contentsOf: regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range))
        }
        return ranges
    }

    static func firstAlteredProtectedToken(input: String, output: String) -> ProtectedToken? {
        let required = protectedTokens(in: input)
        guard !required.isEmpty else { return nil }
        let lowered = output.lowercased()
        let outputNumbers = Set(protectedTokens(in: output).compactMap { token -> String? in
            if case .number(let digits) = token { return digits }
            return nil
        })
        for token in required {
            switch token {
            case .email(let s), .url(let s):
                if !lowered.contains(s.lowercased()) { return token }
            case .number(let digits):
                if !outputNumbers.contains(digits) { return token }
            }
        }
        return nil
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Legacy (reporting only)

    /// The 1.2.0 symmetric word-Levenshtein ratio. Kept so the eval report
    /// can show both numbers side by side; nothing ships on it.
    static func legacyChangeRatio(from original: String, to revised: String) -> Double {
        let a = legacyContentWords(in: original)
        let b = legacyContentWords(in: revised)
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let distance = alignedEdits(a, b).filter { if case .keep = $0 { return false } else { return true } }.count
        return Double(distance) / Double(max(a.count, b.count))
    }

    static func legacyWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func legacyContentWords(in text: String) -> [String] {
        let fillers: Set<String> = ["um", "uh", "umm", "uhm", "erm", "hmm", "ah", "er"]
        var words: [String] = []
        let raw = legacyWords(in: text)
        var index = 0
        while index < raw.count {
            if index + 1 < raw.count, raw[index] == "you", raw[index + 1] == "know" {
                index += 2
                continue
            }
            if !fillers.contains(raw[index]) { words.append(raw[index]) }
            index += 1
        }
        return collapseRuns(collapseRuns(words, length: 2), length: 1)
    }

    private static func collapseRuns(_ words: [String], length: Int) -> [String] {
        guard length > 0, words.count >= length * 2 else { return words }
        var out: [String] = []
        var index = 0
        while index < words.count {
            let next = index + 2 * length
            if next <= words.count,
                Array(words[index..<(index + length)]) == Array(words[(index + length)..<next])
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
}
