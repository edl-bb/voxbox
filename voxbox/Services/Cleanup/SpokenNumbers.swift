import Foundation

/// Deterministic "twelve thousand five hundred dollars" → "$12,500" for the
/// Light and Polish levels. The model is asked to do this too, but a small
/// model skips it often enough that the pass has to be ours.
///
/// Conservative by design: a run is converted only when it is clearly a
/// number being read out (two or more number words, a scale word, or a unit
/// such as dollars or percent after it). A lone "one" or "two" is left as
/// spoken, and runs that do not parse as one number ("twenty twenty six",
/// "one two three") are left alone.
nonisolated enum SpokenNumbers {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    enum Unit: Equatable {
        case currency(String)  // symbol prefix
        case percent
        case cents
        case meridiem(String)  // "am" / "pm"

        static func parse(_ word: String, next: String?) -> (unit: Unit, wordCount: Int)? {
            switch word {
            case "dollars", "dollar", "bucks", "buck": return (.currency("$"), 1)
            case "pounds", "pound", "quid": return (.currency("£"), 1)
            case "euros", "euro": return (.currency("€"), 1)
            case "percent", "percentage": return (.percent, 1)
            case "per": return next == "cent" ? (.percent, 2) : nil
            case "cents", "cent": return (.cents, 1)
            case "am", "pm": return (.meridiem(word), 1)
            default: return nil
            }
        }
    }

    private struct Word {
        var text: String
        var range: NSRange
    }

    static func render(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z]+(?:'[A-Za-z]+)?"#) else { return text }
        let ns = NSMutableString(string: text)
        let words = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Word(text: ns.substring(with: $0.range).lowercased(), range: $0.range)
        }

        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < words.count {
            guard isNumberWord(words[index].text) else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < words.count, adjacent(words[end], words[end + 1], in: ns),
                isNumberWord(words[end + 1].text) || isJoiner(words[end + 1].text, next: end + 2 < words.count ? words[end + 2].text : nil)
            {
                end += 1
            }
            // Trailing "and"/"point" that did not lead anywhere is not part of the number.
            while end > index, !isNumberWord(words[end].text) { end -= 1 }
            let run = Array(words[index...end])
            let numberWords = run.filter { isNumberWord($0.text) }

            var unit: (unit: Unit, wordCount: Int)?
            if end + 1 < words.count, adjacent(words[end], words[end + 1], in: ns) {
                unit = Unit.parse(words[end + 1].text, next: end + 2 < words.count ? words[end + 2].text : nil)
            }

            let hasScale = numberWords.contains { scales[$0.text] != nil }
            let clearlyANumber = numberWords.count >= 2 || hasScale || unit != nil
            if clearlyANumber, let value = parse(run.map(\.text)) {
                var lastRange = words[end].range
                if let unit { lastRange = words[end + unit.wordCount].range }
                // "a hundred dollars" → "$100": the article belongs to the number.
                var startRange = words[index].range
                if index > 0, ["a", "an"].contains(words[index - 1].text), scales[words[index].text] != nil,
                    adjacent(words[index - 1], words[index], in: ns)
                {
                    startRange = words[index - 1].range
                }
                let replaceRange = NSRange(
                    location: startRange.location,
                    length: lastRange.location + lastRange.length - startRange.location)
                replacements.append((replaceRange, format(value, unit: unit?.unit)))
                index = end + 1 + (unit?.wordCount ?? 0)
            } else {
                index = end + 1
            }
        }

        for (range, replacement) in replacements.reversed() {
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }

    // MARK: - Parsing

    static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil || scales[word] != nil
    }

    private static func isJoiner(_ word: String, next: String?) -> Bool {
        guard let next, isNumberWord(next) else { return false }
        return word == "and" || word == "point"
    }

    /// Only whitespace or hyphens between two words.
    private static func adjacent(_ a: Word, _ b: Word, in ns: NSMutableString) -> Bool {
        let gapStart = a.range.location + a.range.length
        let gap = ns.substring(with: NSRange(location: gapStart, length: b.range.location - gapStart))
        return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "-" || $0 == "\u{00A0}" }
    }

    /// Parses a run of number words into a decimal string, or nil when the
    /// sequence is not one well-formed number.
    static func parse(_ words: [String]) -> Decimal? {
        var total = 0
        var current = 0
        var lastKind: Kind = .start
        var index = 0
        var fraction = ""
        var sawScale = false

        while index < words.count {
            let word = words[index]
            if word == "point" {
                // Decimal digits follow, each 0-9, then optionally one scale
                // ("two point five million").
                index += 1
                while index < words.count, let digit = units[words[index]], digit < 10 {
                    fraction += String(digit)
                    index += 1
                }
                guard !fraction.isEmpty else { return nil }
                var value = Decimal(total + current) + (Decimal(string: "0." + fraction) ?? 0)
                if index < words.count, let scale = scales[words[index]] {
                    value *= Decimal(scale)
                    index += 1
                }
                guard index == words.count else { return nil }
                return value
            }
            if word == "and" {
                guard sawScale, lastKind == .scale else { return nil }
                index += 1
                continue
            }
            if let value = units[word] {
                // A unit may open, or follow a tens word (twenty [one]), a scale, or "and".
                switch lastKind {
                case .start, .scale, .and: break
                case .tens: guard value < 10 else { return nil }
                case .unit, .teen: return nil
                }
                current += value
                lastKind = value >= 10 ? .teen : .unit
            } else if let value = tens[word] {
                switch lastKind {
                case .start, .scale, .and: break
                default: return nil
                }
                current += value
                lastKind = .tens
            } else if let scale = scales[word] {
                guard lastKind != .scale || scale > 100 else { return nil }
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
                lastKind = .scale
                sawScale = true
            } else {
                return nil
            }
            index += 1
        }
        return Decimal(total + current)
    }

    private enum Kind { case start, unit, teen, tens, scale, and }

    // MARK: - Formatting

    static func format(_ value: Decimal, unit: Unit?) -> String {
        let number = grouped(value)
        switch unit {
        case .currency(let symbol)?: return symbol + number
        case .percent?: return number + "%"
        case .cents?: return number + " cents"
        case .meridiem(let suffix)?: return number + suffix
        case nil: return number
        }
    }

    /// Thousands separators, no locale surprises, up to two decimals.
    static func grouped(_ value: Decimal) -> String {
        var text = "\(value)"
        var fraction = ""
        if let dot = text.firstIndex(of: ".") {
            fraction = String(text[dot...])
            text = String(text[..<dot])
        }
        var out = ""
        for (offset, char) in text.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return String(out.reversed()) + fraction
    }
}
