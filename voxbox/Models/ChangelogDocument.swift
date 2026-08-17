import Foundation

/// One version section from CHANGELOG.md.
struct ChangelogEntry: Equatable, Identifiable {
    var id: String { version }
    let version: String
    let date: String?
    let markdown: String
}

/// Parses Keep-a-Changelog headings (`## [1.2.0] - 2026-08-17`) into entries.
/// Unreleased stubs and the SpeakType footer are omitted.
enum ChangelogDocument {
    static func parse(_ text: String) -> [ChangelogEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [ChangelogEntry] = []
        var currentVersion: String?
        var currentDate: String?
        var body: [String] = []
        var inEntry = false

        func flush() {
            guard let version = currentVersion else {
                currentDate = nil
                body = []
                inEntry = false
                return
            }
            let markdown = cleanedMarkdown(body.joined(separator: "\n"))
            if !markdown.isEmpty {
                entries.append(
                    ChangelogEntry(version: version, date: currentDate, markdown: markdown)
                )
            }
            currentVersion = nil
            currentDate = nil
            body = []
            inEntry = false
        }

        for line in lines {
            if let heading = parseHeading(line) {
                flush()
                currentVersion = heading.version
                currentDate = heading.date
                inEntry = true
                continue
            }
            if line.hasPrefix("## [") {
                flush()
                continue
            }
            if inEntry {
                body.append(line)
            }
        }
        flush()
        return entries
    }

    static func bundled(in bundle: Bundle = .main) -> [ChangelogEntry] {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return parse(text)
    }

    /// `## [1.2.0]` or `## [1.2.0] - 2026-08-17`. Non-numeric labels (Unreleased) return nil.
    static func parseHeading(_ line: String) -> (version: String, date: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## [") else { return nil }
        let rest = trimmed.dropFirst(4)
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let version = String(rest[rest.startIndex..<close])
        guard let first = version.first, first.isNumber else { return nil }

        var date: String?
        let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("-") {
            let value = after.dropFirst().trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { date = value }
        }
        return (version, date)
    }

    private static func cleanedMarkdown(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("_") { return false }
                if trimmed == "---" { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
