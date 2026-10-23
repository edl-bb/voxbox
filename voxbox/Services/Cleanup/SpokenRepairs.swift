import Foundation

/// Deterministic self-corrections for Light and Polish, before model cleanup.
/// Keeps the second copy of an immediate restart, resolves explicit corrections
/// only with a nearby anchor or matching kinds, and honours “scratch that”.
///
/// The on-device model drops the cue ("no, sorry", "I mean") but keeps both
/// versions, so "Tuesday, no, sorry, Wednesday" came back as "Tuesday,
/// Wednesday". Anything this pass is unsure of is left for the model:
/// deleting words the speaker meant is worse than leaving a correction in.
///
/// Conservative by design: conversational cue phrases, sentence-initial names,
/// ambiguous number runs, questions, exclamations and line breaks are barriers.
/// Edits use original ranges rather than rebuilding sentences, so unrelated
/// punctuation and whitespace survive. Sentence-start capitals are carried
/// forward without lowercasing names or changing an originally lowercase start.
nonisolated enum SpokenRepairs {
    private struct Word {
        let text: String
        let lower: String
        let range: NSRange
        let valid: Bool
    }

    private struct Document {
        let source: NSString
        let words: [Word]

        init(_ text: String) {
            let source = text as NSString
            self.source = source

            words = SpokenRepairs.tokenPattern.matches(
                in: text, range: NSRange(location: 0, length: source.length)
            ).compactMap { match in
                var core = source.substring(with: match.range)
                while let last = core.last, ",.;:!?".contains(last) {
                    core.removeLast()
                }
                guard !core.isEmpty, !["-", "--", "–", "—"].contains(core) else {
                    return nil
                }
                return Word(
                    text: core,
                    lower: core.lowercased(),
                    range: NSRange(
                        location: match.range.location,
                        length: (core as NSString).length),
                    valid: SpokenRepairs.matches(core, SpokenRepairs.wordPattern))
            }
        }

        func gap(_ left: Int, _ right: Int) -> String {
            let start = NSMaxRange(words[left].range)
            let end = right < words.count ? words[right].range.location : source.length
            return source.substring(with: NSRange(location: start, length: end - start))
        }

        func startsSentence(_ index: Int) -> Bool {
            index == 0 || gap(index - 1, index).contains(where: { ".!?".contains($0) })
        }
    }

    private struct Cue {
        let words: [String]
        let strong: Bool
        let numericOnly: Bool

        init(_ phrase: String, strong: Bool = false, numericOnly: Bool = false) {
            words = phrase.lowercased().split(separator: " ").map(String.init)
            self.strong = strong
            self.numericOnly = numericOnly
        }
    }

    private enum Kind: Equatable {
        case weekday, month, relativeDay, number, time, ordinal, name
    }

    private struct Span {
        let start: Int
        let end: Int
        let kind: Kind
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static let wordPattern = regex(
        #"(?i:[$£€]?[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?::[0-9]{2})?(?:am|pm|st|nd|rd|th|%)?|[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*)"#)
    private static let lettersPattern = regex(#"[\p{L}\p{M}]+"#)
    private static let namePattern = regex(
        #"\p{Lu}\p{Ll}+(?:['’\-]\p{Lu}?\p{Ll}+)*"#)
    private static let ordinalPattern = regex(#"[0-9]+(?:st|nd|rd|th)"#)
    private static let numberPattern = regex(
        #"[$£€]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?%?"#)
    private static let plainGapPattern = regex(#"[ \t\u00A0]+"#)
    private static let gapPattern = regex(
        #"[ \t\u00A0]*(?:,|--|–|—|-)?[ \t\u00A0]*"#)
    private static let periodGapPattern = regex(
        #"[ \t\u00A0]*(?:,|--|–|—|-|\.)?[ \t\u00A0]*"#)
    private static let punctuationGapPattern = regex(
        #"[ \t\u00A0]*(?:[,.;:!?]|--|–|—|-)[ \t\u00A0]*"#)

    private static let timePattern: NSRegularExpression = {
        let simple =
            #"(?:[1-9]|1[0-2])(?::[0-5][0-9])? ?(?:am|pm)|(?:[01]?[0-9]|2[0-3]):[0-5][0-9]|(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[1-9]|1[0-2]) (?:am|pm|o['’]clock)|noon|midnight"#
        let hour =
            "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
        let minute =
            "(?:oh[ -](?:one|two|three|four|five|six|seven|eight|nine)|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty)(?:[ -](?:one|two|three|four|five|six|seven|eight|nine))?)"
        let spoken =
            "(?:\(hour) \(minute)|(?:half|quarter) past \(hour)|quarter to \(hour))(?: (?:am|pm))?"
        return regex("(?:\(simple))|(?:\(spoken))")
    }()

    private static let numberGroupPattern: NSRegularExpression = {
        let ones = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let small =
            "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        let underHundred = "(?:\(small)|\(tens)(?: \(ones))?)"
        let hundred = "(?:\(ones) )?hundred(?: (?:and )?\(underHundred))?"
        return regex("\(hundred)|\(underHundred)")
    }()

    // Single words that legitimately double. Number tokens are checked separately.
    private static let allowedRepeats: Set<String> = [
        "had", "that", "very", "really", "so", "no", "yes", "yeah",
        "bye", "ha", "is", "do", "now", "well", "there", "her",
    ]

    // Avoid comma-crossing restarts of particles and the noun "if".
    private static let restartWords = wordSet(
        """
        i we they he she a an the to from at for with by of into onto \
        under between before after and or but nor because \
        while although my our your their his its was were will would can \
        should could have
        """)

    private static let tailWords = wordSet(
        """
        and but or so then at on in by for from to with before after because \
        if please instead next this that
        """)

    private static let weekdays = wordSet(
        "monday tuesday wednesday thursday friday saturday sunday")
    private static let months = wordSet(
        "january february march april may june july august september october november december")
    private static let relativeDays = wordSet("today tomorrow tonight")
    private static let numberWords = wordSet(
        """
        zero one two three four five six seven eight nine ten eleven twelve \
        thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty \
        thirty forty fifty sixty seventy eighty ninety hundred thousand million billion
        """)
    private static let ordinalWords = wordSet(
        """
        first second third fourth fifth sixth seventh eighth ninth tenth \
        eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth \
        eighteenth nineteenth twentieth thirtieth fortieth fiftieth sixtieth \
        seventieth eightieth ninetieth hundredth thousandth millionth billionth
        """)
    private static let units = wordSet(
        """
        dollar dollars buck bucks euro euros pound pounds cent cents percent \
        person people item items ticket tickets second seconds minute minutes hour hours \
        day days week weeks month months year years metre metres meter meters \
        kilometre kilometres kilometer kilometers gram grams kilogram kilograms \
        litre litres liter liters kilo kilos kg km cm mm ml
        """)
    private static let nameStops = wordSet(
        """
        a an the i we you he she it they this that these those my your our their \
        his her its no yes yeah sorry actually thanks please okay ok
        """)

    // Longest cues precede their weak prefixes.
    private static let cues: [Cue] = [
        Cue("no I mean", strong: true),
        Cue("sorry I mean", strong: true),
        Cue("no sorry", strong: true),
        Cue("sorry no", strong: true),
        Cue("no wait", strong: true),
        Cue("wait no", strong: true),
        Cue("or rather", strong: true),
        Cue("I meant", strong: true),
        Cue("make that", strong: true, numericOnly: true),
        Cue("I mean"),
        Cue("sorry"),
        Cue("no"),
        Cue("actually"),
    ]

    static func resolve(_ text: String) -> String {
        var result = text
        for _ in 0..<64 {
            let document = Document(result)
            guard let next = resolveScratch(in: document)
                ?? resolveCue(in: document)
                ?? resolveRepeat(in: document)
            else { return result }
            result = next
        }
        return result
    }

    // MARK: - Restarts

    private static func resolveRepeat(in document: Document) -> String? {
        let words = document.words
        let protected = idiomWords(in: document)
        for start in words.indices {
            let maximum = min(5, (words.count - start) / 2)
            guard maximum > 0 else { continue }
            for width in stride(from: maximum, through: 1, by: -1) {
                let second = start + width
                guard isGap(document.gap(second - 1, second), period: true),
                    !(start..<(second + width)).contains(where: {
                        protected.contains($0)
                    })
                else { continue }

                if width == 1 {
                    let word = words[start]
                    guard !allowedRepeats.contains(word.lower),
                        !isNumberToken(word), word.lower != "oh",
                        word.text == "I" || word.text.first?.isUppercase != true
                            || (document.startsSentence(start) && restartWords.contains(word.lower)),
                        isPlainGap(document.gap(start, second))
                            || restartWords.contains(word.lower)
                    else { continue }
                }

                var equal = true
                for offset in 0..<width {
                    let left = start + offset
                    let right = second + offset
                    if !words[left].valid || !words[right].valid
                        || isNumberToken(words[left]) || words[left].lower == "oh"
                        || (words[left].text != "I" && words[left].text.first?.isUppercase == true
                            && !document.startsSentence(left))
                        || !repeatWordsMatch(left, right, in: document)
                    {
                        equal = false
                        break
                    }
                    if offset > 0,
                        (!isPlainGap(document.gap(left - 1, left))
                            || !isPlainGap(document.gap(right - 1, right)))
                    {
                        equal = false
                        break
                    }
                }
                if equal {
                    return deleting(
                        start, through: second, in: document,
                        carryCapital: words[start].text.first?.isUppercase == true)
                }
            }
        }
        return nil
    }

    private static func repeatWordsMatch(
        _ left: Int, _ right: Int, in document: Document
    ) -> Bool {
        let first = document.words[left]
        let second = document.words[right]
        if first.text == second.text { return true }
        guard first.lower == second.lower,
            document.startsSentence(left),
            !months.contains(first.lower),
            !weekdays.contains(first.lower),
            let initial = second.text.first,
            initial.isLowercase
        else { return false }
        return first.text == initial.uppercased() + String(second.text.dropFirst())
    }

    /// Protect the whole idiom, including overlaps in longer chains, before
    /// trying any repeat width.
    private static func idiomWords(in document: Document) -> Set<Int> {
        let words = document.words
        guard words.count >= 3 else { return [] }
        var result: Set<Int> = []
        for start in 0..<(words.count - 2) {
            guard words[start].valid, words[start + 1].valid, words[start + 2].valid,
                words[start].lower == words[start + 2].lower,
                isPlainGap(document.gap(start, start + 1)),
                isPlainGap(document.gap(start + 1, start + 2))
            else { continue }

            let connector = words[start + 1].lower
            let repeated = words[start].lower
            if ["after", "by", "to"].contains(connector)
                || (connector == "and" && ["again", "more", "over"].contains(repeated))
            {
                result.formUnion(start...(start + 2))
            }
        }
        return result
    }

    // MARK: - Explicit corrections

    private static func resolveCue(in document: Document) -> String? {
        let words = document.words
        var index = 0
        while index < words.count {
            guard let cue = cues.first(where: {
                phrase($0.words, at: index, in: document)
            }) else {
                index += 1
                continue
            }

            let repair = index + cue.words.count
            let cueStart = index
            // Do not reconsider an inner weak cue when a compound cue was refused.
            index = repair

            guard cueStart > 0, repair < words.count,
                isGap(document.gap(cueStart - 1, cueStart), period: cue.strong),
                isGap(document.gap(repair - 1, repair)),
                !blocked(cue, next: words[repair].lower, gap: document.gap(repair - 1, repair))
            else { continue }

            let actually = cue.words == ["actually"]
            if actually, !hasMark(document.gap(cueStart - 1, cueStart)) {
                continue
            }

            let lower = windowStart(before: cueStart, in: document)
            if !cue.numericOnly,
                let pair = parallelSpans(
                    from: lower, before: cueStart, repair: repair, strong: cue.strong, in: document)
            {
                return correcting(pair.0, with: pair.1, in: document)
            }
            if !cue.numericOnly,
                let start = parallelPhrase(
                    from: lower, before: cueStart, repair: repair, strong: cue.strong, in: document)
            {
                return deleting(
                    start, through: repair, in: document,
                    carryCapital: words[start].text.first?.isUppercase == true)
            }
            if cue.numericOnly,
                let result = carriedNumber(
                    from: lower, before: cueStart, repair: repair, in: document)
            {
                return result
            }

            let left = spans(endingAt: cueStart, lower: lower, in: document)
            let right = spans(startingAt: repair, in: document)
            for old in left {
                for new in right {
                    // A strong correction can replace a relative day with a
                    // weekday; weak conversational "no" still needs a match.
                    let dayCorrection = cue.strong
                        && ((old.kind == .relativeDay && new.kind == .weekday)
                            || (old.kind == .weekday && new.kind == .relativeDay))
                    guard old.kind == new.kind || dayCorrection else { continue }
                    guard cue.strong || isTail(after: new.end, in: document) else { continue }
                    if cue.numericOnly, old.kind != .number && old.kind != .time {
                        continue
                    }
                    if actually, old.kind == .name || old.kind == .ordinal {
                        continue
                    }
                    return correcting(old, with: new, in: document)
                }
            }
            if cue.strong, !cue.numericOnly,
                let anchor = anchorStart(
                    from: lower, before: cueStart, repair: repair, in: document)
            {
                return deleting(
                    anchor, through: repair, in: document,
                    carryCapital: words[anchor].text.first?.isUppercase == true)
            }
        }
        return nil
    }

    /// After a weak cue ("sorry", "no", "actually") a replacement must finish
    /// a clause or precede an allowed continuation: in "I called Priya, sorry,
    /// Tash is on the other line" the cue is an aside, not a correction.
    /// Strong cues ("no, sorry", "or rather") are explicit enough without it.
    /// The end is exclusive, as it is for Span.
    private static func isTail(after end: Int, in document: Document) -> Bool {
        if end == document.words.count { return true }
        guard end > 0, end < document.words.count else { return false }
        let gap = document.gap(end - 1, end)
        if gap.contains(where: { ",.;:!?-–—".contains($0) }) { return true }
        return isPlainGap(gap) && tailWords.contains(document.words[end].lower)
    }

    /// "sorry to bother you", "I mean it", "no one": the cue word starts a
    /// phrase. Only when nothing separates them; "no, sorry, to Jules" and
    /// "no, one hundred" are still corrections.
    private static func blocked(_ cue: Cue, next: String, gap: String) -> Bool {
        guard isPlainGap(gap) else { return false }
        if cue.words.last == "sorry", ["for", "about", "to"].contains(next) {
            return true
        }
        if Array(cue.words.suffix(2)) == ["i", "mean"],
            ["it", "that", "to", "what"].contains(next)
        {
            return true
        }
        if cue.words.last == "no",
            ["one", "longer", "way", "problem", "worries", "idea", "need"].contains(next)
        {
            return true
        }
        return false
    }

    /// At most eight words; the caller permits an immediate full stop only
    /// for a strong cue.
    private static func windowStart(before cue: Int, in document: Document) -> Int {
        var start = cue - 1
        while start > 0, cue - start < 8,
            isGap(document.gap(start - 1, start))
        {
            start -= 1
        }
        return start
    }

    private static func anchorStart(
        from lower: Int, before cue: Int, repair: Int, in document: Document
    ) -> Int? {
        let words = document.words
        for start in stride(from: cue - 1, through: lower, by: -1) {
            let maximum = min(3, min(cue - start, words.count - repair))
            for length in stride(from: maximum, through: 1, by: -1) {
                var equal = true
                for offset in 0..<length {
                    let left = start + offset
                    let right = repair + offset
                    if !words[left].valid || !words[right].valid
                        || words[left].lower != words[right].lower
                    {
                        equal = false
                        break
                    }
                    if offset > 0,
                        (!isPlainGap(document.gap(left - 1, left))
                            || !isPlainGap(document.gap(right - 1, right)))
                    {
                        equal = false
                        break
                    }
                }
                if equal { return start }
            }
        }
        return nil
    }

    /// Repeated one- or two-word anchors must lead into matching typed spans.
    private static func parallelSpans(
        from lower: Int, before cue: Int, repair: Int, strong: Bool, in document: Document
    ) -> (Span, Span)? {
        let words = document.words
        for old in spans(endingAt: cue, lower: lower, in: document) {
            for width in 1...2 {
                let start = old.start - width
                let next = repair + width
                guard start >= lower, next < words.count,
                    isPlainGap(document.gap(old.start - 1, old.start)),
                    isPlainGap(document.gap(next - 1, next))
                else { continue }
                let anchor = words[start..<old.start].map(\.lower)
                guard phrase(anchor, at: repair, in: document),
                    width == 1 || (
                        isPlainGap(document.gap(start, start + 1))
                            && isPlainGap(document.gap(repair, repair + 1)))
                else { continue }
                for new in spans(startingAt: next, in: document)
                    where new.kind == old.kind
                {
                    guard strong || isTail(after: new.end, in: document) else { continue }
                    return (
                        Span(start: start, end: old.end, kind: old.kind),
                        Span(start: repair, end: new.end, kind: new.kind))
                }
            }
        }
        return nil
    }

    /// Equal short phrases need both endpoints and a changed interior.
    private static func parallelPhrase(
        from lower: Int, before cue: Int, repair: Int, strong: Bool, in document: Document
    ) -> Int? {
        let words = document.words
        for width in stride(from: 4, through: 2, by: -1) {
            let start = cue - width
            guard start >= lower, repair + width <= words.count,
                words[start].lower == words[repair].lower,
                words[cue - 1].lower == words[repair + width - 1].lower,
                strong || isTail(after: repair + width, in: document)
            else { continue }
            var changed = false
            var valid = true
            for offset in 0..<width {
                let left = start + offset
                let right = repair + offset
                if !words[left].valid || !words[right].valid
                    || (offset > 0 && (
                        !isPlainGap(document.gap(left - 1, left))
                            || !isPlainGap(document.gap(right - 1, right))))
                {
                    valid = false
                    break
                }
                changed = changed || words[left].lower != words[right].lower
            }
            if valid && changed { return start }
        }
        return nil
    }

    /// "Twelve chairs. Make that sixteen": carry only one or two plain words.
    private static func carriedNumber(
        from lower: Int, before cue: Int, repair: Int, in document: Document
    ) -> String? {
        let words = document.words
        let maximum = min(words.count, repair + 8)
        for end in stride(from: maximum, through: repair + 1, by: -1) {
            guard kind(from: repair, to: end, in: document) == .number,
                isNumber(words[repair..<end].map(\.lower).joined(separator: " "))
            else { continue }
            let after = document.gap(end - 1, end)
            let conjunction = end < words.count
                && ["and", "or", "but"].contains(words[end].lower)
                && (end + 1 == words.count || !isNumberComponent(words[end + 1]))
            guard end == words.count
                || matches(after, punctuationGapPattern)
                || (isPlainGap(after) && conjunction)
            else { continue }

            for distance in 1...2 {
                let oldEnd = cue - distance
                guard oldEnd > lower,
                    words[oldEnd..<cue].allSatisfy({
                        matches($0.text, lettersPattern)
                    }),
                    (oldEnd..<cue).allSatisfy({
                        isPlainGap(document.gap($0 - 1, $0))
                    })
                else { continue }
                for old in spans(endingAt: oldEnd, lower: lower, in: document)
                    where old.kind == .number
                {
                    guard isNumber(
                        words[old.start..<old.end].map(\.lower).joined(separator: " "))
                    else { continue }
                    let tailStart = words[oldEnd].range.location
                    let tailEnd = NSMaxRange(words[cue - 1].range)
                    let tail = document.source.substring(
                        with: NSRange(location: tailStart, length: tailEnd - tailStart))
                    return deleting(
                        old.start, through: repair, in: document,
                        carryCapital: words[old.start].text.first?.isUppercase == true,
                        insertion: (NSMaxRange(words[end - 1].range), " " + tail))
                }
            }
        }
        return nil
    }

    private static func correcting(
        _ old: Span, with new: Span, in document: Document
    ) -> String {
        let words = document.words
        let unit = words[old.end - 1]
        var insertion: (Int, String)?
        if units.contains(unit.lower),
            !units.contains(words[new.end - 1].lower),
            new.end == words.count || !units.contains(words[new.end].lower)
        {
            insertion = (NSMaxRange(words[new.end - 1].range), " " + unit.text)
        }
        return deleting(
            old.start, through: new.start, in: document,
            carryCapital: words[old.start].text.first?.isUppercase == true,
            insertion: insertion)
    }

    private static func spans(
        endingAt end: Int, lower: Int, in document: Document
    ) -> [Span] {
        var result: [Span] = []
        for start in lower..<end {
            if let kind = kind(from: start, to: end, in: document),
                completeNumberBoundary(start, end, kind: kind, in: document)
            {
                result.append(Span(start: start, end: end, kind: kind))
            }
        }
        return result
    }

    private static func spans(
        startingAt start: Int, in document: Document
    ) -> [Span] {
        var result: [Span] = []
        let maximum = min(document.words.count, start + 8)
        for end in stride(from: maximum, through: start + 1, by: -1) {
            if let kind = kind(from: start, to: end, in: document),
                completeNumberBoundary(start, end, kind: kind, in: document)
            {
                result.append(Span(start: start, end: end, kind: kind))
            }
        }
        return result
    }

    private static func kind(
        from start: Int, to end: Int, in document: Document
    ) -> Kind? {
        let words = document.words
        guard words[start..<end].allSatisfy(\.valid) else { return nil }
        if end - start > 1 {
            for index in (start + 1)..<end {
                guard isPlainGap(document.gap(index - 1, index)) else { return nil }
            }
        }
        let value = words[start..<end].map(\.lower).joined(separator: " ")
        if weekdays.contains(value) { return .weekday }
        if months.contains(value) { return .month }
        if relativeDays.contains(value) { return .relativeDay }
        if isTime(value) { return .time }
        if isOrdinal(value) { return .ordinal }

        // Include the established ordinal complement in the replacement span,
        // so "second exit" must satisfy the same tail rule as other repairs.
        if end - start == 2, words[end - 1].lower == "exit",
            isOrdinal(words[start].lower)
        {
            return .ordinal
        }

        var components = value.split(separator: " ").map(String.init)
        if let last = components.last, units.contains(last) {
            components.removeLast()
        }
        if isNumber(components.joined(separator: " ")) { return .number }

        guard end - start <= 2, !document.startsSentence(start) else { return nil }
        for word in words[start..<end] {
            guard !nameStops.contains(word.lower),
                !weekdays.contains(word.lower),
                !months.contains(word.lower),
                !relativeDays.contains(word.lower),
                !isNumberToken(word),
                matches(word.text, namePattern)
            else { return nil }
        }
        return .name
    }

    /// Never salvage just the tail or head of an unparseable numeric run.
    private static func completeNumberBoundary(
        _ start: Int, _ end: Int, kind: Kind, in document: Document
    ) -> Bool {
        guard kind == .number || kind == .time || kind == .ordinal else { return true }
        let words = document.words
        if start > 0, isPlainGap(document.gap(start - 1, start)),
            isNumberComponent(words[start - 1])
        {
            return false
        }
        if end < words.count, isPlainGap(document.gap(end - 1, end)),
            isNumberComponent(words[end])
        {
            return false
        }
        return true
    }

    // MARK: - Numbers and times

    private static func isNumberToken(_ word: Word) -> Bool {
        word.text.rangeOfCharacter(from: .decimalDigits) != nil
            || numberWords.contains(word.lower)
            || isOrdinal(word.lower)
    }

    private static func isNumberComponent(_ word: Word) -> Bool {
        isNumberToken(word)
            || ["and", "point", "am", "pm", "o'clock", "o’clock"].contains(word.lower)
    }

    private static func isTime(_ value: String) -> Bool {
        matches(value, timePattern)
    }

    private static func isOrdinal(_ value: String) -> Bool {
        if ordinalWords.contains(value) { return true }
        if matches(value, ordinalPattern) { return true }
        let parts = value.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        return parts.count == 2
            && wordSet("twenty thirty forty fifty sixty seventy eighty ninety")
                .contains(parts[0])
            && wordSet("first second third fourth fifth sixth seventh eighth ninth")
                .contains(parts[1])
    }

    private static func isNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if matches(value, numberPattern) { return true }

        let words = value.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }

        var whole = words
        if let point = words.firstIndex(of: "point") {
            let fraction = words[(point + 1)...]
            guard !fraction.isEmpty,
                fraction.allSatisfy({
                    wordSet("zero one two three four five six seven eight nine").contains($0)
                })
            else { return false }
            whole = Array(words[..<point])
        }
        guard !whole.isEmpty else { return false }

        let scales = ["thousand": 1, "million": 2, "billion": 3]
        var previousScale = 4
        var start = 0
        var sawScale = false
        for index in whole.indices {
            guard let scale = scales[whole[index]] else { continue }
            guard scale < previousScale, index > start,
                isNumberGroup(Array(whole[start..<index]))
            else { return false }
            previousScale = scale
            sawScale = true
            start = index + 1
            if start < whole.count, whole[start] == "and" {
                start += 1
                guard start < whole.count else { return false }
            }
        }
        if start == whole.count { return sawScale }
        return isNumberGroup(Array(whole[start...]))
    }

    private static func isNumberGroup(_ words: [String]) -> Bool {
        matches(words.joined(separator: " "), numberGroupPattern)
    }

    // MARK: - Scratch / strike / delete that

    private static func resolveScratch(in document: Document) -> String? {
        let words = document.words
        for index in words.indices where index > 0 {
            guard ["scratch", "strike", "delete"].contains(words[index].lower),
                phrase([words[index].lower, "that"], at: index, in: document)
            else { continue }

            let before = document.gap(index - 1, index)
            let after = document.gap(index + 1, index + 2)
            let repair = index + 2
            if (isGap(before, period: true) || isPlainGap(before) || before == "? "),
                repair < words.count, isGap(after, period: true)
            {
                let lower = windowStart(before: index, in: document)
                for old in spans(endingAt: index, lower: lower, in: document) {
                    guard [Kind.number, .time, .weekday, .name].contains(old.kind) else { continue }
                    for new in spans(startingAt: repair, in: document) where old.kind == new.kind {
                        return correcting(old, with: new, in: document)
                    }
                }
                // Include a repeated label such as "Python three point eleven".
                for start in lower..<index where words[start].lower == words[repair].lower {
                    guard start + 1 < index, repair + 1 < words.count,
                        isPlainGap(document.gap(start, start + 1)),
                        isPlainGap(document.gap(repair, repair + 1)),
                        let oldKind = kind(from: start + 1, to: index, in: document),
                        [Kind.number, .time].contains(oldKind),
                        spans(startingAt: repair + 1, in: document).contains(where: { $0.kind == oldKind })
                    else { continue }
                    return deleting(start, through: repair, in: document, carryCapital: false)
                }
                for start in max(lower, index - 3)..<index {
                    guard let oldKind = scratchPhrase(from: start, to: index, in: document) else { continue }
                    for end in stride(from: min(words.count, repair + 3), through: repair + 1, by: -1) {
                        guard scratchPhrase(from: repair, to: end, in: document) == oldKind,
                            isTail(after: end, in: document)
                        else { continue }
                        var result = deleting(start, through: repair, in: document, carryCapital: false)
                        if oldKind == "adjective", document.startsSentence(repair), !document.startsSentence(start) {
                            let ns = NSMutableString(string: result)
                            let location = words[start].range.location
                            ns.replaceCharacters(
                                in: NSRange(location: location, length: 1),
                                with: ns.substring(with: NSRange(location: location, length: 1)).lowercased())
                            result = ns as String
                        }
                        return result
                    }
                }
            }
            guard isGap(before, period: true),
                hasMark(before) || before.contains("."),
                after.isEmpty || isGap(after, period: true),
                index + 2 == words.count || hasMark(after) || after.contains(".")
            else { continue }

            var start = index - 1
            while start > 0 {
                let gap = document.gap(start - 1, start)
                if gap.contains(where: { ".!?\r\n".contains($0) }) { break }
                start -= 1
            }
            let clause = words[start..<index].map(\.lower).joined(separator: " ")
            guard !before.contains("?"),
                clause.range(of: #"^(?:(?:can|could|would) you\b|please\b)"#, options: .regularExpression) == nil
            else { continue }
            return deleting(
                start, through: index + 2, in: document, carryCapital: true)
        }
        return nil
    }

    private static func scratchPhrase(from start: Int, to end: Int, in document: Document) -> String? {
        let words = document.words
        guard end - start <= 3, words[start..<end].allSatisfy(\.valid) else { return nil }
        for index in (start + 1)..<end {
            guard isPlainGap(document.gap(index - 1, index)) else { return nil }
        }
        let adjectives = wordSet(
            "black white red green blue yellow orange purple pink grey gray brown charcoal forest navy cream beige teal maroon dark light old new large small spare main big soft hard warm cool bright dull round square wooden plastic")
        let phraseWords = words[start..<end]
        if adjectives.contains(words[start].lower),
            phraseWords.allSatisfy({
                matches($0.text, lettersPattern)
                    && !wordSet("is are was were has have needs wants looks seems can will").contains($0.lower)
            })
        {
            return "adjective"
        }
        if phraseWords.allSatisfy({
            matches($0.text, namePattern) && !nameStops.contains($0.lower)
                && !weekdays.contains($0.lower) && !months.contains($0.lower)
                && !wordSet("tell send ask call ping meet use move book activate").contains($0.lower)
        }) {
            return "name"
        }
        return nil
    }

    // MARK: - Range edits

    private static func deleting(
        _ start: Int, through repair: Int, in document: Document, carryCapital: Bool,
        insertion: (Int, String)? = nil
    ) -> String {
        var location = document.words[start].range.location
        let end = repair < document.words.count
            ? document.words[repair].range.location : document.source.length

        // A final retraction must not leave the preceding sentence's gap behind.
        if repair == document.words.count {
            while location > 0 {
                let previous = document.source.character(at: location - 1)
                guard previous == 32 || previous == 9 || previous == 160 else { break }
                location -= 1
            }
        }

        var suffix = document.source.substring(from: end)
        if let (position, text) = insertion {
            guard position >= end, position <= document.source.length else {
                return document.source as String
            }
            suffix = (suffix as NSString).replacingCharacters(
                in: NSRange(location: position - end, length: 0), with: text)
        }
        if carryCapital, document.startsSentence(start), let first = suffix.first {
            suffix = first.uppercased() + String(suffix.dropFirst())
        }
        return document.source.substring(to: location) + suffix
    }

    private static func phrase(
        _ parts: [String], at start: Int, in document: Document
    ) -> Bool {
        guard start + parts.count <= document.words.count else { return false }
        for offset in parts.indices {
            let index = start + offset
            guard document.words[index].valid,
                document.words[index].lower == parts[offset].lowercased()
            else { return false }
            if offset > 0, !isGap(document.gap(index - 1, index)) { return false }
        }
        return true
    }

    private static func isPlainGap(_ value: String) -> Bool {
        matches(value, plainGapPattern)
    }

    private static func isGap(_ value: String, period: Bool = false) -> Bool {
        guard !value.isEmpty else { return false }
        return matches(value, period ? periodGapPattern : gapPattern)
    }

    private static func hasMark(_ value: String) -> Bool {
        value.contains(where: { ",-–—".contains($0) })
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"\A(?:"# + pattern + #")\z"#)
    }

    private static func matches(_ value: String, _ pattern: NSRegularExpression) -> Bool {
        pattern.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func wordSet(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
