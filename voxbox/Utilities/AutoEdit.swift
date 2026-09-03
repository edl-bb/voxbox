import Foundation

/// Deterministic filler-word strip and space tidy. Instant, offline, no model.
/// Distinct from on-device AI cleanup, which can also drop fillers but only
/// on longer dictations and only when a cleanup model is available.
nonisolated enum AutoEdit {
    static let defaultsKey = "enableAutoEdit"

    /// Optional comma before, the filler, optional comma or terminal mark
    /// after. Word boundaries are letters so "hum" and "rather" survive.
    private static let fillerPattern =
        #"(?i)(,\s*)?(?<![A-Za-z])(?:uh+|um+|umm+|uhm+|erm+|hmm+|ah|er)(?![A-Za-z])(\s*([,.;:!?]))?"#

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func apply(to text: String) -> String {
        apply(to: text, enabled: isEnabled)
    }

    static func apply(to text: String, enabled: Bool) -> String {
        guard enabled else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var edited = stripFillers(text)
        edited = edited.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        // Collapse runs of spaces but keep paragraph breaks: the model (and
        // the reader) need them.
        edited = edited.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        edited = edited.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        edited = edited.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        edited = edited.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // Trim first: a stripped opening filler leaves a leading space, and
        // the sentence-start rule anchors on the first character.
        return capitaliseAfterStrip(edited.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "I was, um, going" → "I was going"; "ready. Um. Next" → "ready. Next";
    /// "Um, so we" → "so we" (`apply` then capitalises the new sentence
    /// start). Keeps a terminal mark, keeps exactly one comma when the filler
    /// sat between two.
    static func stripFillers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: fillerPattern) else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let leadingComma = match.range(at: 1).location != NSNotFound
            let trailing = match.range(at: 3).location != NSNotFound
                ? ns.substring(with: match.range(at: 3)) : ""
            let replacement: String
            switch trailing {
            case ".", "!", "?", ";", ":":
                replacement = trailing  // "ready. Um. Next" keeps one full stop
            case ",":
                replacement = leadingComma ? "," : ""
            default:
                replacement = ""
            }
            ns.replaceCharacters(in: match.range, with: replacement)
        }
        var result = ns as String
        // A stripped filler can leave "word ." or ", ," behind.
        result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([.!?;:])\s*\."#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*[,;:]\s*"#, with: "", options: .regularExpression)
        return result
    }

    /// A filler at the start of a sentence leaves the next word lowercase.
    private static func capitaliseAfterStrip(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(^|[.!?]\s+|\n\n)([a-z])"#) else { return text }
        let ns = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range(at: 2)
            ns.replaceCharacters(in: range, with: ns.substring(with: range).uppercased())
        }
        return ns as String
    }
}
