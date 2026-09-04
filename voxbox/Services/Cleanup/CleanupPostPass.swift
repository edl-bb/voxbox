import Foundation

/// Deterministic repairs applied to model output before the guardrail:
/// strip preambles and refusals, tidy punctuation and whitespace, and undo
/// casing the speaker did not ask for. Emails and URLs are never touched.
nonisolated enum CleanupPostPass {
    struct TidyResult: Equatable {
        var text: String
        /// Uppercase ratio still high after repair: worth a look in the tuner.
        var casingAnomaly: Bool
    }

    // MARK: - Tidy

    static func tidy(
        _ output: String, reference input: String, markdownAllowed: Bool, numerals: Bool = false,
        spokenFillers: Bool = false, joinFragments: Bool = false
    ) -> String {
        tidyWithDiagnostics(
            output, reference: input, markdownAllowed: markdownAllowed, numerals: numerals,
            spokenFillers: spokenFillers, joinFragments: joinFragments
        ).text
    }

    /// `numerals` renders spoken numbers as digits, `spokenFillers` strips
    /// the unambiguous fillers and immediate repeats a lazy model pass left
    /// behind (both for Light and Polish), and `joinFragments` folds a
    /// sentence that begins with a conjunction back onto the one before it
    /// (Polish).
    static func tidyWithDiagnostics(
        _ output: String, reference input: String, markdownAllowed: Bool, numerals: Bool = false,
        spokenFillers: Bool = false, joinFragments: Bool = false
    ) -> TidyResult {
        var text = output
        if !markdownAllowed {
            text = stripMarkdownResidue(text)
        }
        text = normaliseWhitespace(text)
        text = applyOutsideProtectedSpans(text) { segment in
            var next = segment
            if spokenFillers { next = stripSpokenFillers(next) }
            if numerals { next = SpokenNumbers.render(in: next) }
            if joinFragments { next = joinPauseFragments(next) }
            return normalisePunctuation(next)
        }
        text = fixTrailingEllipsis(text, reference: input)
        text = repairCasing(text, reference: input)
        text = capitaliseSentenceStarts(text)
        text = normaliseWhitespace(text)
        let anomaly = uppercaseRatio(text) > max(0.30, 2 * uppercaseRatio(input) + 0.05)
        return TidyResult(text: text, casingAnomaly: anomaly)
    }

    /// A speech engine ends a sentence wherever the speaker paused, so a
    /// dictation is full of fragments that begin with a conjunction: "…in
    /// faster sections. And the pauses…". Fold those back onto the previous
    /// sentence with a comma. Only after a full stop that follows a letter
    /// (never "?", "!", a number or an abbreviation), and never at the start
    /// of a paragraph.
    static func joinPauseFragments(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[a-z]{2})\. (And|But|Because|Which|Or) (?=[a-z])"#) else {
            return text
        }
        let ns = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            ns.replaceCharacters(in: match.range, with: ", \(word) ")
        }
        return ns as String
    }

    /// Words that legitimately repeat ("had had", "that that is").
    private static let allowedRepeats: Set<String> = ["had", "that", "very", "no", "bye", "so", "is", "ha"]

    /// The deterministic backstop behind Light and Polish: um/uh-family
    /// fillers (via Auto Edit's rules), filler phrases set off by commas, and
    /// a word or contraction repeated back to back ("I'm, I'm gonna").
    /// Context-dependent fillers ("like", "basically") are left to the model.
    static func stripSpokenFillers(_ text: String) -> String {
        var next = AutoEdit.stripFillers(text)
        // "so, you know, have a play" → "so have a play"; "Yes, you know, we" → "Yes, we".
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b([A-Za-z']+),\s*(?:you know|i mean|sort of|kind of),\s*"#) {
            let ns = NSMutableString(string: next)
            for match in regex.matches(in: next, range: NSRange(location: 0, length: ns.length)).reversed() {
                let before = ns.substring(with: match.range(at: 1))
                let joiner = connectives.contains(before.lowercased()) ? " " : ", "
                ns.replaceCharacters(in: match.range, with: before + joiner)
            }
            next = ns as String
        }
        // "You know, we should…" → "we should…" (the sentence capital comes later).
        next = next.replacingOccurrences(
            of: #"(?im)(^|[.!?]\s+)(?:you know|i mean|sort of|kind of),\s*"#, with: "$1", options: .regularExpression)
        // Immediate repeats, optionally separated by a comma.
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b([A-Za-z]+(?:'[A-Za-z]+)?)(?:,\s*|\s+)\1\b"#) {
            let ns = NSMutableString(string: next)
            for match in regex.matches(in: next, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: match.range(at: 1))
                guard !allowedRepeats.contains(word.lowercased()) else { continue }
                ns.replaceCharacters(in: match.range, with: word)
            }
            next = ns as String
        }
        return next.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Words after which a removed filler phrase leaves no comma behind.
    private static let connectives: Set<String> = [
        "so", "and", "but", "because", "that", "to", "of", "at", "in", "on", "for", "with", "or", "if", "then",
        "which", "is", "was", "are", "were", "just",
    ]

    /// `**`, `__`, backticks and heading markers. List markers stay: they
    /// read fine as plain text.
    static func stripMarkdownResidue(_ text: String) -> String {
        var next = text.replacingOccurrences(of: "**", with: "")
        next = next.replacingOccurrences(of: "__", with: "")
        next = next.replacingOccurrences(of: "`", with: "")
        next = next.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        return next
    }

    static func normaliseWhitespace(_ text: String) -> String {
        var next = text.replacingOccurrences(of: "\r\n", with: "\n")
        next = next.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        next = next.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        next = next.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        next = next.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return next.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Doubled and mis-spaced punctuation. Runs only outside emails and URLs.
    static func normalisePunctuation(_ text: String) -> String {
        var next = text
        let rules: [(String, String)] = [
            (#"[ \t]+([,.;:!?])"#, "$1"),
            (#",{2,}"#, ","),
            (#",\s*\."#, "."),
            (#"\.\s*,"#, "."),
            (#"\?\."#, "?"),
            (#"!\."#, "!"),
            (#"!{2,}"#, "!"),
            (#"\?{2,}"#, "?"),
            (#"(?<!\.)\.\.(?!\.)"#, "."),
            (#"(?m)^\s*,\s*"#, ""),
            (#", ,"#, ","),
            // One space after sentence punctuation when a new sentence follows
            // ("etc.Next"). Lowercase continuations are left alone so bare
            // filenames and domains ("report.pdf", "voxbox.app") survive.
            (#"(?<=[A-Za-z]{2})([.!?])(?=[A-Z])"#, "$1 "),
            (#"(?<=[A-Za-z]{2})([,;:])(?=[A-Za-z])"#, "$1 "),
        ]
        for (pattern, replacement) in rules {
            next = next.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return next
    }

    static func fixTrailingEllipsis(_ text: String, reference input: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.hasSuffix("…"), !trimmedInput.hasSuffix("...") else { return text }
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.hasSuffix("...") {
            next = String(next.dropLast(3)) + "."
        } else if next.hasSuffix("…") {
            next = String(next.dropLast()) + "."
        }
        return next
    }

    /// First letter of the text and of each sentence, when the word is all
    /// lowercase (leaves `iPhone`, emails, URLs alone).
    static func capitaliseSentenceStarts(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(^|[.!?]\s+|\n\n|\n(?:[-*•] ?|\d+\. ))([a-z])"#) else {
            return text
        }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            guard !isInsideProtectedSpan(letterRange, in: ns as String) else { continue }
            // Only when the whole word is lowercase.
            let wordEnd = wordEndIndex(in: ns as String, from: letterRange.location)
            let word = ns.substring(with: NSRange(location: letterRange.location, length: wordEnd - letterRange.location))
            guard word == word.lowercased() else { continue }
            ns.replaceCharacters(in: letterRange, with: ns.substring(with: letterRange).uppercased())
        }
        return ns as String
    }

    /// Undo ALL-CAPS words and Title Case runs (three or more consecutive
    /// capitalised words) that the speaker dictated in lowercase. Single
    /// capitalised words are left alone: they are usually names the engine
    /// lowercased.
    static func repairCasing(_ text: String, reference input: String) -> String {
        let inputForms = Dictionary(
            input.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
                .map { (String($0).lowercased(), String($0)) },
            uniquingKeysWith: { first, _ in first })

        var lines = text.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            var words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // ALL CAPS.
            for (index, word) in words.enumerated() {
                let core = letters(in: word)
                guard core.count >= 2, core == core.uppercased(), core != core.lowercased() else { continue }
                if let original = inputForms[core.lowercased()], original == original.lowercased() {
                    words[index] = word.replacingOccurrences(of: core, with: original)
                }
            }
            // Title Case runs.
            var runStart: Int?
            func flush(_ end: Int) {
                guard let start = runStart, end - start >= 3 else { runStart = nil; return }
                for index in start..<end {
                    let core = letters(in: words[index])
                    if let original = inputForms[core.lowercased()], original == original.lowercased(),
                        core != "I"
                    {
                        words[index] = words[index].replacingOccurrences(of: core, with: original)
                    }
                }
                runStart = nil
            }
            for (index, word) in words.enumerated() {
                let core = letters(in: word)
                let isCapitalised = core.count >= 2 && core.first!.isUppercase
                    && core.dropFirst().allSatisfy { $0.isLowercase }
                let sentenceStart = index == 0 || words[index - 1].last.map { ".!?".contains($0) } == true
                if isCapitalised, !sentenceStart {
                    if runStart == nil { runStart = index }
                } else if isCapitalised, sentenceStart, runStart == nil {
                    // A capitalised sentence start may begin a title-case run.
                    runStart = index
                } else {
                    flush(index)
                }
            }
            flush(words.count)
            lines[lineIndex] = words.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Preamble and refusal

    /// Labels and instruction fragments the model sometimes wraps around the
    /// transcript despite being told not to. Case-insensitive, up to three
    /// passes, plus a leaked `REMEMBER:` trailer and wrapping quotes.
    static func stripModelPreamble(_ text: String, promptSet: CleanupPromptSet = .compiled) -> String {
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let before = next
            next = stripLeakedInstructions(next, promptSet: promptSet)
            next = stripLeadingWrapperLine(next)
            next = stripTrailer(next)
            next = stripWrappingQuotes(next)
            if next == before { break }
        }
        return next
    }

    static func looksLikeRefusal(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let prefixes = [
            "sorry, i can't", "sorry, i cannot", "i'm sorry, but", "i can't help", "i cannot help",
            "i'm unable to", "i am unable to", "as an ai", "i can't assist", "i cannot assist",
        ]
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    private static func stripLeakedInstructions(_ text: String, promptSet: CleanupPromptSet) -> String {
        var next = text
        let leaks = [promptSet.markdown, promptSet.outputOnly, promptSet.style, promptSet.role]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for leak in leaks where next.lowercased().hasPrefix(leak.lowercased()) {
            next = String(next.dropFirst(leak.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return next
    }

    private static let wrapperPrefixes = [
        "here's the cleaned-up transcript:", "here is the cleaned-up transcript:",
        "here's the cleaned transcript:", "here is the cleaned transcript:",
        "here's the cleaned-up text:", "here is the cleaned-up text:",
        "here's the clean transcript:", "here is the clean transcript:",
        "here's the cleaned text:", "here is the cleaned text:",
        "here's the clean text:", "here is the clean text:",
        "here's the tidied text:", "here is the tidied text:",
        "here's the tidied dictation:", "here is the tidied dictation:",
        "here's the cleaned dictation:", "here is the cleaned dictation:",
        "here's the transcript:", "here is the transcript:",
        "here's the text:", "here is the text:",
        "cleaned-up transcript:", "cleaned transcript:", "cleaned-up text:", "cleaned text:",
        "clean text:", "tidied text:", "tidied dictation:", "cleaned dictation:",
        "cleaned:", "output:", "transcript:", "dictation:", "result:",
    ]

    private static let courtesyOpeners = [
        "of course! ", "of course, ", "certainly! ", "certainly, ", "sure! ", "sure, ", "sure. ", "sure ",
        "okay, ", "okay. ", "ok, ", "ok. ",
    ]

    /// Drops one leading conversational wrapper line. Real dictation is kept.
    static func stripLeadingWrapperLine(_ text: String) -> String {
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
        guard let afterWrapper = droppingWrapperPrefix(from: firstLine) else { return trimmed }
        let pieces = [afterWrapper, remainder]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "\n")
    }

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
        guard let prefix = wrapperPrefixes.first(where: { search.hasPrefix($0) }) else { return nil }
        dropCount += prefix.count
        var rest = String(candidate.dropFirst(dropCount)).trimmingCharacters(in: .whitespaces)
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

    /// A leaked `REMEMBER: …` suffix, or a closing remark on its own line.
    private static func stripTrailer(_ text: String) -> String {
        guard let range = text.range(of: #"(?im)^\s*remember:.*\z"#, options: .regularExpression) else {
            return text
        }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let wrapped =
            (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("“") && text.hasSuffix("”"))
        guard wrapped else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Emails and URLs are swapped for private-use placeholders while the
    /// transform runs, then restored. Masking (rather than splitting the text
    /// into segments) keeps line-start anchors and lookarounds honest: a
    /// comma right after an email is still "after a word", not "at a line
    /// start".
    private static func applyOutsideProtectedSpans(_ text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        let protectedRanges = CleanupGuardrail.protectedRanges(in: text).sorted { $0.location < $1.location }
        guard !protectedRanges.isEmpty else { return transform(text) }
        var spans: [String] = []
        var masked = ""
        var cursor = 0
        for range in protectedRanges where range.location >= cursor {
            masked += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            masked += placeholder(spans.count)
            spans.append(ns.substring(with: range))
            cursor = range.location + range.length
        }
        masked += ns.substring(from: cursor)
        var result = transform(masked)
        for (index, span) in spans.enumerated().reversed() {
            result = result.replacingOccurrences(of: placeholder(index), with: span)
        }
        return result
    }

    private static func placeholder(_ index: Int) -> String {
        "\u{E000}\(index)\u{E001}"
    }

    private static func isInsideProtectedSpan(_ range: NSRange, in text: String) -> Bool {
        CleanupGuardrail.protectedRanges(in: text).contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func wordEndIndex(in text: String, from start: Int) -> Int {
        let ns = text as NSString
        var index = start
        while index < ns.length {
            let scalar = ns.character(at: index)
            guard let unicode = Unicode.Scalar(scalar), CharacterSet.letters.contains(unicode) else { break }
            index += 1
        }
        return index
    }

    private static func letters(in word: String) -> String {
        String(word.filter { $0.isLetter })
    }

    static func uppercaseRatio(_ text: String) -> Double {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter(\.isUppercase).count) / Double(letters.count)
    }
}
