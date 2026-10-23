import Foundation
import NaturalLanguage

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
        let tokenEdges = CharacterSet(charactersIn: "\"'“”‘’()[]{},;.!?")
        let tokens = Set(input.split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: tokenEdges.union(CharacterSet(charactersIn: "`")))
        }.filter { $0.range(of: #"\S[:_/.]\S"#, options: .regularExpression) != nil })
        let identifierEdges = tokenEdges.union(CharacterSet(charactersIn: "`"))
        var saved: [String] = []
        var text = output
        if let regex = try? NSRegularExpression(pattern: #"\S+"#) {
            let ns = NSMutableString(string: text)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let token = ns.substring(with: match.range)
                guard tokens.contains(token.trimmingCharacters(in: identifierEdges)) else { continue }
                ns.replaceCharacters(in: match.range, with: "\u{E002}\(saved.count)\u{E003}")
                saved.append(markdownAllowed ? token : token.replacingOccurrences(of: "`", with: ""))
            }
            text = ns as String
        }
        text = restoreDictatedForms(text, reference: input)
        text = restoreClippedScaffolding(text, reference: input)
        if !markdownAllowed {
            text = stripMarkdownResidue(text)
        }
        text = normaliseWhitespace(text)
        if spokenFillers { text = dropUnbracketedFillers(text, reference: input) }
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
        for (index, token) in saved.enumerated() {
            text = text.replacingOccurrences(of: "\u{E002}\(index)\u{E003}", with: token)
        }
        let anomaly = uppercaseRatio(text) > max(0.30, 2 * uppercaseRatio(input) + 0.05)
        return TidyResult(text: text, casingAnomaly: anomaly)
    }

    // MARK: - Dictated forms

    /// Undoes format changes the speaker never asked for instead of vetoing
    /// the pass over them: "17:00" for a dictated "5pm" (Polish does this a
    /// few times a run), "Fri" for a dictated "Friday", and digits in
    /// another script ("version ๔").
    static func restoreDictatedForms(_ text: String, reference: String) -> String {
        var next = restoreCalendarNames(asciiDigits(text, reference: reference), reference: reference)
        next = restoreSmallNumberWords(next, reference: reference)
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(\d{1,2})(?::(\d{2}))?\s?([ap])\.?m\b\.?"#) else { return next }
        let ns = reference as NSString
        for match in regex.matches(in: reference, range: NSRange(location: 0, length: ns.length)) {
            guard let hour = Int(ns.substring(with: match.range(at: 1))), (1...12).contains(hour) else { continue }
            let minutes = match.range(at: 2).location == NSNotFound ? "00" : ns.substring(with: match.range(at: 2))
            let pm = ns.substring(with: match.range(at: 3)).lowercased() == "p"
            let hour24 = hour % 12 + (pm ? 12 : 0)
            let dictated = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // Restore spacing only when this exact compact time was dictated.
            // Do not choose a spelling when the reference itself uses both.
            if !dictated.contains(" "), !dictated.contains(".") {
                let spaced = "\(hour)" + (minutes == "00" && match.range(at: 2).location == NSNotFound
                    ? "" : ":\(minutes)") + " " + (pm ? "pm" : "am")
                if reference.range(of: spaced, options: .caseInsensitive) == nil {
                    next = applyOutsideProtectedSpans(next) { segment in
                        segment.replacingOccurrences(
                            of: #"(?i)(?<![\w:/])"# + NSRegularExpression.escapedPattern(for: spaced) + #"(?![\w:])"#,
                            with: NSRegularExpression.escapedTemplate(for: dictated), options: .regularExpression)
                    }
                }
            }
            for form in Set(["\(hour24):\(minutes)", String(format: "%02d:%@", hour24, minutes)]) where !reference.contains(form) {
                next = next.replacingOccurrences(
                    of: #"(?<![\d:])"# + NSRegularExpression.escapedPattern(for: form) + #"(?![\d:])(?:\s?(?:hrs|hours|h)\b)?"#,
                    with: NSRegularExpression.escapedTemplate(for: dictated), options: .regularExpression)
            }
        }
        return next
    }

    /// Polish writes "Fri at 2pm" for "Friday at 2pm" (most runs when the
    /// language is auto). Expand an abbreviation back to the name the
    /// speaker said, unless they said the short form too ("we sat down").
    private static func restoreCalendarNames(_ text: String, reference: String) -> String {
        var next = text
        for (name, abbreviations) in calendarAbbreviations
        where reference.range(of: #"\b\#(name)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            for abbreviation in abbreviations
            where reference.range(of: #"\b\#(abbreviation)\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
                // "Fri. at 2pm" loses the dot; "by Mon." keeps it as the full stop.
                next = next.replacingOccurrences(
                    of: #"(?i)\b\#(abbreviation)\.(?=\s+[a-z0-9])"#, with: name, options: .regularExpression)
                next = next.replacingOccurrences(
                    of: #"(?i)\b\#(abbreviation)\b"#, with: name, options: .regularExpression)
            }
        }
        return next
    }

    /// Polish writes "3 things" for "three things". The number pass leaves
    /// a lone small number as a word (only "three dollars" or "three
    /// percent" become digits), so match it: restore the word wherever the
    /// speaker said it before the same next word.
    private static func restoreSmallNumberWords(_ text: String, reference: String) -> String {
        var next = text
        for (digit, word) in smallNumberWords {
            let pattern = #"(?i)\b\#(word)\s+([a-z]+)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = reference as NSString
            for match in regex.matches(in: reference, range: NSRange(location: 0, length: ns.length)) {
                let following = ns.substring(with: match.range(at: 1))
                // "two to three weeks" is a range, and ranges stay digits.
                let before = ns.substring(to: match.range.location)
                let inRange = ["to", "or"].contains(following.lowercased())
                    || before.range(of: #"(?i)\b[a-z]+\s+(?:to|or)\s+$"#, options: .regularExpression)
                        .map { SpokenNumbers.isNumberWord(before[$0].split(separator: " ")[0].lowercased()) } == true
                guard !inRange, !SpokenNumbers.isNumberWord(following.lowercased()),
                    reference.range(of: #"\b\#(digit)\s+\#(following)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
                else { continue }
                next = next.replacingOccurrences(
                    of: #"(?<![\d.,$£€])\b\#(digit)\s+(\#(following))\b"#, with: "\(word) $1",
                    options: [.regularExpression, .caseInsensitive])
            }
        }
        return next
    }

    private static let smallNumberWords = [
        ("1", "one"), ("2", "two"), ("3", "three"), ("4", "four"), ("5", "five"), ("6", "six"), ("7", "seven"),
        ("8", "eight"), ("9", "nine"),
    ]

    private static let calendarAbbreviations: [(String, [String])] = [
        ("Monday", ["mon"]), ("Tuesday", ["tues", "tue"]), ("Wednesday", ["wed"]),
        ("Thursday", ["thurs", "thur", "thu"]), ("Friday", ["fri"]), ("Saturday", ["sat"]),
        ("Sunday", ["sun"]), ("January", ["jan"]), ("February", ["feb"]), ("March", ["mar"]),
        ("April", ["apr"]), ("June", ["jun"]), ("July", ["jul"]), ("August", ["aug"]),
        ("September", ["sept", "sep"]), ("October", ["oct"]), ("November", ["nov"]),
        ("December", ["dec"]),
    ]

    /// Decimal digits from other scripts become 0–9, unless the speaker's
    /// own text used them.
    private static func asciiDigits(_ text: String, reference: String) -> String {
        func foreign(_ scalar: Unicode.Scalar) -> Bool {
            !scalar.isASCII && scalar.properties.numericType == .decimal
        }
        guard text.unicodeScalars.contains(where: foreign), !reference.unicodeScalars.contains(where: foreign) else {
            return text
        }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if foreign(scalar), let value = scalar.properties.numericValue, let ascii = Unicode.Scalar(48 + Int(value)) {
                scalars.append(ascii)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: - Spoken scaffolding

    /// Polish only: drops what exists because the text was spoken, not
    /// written. A discourse opener ("So hi Jack", "Okay so can you…") and
    /// self-narration before a comma ("Also I meant to say, the slide…" →
    /// "Also, the slide…"). The comma is the guard: "I meant to say yes",
    /// "the thing is broken" and "I wanted to say thank you" stay.
    static func dropSpokenScaffolding(_ text: String) -> String {
        var next = text
        for _ in 0..<3 {
            let before = next
            next = dropOpener(next)
            next = dropNarration(next)
            if next == before { break }
        }
        return next
    }

    private static func dropOpener(_ text: String) -> String {
        let patterns = [
            #"^(?:okay|ok|right|alright|all right),?\s+so\b,?\s+(?!far\b|much\b|many\b|that\b)"#,
            #"^so,\s+"#,
            #"^so\s+(?=(?:hi|hey|hello|g'day)\b)"#,
            #"^anyway,?\s+(?!it's done\b)"#,
        ]
        // A raw take may still open with a hesitation: "Um so hi Jack".
        let hesitation = #"(?:(?:um+|uh+|erm*|ah+)[,.]?\s+)*"#
        for pattern in patterns {
            let anchored = "^" + hesitation + pattern.dropFirst()
            guard let range = text.range(of: "(?i)" + anchored, options: .regularExpression) else { continue }
            return capitaliseFirst(String(text[range.upperBound...]))
        }
        return text
    }

    private static let narration =
        #"(?:i (?:just )?(?:meant|wanted|was going) to (?:say|mention)|what i'?m trying to say is|what i am trying to say is|i guess what i'?m saying is|the thing is)"#

    private static func dropNarration(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(^|[.!?]\s+|\b(?:also|and|but|oh)\b,?\s+)"# + narration + #",\s+(?=\S)"#)
        else { return text }
        let ns = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let lead = ns.substring(with: match.range(at: 1))
            let trimmed = lead.trimmingCharacters(in: .whitespaces)
            let opensSentence = trimmed.isEmpty || ".!?".contains(trimmed.last!)
            // "Also I meant to say, the" → "Also, the"; "…today. I meant to say, the" → "…today. The".
            let replacement = opensSentence ? lead : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + ", "
            ns.replaceCharacters(in: match.range, with: replacement)
            if opensSentence {
                let at = match.range.location + (replacement as NSString).length
                if at < ns.length {
                    ns.replaceCharacters(in: NSRange(location: at, length: 1), with: ns.substring(with: NSRange(location: at, length: 1)).uppercased())
                }
            }
        }
        return ns as String
    }

    private static func capitaliseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Questions

    /// The model sometimes ends a dictated question with a full stop ("Can
    /// you move the stand-up to the bigger room."). Where the three words
    /// before a "?" in the dictation end a sentence with "." in the output,
    /// put the "?" back.
    static func restoreQuestionMarks(_ output: String, reference: String) -> String {
        guard reference.contains("?"),
            let regex = try? NSRegularExpression(pattern: #"((?:[A-Za-z0-9'’]+[ ,]+){2}[A-Za-z0-9'’]+)\?"#)
        else { return output }
        let ref = reference as NSString
        var out = output
        for match in regex.matches(in: reference, range: NSRange(location: 0, length: ref.length)) {
            let tail = ref.substring(with: match.range(at: 1))
            let words = tail.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            guard words.count == 3 else { continue }
            let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[ ,]+"#)
            out = out.replacingOccurrences(
                of: "(" + pattern + #")\.(?=\s|$)"#, with: "$1?", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Mark only sentence-initial direct questions; quoted text and token
    /// punctuation cannot supply a sentence boundary.
    static func markDirectQuestions(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        let quotes = (try? NSRegularExpression(
            pattern: #""[^"]*"|“[^”]*”|(?<!\w)'[^'\r\n]*'(?!\w)|‘[^’\r\n]*’"#))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) ?? []
        var protected = quotes + CleanupGuardrail.protectedRanges(in: text).map { range in
            var range = range
            while range.length > 0, ".!?".utf16.contains(ns.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            return range
        }
        for pattern in [
            #"\b(?:[A-Za-z]\.){2,}|\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\."#,
            #"\b[\w-]+[:_/@][\w:/.@-]*[\w/]\b|\b[\w-]+(?:\.[\w-]+)+\b"#,
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                protected += regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            }
        }
        let auxiliary = "(?:can|could|would|will|should|do|does|did|is|are|was|were|have|has)"
        let subject = "(?:you|we|i|they|he|she|it|there|someone|anyone|this|that|these|those|"
            + "(?:the|a|an|my|your|our|their|his|her|its)\\s+[\\p{L}]+)"
        let wh = "(?:what|why|how|when|where|who|which)"
        let opener = #"(?:\s*(?:(?i:(?:so\s+)?(?:hey|hi|hello))\s+[\p{L}]+,?\s+|(?i:okay|ok)(?:,?\s+so)?,?\s+|(?i:also),\s+|(?i:hey|so|anyway|and),?\s+|\p{Lu}\p{Ll}+,\s+))?"#
            + #"(?:(?i:i (?:meant|was going) to say),\s+)?"#
        let question = "(?i:" + auxiliary + #"\s+"# + subject + #"\b|"#
            + wh + #"(?:\s+"# + auxiliary + #"\b|['’](?:s|re)\b)|how\s+(?:many|much|long|often)\b|"#
            + #"who\s+(?:else\s+|in\s+(?:their|there)\s+right\s+mind\s+)"# + auxiliary + #"\b)"#
        guard let regex = try? NSRegularExpression(pattern: "^" + opener + question) else { return text }
        var start = 0
        let length = ns.length
        for index in 0...length {
            let atEnd = index == length
            let char: unichar = atEnd ? 46 : ns.character(at: index)
            if quotes.contains(where: { NSMaxRange($0) - 1 == index }),
                index > 0, ".!?".utf16.contains(ns.character(at: index - 1))
            {
                start = index + 1
                continue
            }
            guard [10, 13, 33, 46, 63].contains(char) else { continue }
            if protected.contains(where: { NSLocationInRange(index, $0) }) { continue }
            if char == 46, index + 1 < ns.length,
                let scalar = Unicode.Scalar(ns.character(at: index + 1)),
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                continue
            }
            if char == 46, !atEnd,
                (index > 0 && ns.character(at: index - 1) == 46
                    || index + 1 < length && ns.character(at: index + 1) == 46)
            {
                start = index + 1
                continue
            }
            if char == 46 {
                let sentence = ns.substring(with: NSRange(location: start, length: index - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let last = sentence.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
                let dangling: Set<String> = [
                    "a", "an", "the", "and", "or", "but", "because", "if", "that", "which",
                    "to", "of", "for", "with", "from", "at", "in", "on", "is", "are", "was", "were",
                    "can", "could", "would", "should", "will", "have", "has", "had",
                    "without", "like", "given", "until", "before", "after",
                ]
                if !sentence.contains("…"), !dangling.contains(last),
                    !atEnd || (sentence.last?.isLetter == true || sentence.last?.isNumber == true),
                    regex.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) != nil
                {
                    ns.replaceCharacters(in: NSRange(location: index, length: atEnd ? 0 : 1), with: "?")
                }
            }
            start = index + 1
        }
        return ns as String
    }

    // MARK: - Dictated lists

    private static let ordinals: [[String]] = [
        ["first", "firstly", "first of all", "number one"],
        ["second", "secondly", "number two"],
        ["third", "thirdly", "number three"],
        ["fourth", "fourthly", "number four"],
        ["fifth", "fifthly", "number five"],
        ["sixth", "number six"],
    ]

    /// "Hey team, three things. First, the build is up. Second, …" → a lead
    /// line and a numbered list. Only sentences that open with spoken
    /// ordinals in order (first, second, …; "finally"/"lastly" may close),
    /// at least two of them. An ordinal may follow a connective ("And
    /// third,") or sit in "the second thing is"; a filler straight after it
    /// ("Third, basically we…") goes with it. Sentences between ordinals stay with their
    /// item; anything after the last item's sentence becomes a paragraph
    /// after the list. The model is not asked to do this: in the eval it
    /// never produced a list, and when it did (v2) it listed prose.
    static func formatSpokenLists(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map(formatSpokenList(inParagraph:)).joined(separator: "\n\n")
    }

    private static func formatSpokenList(inParagraph paragraph: String) -> String {
        guard !paragraph.contains("\n") else { return paragraph }
        let sentences = paragraph.components(separatedBy: " ").reduce(into: [String]()) { out, word in
            if let last = out.last, let end = last.last, !".!?".contains(end) {
                out[out.count - 1] = last + " " + word
            } else {
                out.append(word)
            }
        }
        guard let start = sentences.indices.first(where: { listOpener(sentences[$0], index: 0) != nil }) else {
            return paragraph
        }
        var items: [String] = []
        var itemStarts: [Int] = []
        var index = start
        while index < sentences.count {
            if let opener = listOpener(sentences[index], index: items.count) {
                var body = String(sentences[index].dropFirst(opener.length))
                body = body.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
                guard let first = body.first else { return paragraph }
                items.append(first.uppercased() + body.dropFirst())
                itemStarts.append(index)
                if opener.closes {
                    index += 1
                    break
                }
            } else if !items.isEmpty, index < sentences.count, itemStarts.count >= 1,
                sentences[(index + 1)...].contains(where: { listOpener($0, index: items.count) != nil })
            {
                items[items.count - 1] += " " + sentences[index]
            } else {
                break
            }
            index += 1
        }
        guard items.count >= 2 else { return paragraph }
        var lead = sentences[..<start].joined(separator: " ")
        if lead.hasSuffix(".") { lead = String(lead.dropLast()) + ":" }
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let tail = sentences[index...].joined(separator: " ")
        return [lead, list, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let listConnectives = ["and then ", "and ", "then ", "also ", "plus "]
    private static let listClosers = ["finally", "lastly", "last of all", "last but not least"]
    private static let itemFillers = ["basically", "you know", "um", "uh"]

    /// The spoken ordinal that opens `sentence` as list item `index`, and how
    /// many characters it spans (including a trailing filler). Nil when the
    /// sentence is not that item.
    private static func listOpener(_ sentence: String, index: Int) -> (length: Int, closes: Bool)? {
        let lowered = sentence.lowercased()
        var offset = 0
        if let connective = listConnectives.first(where: { lowered.hasPrefix($0) }) {
            offset = connective.count
        }
        let rest = lowered.dropFirst(offset)
        var words = index < ordinals.count ? ordinals[index] : []
        if index < ordinals.count {
            let ordinal = ordinals[index][0]
            words += ["the \(ordinal) thing is", "the \(ordinal) one is", "the \(ordinal) point is"]
        }
        let closers = index >= 2 ? listClosers : []
        func boundary(_ word: String) -> Bool { rest.hasPrefix(word + ",") || rest.hasPrefix(word + " ") }
        guard let word = (words + closers).first(where: boundary) else { return nil }
        var length = offset + word.count
        var tail = lowered.dropFirst(length).drop { $0 == "," || $0 == " " }
        if let filler = itemFillers.first(where: { tail.hasPrefix($0 + ",") || tail.hasPrefix($0 + " ") }) {
            tail = tail.dropFirst(filler.count).drop { $0 == "," || $0 == " " }
            length = lowered.count - tail.count
        }
        return (length, closers.contains(word))
    }

    /// Turns the engine's pause-led sentence breaks into plain word gaps so
    /// the model has to decide where sentences end: "…should be. Based on…"
    /// → "…should be based on…". Questions, exclamations, paragraph breaks,
    /// numbers and abbreviations are left alone; "I" and capitalised names
    /// keep their capital.
    static func flattenSentenceBreaks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[a-z]{2})\. ([A-Z])([a-z]*)(?= )"#) else { return text }
        let ns = NSMutableString(string: text)
        let lowercaseWords = Set(
            text.split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .map(String.init)
                .filter { $0.first?.isLowercase == true })
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let first = ns.substring(with: match.range(at: 1))
            let rest = ns.substring(with: match.range(at: 2))
            let word = first + rest
            let lowered = first.lowercased() + rest
            // Lowercase only words that are clearly not names: common
            // sentence openers, words the speaker also used in lowercase, or
            // words that read as anything but a noun once the break is gone
            // ("New paragraph. Starts here."). "I", "Sam", "Okta" keep their capital.
            let common = Self.commonOpeners.contains(lowered) || lowercaseWords.contains(lowered)
                || !readsAsNoun(lowered, after: match.range.location, in: ns)
            let replacement = word == "I" || rest.isEmpty || !common ? " \(word)" : " \(lowered)"
            ns.replaceCharacters(in: match.range, with: replacement)
        }
        return ns as String
    }

    /// Tags `word` inside the lowercased, break-free run of words around it.
    /// Unknown words (most names) tag as nouns.
    private static func readsAsNoun(_ word: String, after location: Int, in text: NSString) -> Bool {
        guard let tag = lexicalClass(of: word, after: location, in: text) else { return true }
        return tag == .noun || tag == .otherWord
    }

    private static func lexicalClass(of word: String, after location: Int, in text: NSString) -> NLTag? {
        let before = text.substring(to: location).split(separator: " ").suffix(4).joined(separator: " ")
        // `location` is the full stop: skip it and the word itself.
        let after = text.substring(from: location).split(separator: " ").dropFirst(2).prefix(4).joined(separator: " ")
        let prefix = before.replacingOccurrences(of: ".", with: "").lowercased() + " "
        let phrase = prefix + word + " " + after.lowercased()
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = phrase
        let start = phrase.index(phrase.startIndex, offsetBy: prefix.count)
        return tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0
    }

    private static let commonOpeners: Set<String> = [
        "and", "but", "so", "because", "which", "that", "then", "the", "a", "an", "this", "these", "those",
        "it", "there", "they", "we", "he", "she", "you", "my", "our", "your", "if", "when", "where", "while",
        "also", "just", "or", "not", "to", "for", "with", "from", "on", "in", "at", "as", "of", "by", "about",
        "like", "what", "how", "why", "who", "is", "was", "are", "were", "can", "could", "would", "should",
        "will", "maybe", "actually", "even", "still", "really", "especially", "based", "otherwise", "although",
        "though", "unless", "until", "since", "after", "before", "plus", "instead", "probably", "all", "some",
    ]

    /// A speech engine ends a sentence wherever the speaker paused, so a
    /// dictation is full of fragments that begin with a conjunction: "…in
    /// faster sections. And the pauses…". Fold those back onto the previous
    /// sentence with a comma. Only after a full stop that follows a letter
    /// (never "?", "!", a number or an abbreviation), and never at the start
    /// of a paragraph.
    static func joinPauseFragments(_ text: String) -> String {
        // Never before a list word: "…everyone. And third, we need…" is the
        // next item, not a fragment.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<=[a-z]{2})\. (And|But|Because|Which|Or) (?=[a-z])(?!(?:first|second|third|fourth|fifth|finally|lastly)\b)"#)
        else {
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

    /// The model drops a filler's commas or the filler alone: "so you know
    /// have a play" or "so, have a play" for "so, you know, have a play".
    /// Without the commas "so you know where it is" means something, so
    /// this only acts where the speaker set the filler off and the words
    /// either side survive.
    static func dropUnbracketedFillers(_ text: String, reference: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b([\w']+),\s+you know,\s+([\w']+)\b"#) else { return text }
        let ns = reference as NSString
        var next = text
        for match in regex.matches(in: reference, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1))
            let before = NSRegularExpression.escapedPattern(for: word)
            let after = NSRegularExpression.escapedPattern(for: ns.substring(with: match.range(at: 2)))
            next = next.replacingOccurrences(
                of: #"(?i)\b(\#(before)) you know (\#(after))\b"#, with: "$1 $2", options: .regularExpression)
            if connectives.contains(word.lowercased()) {
                next = next.replacingOccurrences(
                    of: #"(?i)\b(\#(before)), (\#(after))\b"#, with: "$1 $2", options: .regularExpression)
            }
        }
        return next
    }

    /// Light cut "Also I meant to say, the second slide" to "Also I meant
    /// the second slide", which reads as a different sentence. Light keeps
    /// scaffolding (Polish drops it before the model), so put it back.
    static func restoreClippedScaffolding(_ text: String, reference: String) -> String {
        let said = #"(?i)\bmeant to say\b"#
        let count = { (string: String, pattern: String) in
            (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
                in: string, range: NSRange(location: 0, length: (string as NSString).length)) ?? 0
        }
        guard count(reference, said) > count(text, said),
            let clipped = text.range(of: #"(?i)\bmeant,?\s+(?!to\b)"#, options: .regularExpression)
        else { return text }
        // The first one only: "what I meant was" later on is the speaker's.
        return text.replacingCharacters(in: clipped, with: text[clipped].prefix(5) + " to say, ")
    }

    /// The deterministic backstop behind Light and Polish: um/uh-family
    /// fillers (via Auto Edit's rules), filler phrases set off by commas, and
    /// a word or contraction repeated back to back ("I'm, I'm gonna").
    /// Context-dependent fillers ("like", mid-clause "basically") are left to
    /// the model.
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
        // "basically" opening a clause is filler ("And third, basically we
        // need…", "Basically, it's broken"); mid-clause it can mean "almost"
        // ("it's basically done") and stays.
        next = next.replacingOccurrences(
            of: #"(?im)(^|[.!?]\s+|\b(?:and|but|so|first|second|third|fourth|fifth|firstly|secondly|thirdly|finally|lastly),?\s+)basically,?\s+"#,
            with: "$1", options: .regularExpression)
        // Immediate repeats, optionally separated by a comma.
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b([A-Za-z]+(?:'[A-Za-z]+)?)(?:,\s*|\s+)\1\b"#) {
            let ns = NSMutableString(string: next)
            for match in regex.matches(in: next, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: match.range(at: 1))
                guard !allowedRepeats.contains(word.lowercased()),
                    !SpokenNumbers.isNumberWord(word.lowercased()), word.lowercased() != "oh"
                else { continue }
                if !ns.substring(with: match.range).contains(","), word != "I",
                    word.first?.isUppercase == true
                {
                    let prefix = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                    let startsSentence = prefix.isEmpty || prefix.last.map({ ".!?\r\n".contains($0) }) == true
                    if !startsSentence || !clauseOpeners.contains(word.lowercased()) { continue }
                }
                // "I like it, it looks…" is two clauses, not a restart.
                if ns.substring(with: match.range).contains(","),
                    !clauseOpeners.contains(word.lowercased())
                {
                    continue
                }
                ns.replaceCharacters(in: match.range, with: word)
            }
            next = ns as String
        }
        return next.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Words that cannot end a clause, so "we, we" or "the, the" across a
    /// comma is a restart. Anything else ("it, it", "you, you") may be the
    /// end of one clause and the start of the next. "in" and "on" stay:
    /// "following up on, on the thing" is far more common in dictation than
    /// "send it in, in the morning".
    private static let clauseOpeners: Set<String> = [
        "i", "we", "they", "he", "she", "i'm", "we're", "they're", "it's", "the", "a", "an", "my", "our", "your",
        "their", "to", "of", "in", "on", "at", "for", "with", "and", "but", "or", "so", "was", "were", "will",
        "would", "can", "could", "should", "have",
    ]

    /// Words after which a removed filler phrase leaves no comma behind.
    private static let connectives: Set<String> = [
        "so", "and", "but", "because", "that", "to", "of", "at", "in", "on", "for", "with", "or", "if", "then",
        "which", "is", "was", "are", "were", "just",
    ]

    /// `**`, `__`, backticks and heading markers. List markers stay: they
    /// read fine as plain text.
    static func stripMarkdownResidue(_ text: String) -> String {
        var next = dropTrailingStubList(text)
        next = next.replacingOccurrences(of: "**", with: "")
        next = next.replacingOccurrences(of: "__", with: "")
        next = next.replacingOccurrences(of: "`", with: "")
        next = next.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        return next
    }

    /// A small model sometimes ends a long take with a list of keywords it
    /// was never asked for ("…on Friday.\n\n1. Rooms\n2. Lunch"). Two or
    /// more items of at most three words each, after the last blank line,
    /// are never dictation.
    static func dropTrailingStubList(_ text: String) -> String {
        guard let split = text.range(of: "\n\n", options: .backwards) else { return text }
        let block = text[split.upperBound...].components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard block.count >= 2 else { return text }
        let stubs = block.allSatisfy { line in
            guard let marker = line.range(of: #"^\s*(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) else { return false }
            return line[marker.upperBound...].split(separator: " ").count <= 3
        }
        guard stubs else { return text }
        return String(text[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
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
            (#"(?<=[A-Za-z]{2})([,;])(?=[A-Za-z])"#, "$1 "),
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
    /// `reference` is the dictation. A strip the dictation itself would
    /// trigger is the speaker's text, not a leak: a take that starts
    /// "Remember: the board pack…" or "Result: we shipped" keeps that line.
    static func stripModelPreamble(
        _ text: String, promptSet: CleanupPromptSet = .compiled, reference: String? = nil
    ) -> String {
        let dictated = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepsWrapper = dictated.map { stripLeadingWrapperLine($0) != $0 } ?? false
        let keepsTrailer = dictated.map { stripTrailer($0) != $0 } ?? false
        let keepsQuotes = dictated.map { stripWrappingQuotes($0) != $0 } ?? false
        let stripsTags = !(dictated?.lowercased().contains("<dictation>") ?? false)
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let before = next
            // Instructions first: the v3 role text itself names the tags.
            next = stripLeakedInstructions(next, promptSet: promptSet)
            if stripsTags {
                // The v3 wrap tags, echoed back.
                next = next.replacingOccurrences(of: #"(?i)</?dictation>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !keepsWrapper { next = stripLeadingWrapperLine(next) }
            if !keepsTrailer { next = stripTrailer(next) }
            if !keepsQuotes { next = stripWrappingQuotes(next) }
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
