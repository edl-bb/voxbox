import Foundation

/// Budget for one intensity. `cost` is the weighted edit count from
/// `CleanupGuardrail`; the pass is accepted when
/// `cost <= max(minFreeEdits, maxCostRatio * inputContentTokens)` and the
/// output retains at least `minRetention` of the input's content tokens.
nonisolated struct GuardrailBudget: Equatable, Sendable {
    var maxCostRatio: Double
    /// Absolute floor so a short take can still afford a few real edits.
    var minFreeEdits: Int
    /// Fraction of input content tokens that must survive (kept or
    /// substituted). Catches a summary whose deletions each fit the budget.
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
    /// The output repeats words from the model's own instructions that the
    /// speaker never said (a pasted example sentence).
    case instructionEcho(String)
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
    /// A unit family or clock time the dictation used ("pounds", "2pm").
    case unit(String)

    var display: String {
        switch self {
        case .email(let s), .url(let s), .number(let s), .unit(let s): return s
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
    /// Takes with this many content tokens or fewer are not governed by the
    /// edit budget at all; protected tokens, content loss, empty output and
    /// refusals are still checked.
    static let shortTakeTokens = 12

    /// Pure fillers, filler phrases, or a word repeated back to back: the
    /// things Light and Polish exist to remove. Decides whether a take too
    /// short for the model still deserves the instant pass.
    static func containsSpokenNoise(_ text: String, lexicon: FillerLexicon = .compiled) -> Bool {
        let words = tokens(text)
        if words.contains(where: { lexicon.pureTokens.contains($0) }) { return true }
        for phrase in lexicon.phrases where !phrase.isEmpty && words.count >= phrase.count {
            for start in 0...(words.count - phrase.count) where Array(words[start..<(start + phrase.count)]) == phrase {
                return true
            }
        }
        return zip(words, words.dropFirst()).contains { $0 == $1 }
    }

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
        let cost = breakdown.cost
        let retained = edits.reduce(0.0) { partial, edit in
            switch edit {
            case .keep: return partial + 1
            case .substitute: return partial + 1
            case .delete, .insert: return partial
            }
        }
        // Words the level was told to drop (fillers, false starts) are not
        // "lost content", so they leave the denominator as well as the cost.
        let retainable = Double(max(1, a.count - breakdown.freeDeletions))
        let retention = a.isEmpty ? 1 : min(1, retained / retainable)
        let ratio = cost / Double(n)
        let allowance = max(Double(budget.minFreeEdits), budget.maxCostRatio * Double(n))
        let verdict: GuardrailVerdict
        if let altered = firstAlteredProtectedToken(input: input, output: output) {
            verdict = .protectedTokenAltered(altered.display)
        } else if a.count > shortTakeTokens, cost > allowance {
            verdict = .changeRatioExceeded(ratio: ratio, budget: budget.maxCostRatio)
        } else if a.count > shortTakeTokens, retention < budget.minRetention {
            verdict = .retentionTooLow(kept: retention, floor: budget.minRetention)
        } else if let lost = contentLoss(in: edits, lexicon: lexicon) {
            verdict = .protectedTokenAltered(lost)
        } else if a.count <= shortTakeTokens {
            // Short takes skip ratios, but still keep content protections.
            verdict = .notGoverned
        } else {
            verdict = .accepted
        }
        return GuardrailEvaluation(
            verdict: verdict, costRatio: ratio, retention: retention, cost: cost, inputTokens: a.count)
    }

    /// Hard protections also apply to short takes. Run after pre-model repairs,
    /// so retracted words are not mistaken for lost content.
    static func contentLoss(in edits: [TokenEdit], lexicon: FillerLexicon = .compiled) -> String? {
        let negations: Set<String> = ["not", "never"]
        let person: [String: Int] = [
            "i": 1, "me": 1, "my": 1, "mine": 1,
            "you": 2, "your": 2, "yours": 2,
            "we": 3, "us": 3, "our": 3, "ours": 3,
        ]
        let input = edits.compactMap { edit -> String? in
            switch edit {
            case .keep(let word), .delete(let word), .substitute(let word, _): return word
            case .insert: return nil
            }
        }
        let output = edits.compactMap { edit -> String? in
            switch edit {
            case .keep(let word), .insert(let word), .substitute(_, let word): return word
            case .delete: return nil
            }
        }
        let lost = Set(input.filter { word in
            input.filter { $0 == word }.count > output.filter { $0 == word }.count
        })
        var index = 0
        while index < edits.count {
            switch edits[index] {
            case .substitute(let from, let to):
                if negations.contains(from), lost.contains(from) { return from }
                if let old = person[from], let new = person[to], old != new,
                    lost.contains(from),
                    output.filter({ $0 == to }).count > input.filter({ $0 == to }).count
                {
                    return "speaker person"
                }
                index += 1
            case .delete:
                var run: [String] = []
                var cursor = index
                while cursor < edits.count, case .delete(let token) = edits[cursor] {
                    run.append(token)
                    cursor += 1
                }
                // The alignment's free repeated prefix is still removable.
                if run != keptTokens(in: edits, from: cursor, count: run.count) {
                    if let negation = run.first(where: { negations.contains($0) && lost.contains($0) }) { return negation }
                    let content = run.filter {
                        lost.contains($0) && !lexicon.pureTokens.contains($0) && !lexicon.deletableTokens.contains($0)
                            && !functionWords.contains($0) && !numberUnitWords.contains($0)
                    }
                    // Losing a condition can invert an otherwise faithful
                    // request. Avoid treating arbitrary correction runs as clauses.
                    if let first = run.first, ["without", "unless"].contains(first), content.count >= 3 {
                        return "condition clause"
                    }
                }
                index = cursor
            case .keep, .insert:
                index += 1
            }
        }
        return nil
    }

    // MARK: - Instruction echo

    /// Shortest copied run that counts as an echo. Four-word runs collide
    /// with ordinary speech ("keep it as a"); five rarely do.
    static let echoRunLength = 5

    /// The first run of `echoRunLength` words that appears in `instructions`
    /// and in `output` but not in `input`. A small model near the end of a
    /// take that stops mid-sentence can paste an example sentence from its
    /// instructions; the edit budget alone misses it on a long take.
    static func echoedInstruction(output: String, input: String, instructions: String) -> String? {
        let n = echoRunLength
        let outputWords = tokens(output)
        guard outputWords.count >= n else { return nil }
        let instructionRuns = runs(of: tokens(instructions), length: n)
        guard !instructionRuns.isEmpty else { return nil }
        let inputRuns = runs(of: tokens(input), length: n)
        for start in 0...(outputWords.count - n) {
            let run = outputWords[start..<(start + n)].joined(separator: " ")
            if instructionRuns.contains(run), !inputRuns.contains(run) {
                return run
            }
        }
        return nil
    }

    private static func runs(of words: [String], length n: Int) -> Set<String> {
        guard words.count >= n else { return [] }
        return Set((0...(words.count - n)).map { words[$0..<($0 + n)].joined(separator: " ") })
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
        return collapseSpokenNumbers(out)
    }

    // MARK: - Spoken numbers

    private static let unitWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scaleWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    /// Words a numeral rewrite absorbs into a symbol ("dollars" → "$",
    /// "percent" → "%"). Deleting one is free.
    static let numberUnitWords: Set<String> = [
        "dollars", "dollar", "bucks", "cents", "cent", "percent", "pounds", "pound", "euros", "euro", "quid",
    ]

    static func isNumberWord(_ word: String) -> Bool {
        unitWords[word] != nil || tensWords[word] != nil || scaleWords[word] != nil
    }

    /// "twelve thousand five hundred" → "12500", so a Light or Polish pass
    /// that writes numerals compares equal to the dictation. Decimals split
    /// the way the digit form does ("two point five" → "2", "5").
    static func collapseSpokenNumbers(_ words: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(words.count)
        var index = 0
        while index < words.count {
            guard isNumberWord(words[index]) else {
                out.append(words[index])
                index += 1
                continue
            }
            var total = 0
            var current = 0
            var cursor = index
            var sawScale = false
            while cursor < words.count {
                let word = words[cursor]
                if let unit = unitWords[word] {
                    current += unit
                } else if let tens = tensWords[word] {
                    current += tens
                } else if let scale = scaleWords[word] {
                    // Checked: "hundred hundred hundred…" from a speech
                    // glitch would otherwise overflow Int and crash.
                    let (scaled, overflow) = max(current, 1).multipliedReportingOverflow(by: scale)
                    guard !overflow, scaled < 1_000_000_000_000_000 else { break }
                    if scale == 100 {
                        current = scaled
                    } else {
                        total += scaled
                        current = 0
                    }
                    sawScale = true
                } else if word == "and", sawScale, cursor + 1 < words.count, isNumberWord(words[cursor + 1]) {
                    // "one hundred and five"
                } else {
                    break
                }
                cursor += 1
            }
            out.append(String(total + current))
            if cursor + 1 < words.count, words[cursor] == "point", let first = unitWords[words[cursor + 1]], first < 10 {
                cursor += 1
                while cursor < words.count, let digit = unitWords[words[cursor]], digit < 10 {
                    out.append(String(digit))
                    cursor += 1
                }
            }
            index = cursor
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

    static func cost(of edits: [TokenEdit], lexicon: FillerLexicon) -> Double {
        costBreakdown(of: edits, lexicon: lexicon).cost
    }

    struct CostBreakdown: Equatable {
        var cost: Double
        /// Deletions that cost nothing: fillers, deletable words, false starts.
        var freeDeletions: Int
    }

    static func costBreakdown(of edits: [TokenEdit], lexicon: FillerLexicon) -> CostBreakdown {
        var total = 0.0
        var freeDeletions = 0
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
                    freeDeletions += run.count
                    index = cursor
                    continue
                }
                let nextKept = following.first
                for token in run {
                    let price = deletionCost(token, nextKept: nextKept, lexicon: lexicon)
                    if price == 0 { freeDeletions += 1 }
                    total += price
                }
                index = cursor
            }
        }
        return CostBreakdown(cost: total, freeDeletions: freeDeletions)
    }

    private static func deletionCost(_ token: String, nextKept: String?, lexicon: FillerLexicon) -> Double {
        if lexicon.pureTokens.contains(token) || lexicon.deletableTokens.contains(token) { return 0 }
        if numberUnitWords.contains(token) { return 0 }
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
            case .unit:
                break
            }
        }
        return alteredUnit(input: input, output: output).map(ProtectedToken.unit)
    }

    // MARK: - Units and times

    /// Unit families a model must not convert between. The Apple model
    /// "localised" pounds to kilos and 2pm to 14:00 for an en-AU speaker
    /// even when told not to.
    static let unitFamilies: [(name: String, pattern: String)] = [
        // "two pounds of apples" is a weight; "twenty pounds" alone is money
        // and becomes "£20".
        ("imperial weight", #"\b(?:pounds?|lbs?)\b(?= of\b)|\b(?:lbs?|ounces?|oz)\b"#),
        ("metric weight", #"\b(?:kilos?|kilograms?|kgs?|grams?)\b"#),
        ("imperial distance", #"\b(?:miles?|feet|foot|inch(?:es)?|yards?)\b"#),
        ("metric distance", #"\b(?:kilometres?|kilometers?|kms?|metres?|meters?|centimetres?|centimeters?|cm|mm)\b"#),
        ("imperial volume", #"\b(?:gallons?|pints?|fl oz)\b"#),
        ("metric volume", #"\b(?:litres?|liters?|millilitres?|milliliters?|ml)\b"#),
        ("Fahrenheit", #"\b(?:fahrenheit)\b"#),
        ("Celsius", #"\b(?:celsius|centigrade)\b"#),
    ]

    private static let numberWordPattern =
        "(?:\\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"

    /// "2pm", "2 p.m.", "two pm", "10:30am": the speaker said a 12-hour time.
    static func twelveHourTimes(in text: String) -> Int {
        let pattern = "(?i)\\b\(numberWordPattern)(?::\\d{2})?\\s?(?:am|pm|a\\.m\\.|p\\.m\\.)(?![a-z])"
        return matches(of: pattern, in: text).count
    }

    /// The first unit family that appeared or disappeared, a 12-hour time
    /// that became something else, a lost currency, day or month name, or a
    /// dictated list that lost one of its ordinals.
    static func alteredUnit(input: String, output: String) -> String? {
        let lowerIn = input.lowercased()
        let lowerOut = output.lowercased()
        for family in unitFamilies {
            let had = !matches(of: family.pattern, in: lowerIn).isEmpty
            let has = !matches(of: family.pattern, in: lowerOut).isEmpty
            if had != has { return family.name }
        }
        if twelveHourTimes(in: input) > twelveHourTimes(in: output) { return "12-hour time" }
        // Polish wrote "I think it was 12,500" for "twelve thousand five
        // hundred dollars": an amount that loses its currency. Symbols and
        // words count the same, so "$12,500" for "12,500 dollars" passes.
        // Presence, not count: "three dollars fifty cents" → "$3.50" is fine.
        if currencyMentions(in: lowerIn) > 0, currencyMentions(in: lowerOut) == 0 { return "currency" }
        // Polish wrote "options by mon." for "options by Monday": a day or
        // month the speaker named must survive in full.
        for name in calendarNames where count(of: name, in: lowerOut) < count(of: name, in: lowerIn) {
            return "date"
        }
        // Polish merged "Firstly, … And secondly, …" into one sentence and
        // dropped "secondly", which also stops the list from forming.
        // "Firstly" → "First" is fine, so compare without the "-ly".
        let ordinalsIn = Set(matches(of: spokenOrdinalPattern, in: lowerIn).map(ordinalStem))
        if ordinalsIn.count >= 2,
            !ordinalsIn.isSubset(of: Set(matches(of: #"\b[a-z]+\b"#, in: lowerOut).map(ordinalStem)))
        {
            return "spoken list"
        }
        return nil
    }

    private static let calendarNames = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august", "september",
        "october", "november", "december",
    ]

    /// An ordinal opening a sentence or clause: "First, …", ". And secondly, …".
    private static let spokenOrdinalPattern =
        #"(?:^|[.!?,]\s+)(?:and |then )?(?:first|firstly|second|secondly|third|thirdly|fourth|fifth|finally|lastly)\b"#

    private static func ordinalStem(_ match: String) -> String {
        let word = match.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? match
        return word.hasSuffix("ly") ? String(word.dropLast(2)) : word
    }

    private static func count(of word: String, in text: String) -> Int {
        matches(of: "\\b\(word)\\b", in: text).count
    }

    private static func currencyMentions(in text: String) -> Int {
        matches(of: #"[$£€]\s?\d|\b(?:dollars?|bucks?|quid|euros?|cents?)\b|\bpounds?\b(?! of)"#, in: text).count
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
