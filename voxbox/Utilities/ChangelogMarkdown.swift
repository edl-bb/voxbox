import Foundation

/// Changelog-flavored markdown blocks: headings, nested lists, paragraphs.
/// SwiftUI `Text(AttributedString)` drops list and heading presentation, so
/// Release Notes renders these blocks explicitly.
enum ChangelogMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case listItem(depth: Int, text: String)
    case paragraph(String)
}

enum ChangelogMarkdown {
    static func blocks(in markdown: String) -> [ChangelogMarkdownBlock] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [ChangelogMarkdownBlock] = []

        for raw in lines {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if let heading = parseHeading(line) {
                blocks.append(heading)
                continue
            }
            if let item = parseListItem(line) {
                blocks.append(item)
                continue
            }
            blocks.append(.paragraph(line.trimmingCharacters(in: .whitespaces)))
        }
        return blocks
    }

    /// Inline markdown (`code`, **bold**, [links](url)) for a single line of text.
    static func inline(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString() }
        do {
            return try AttributedString(
                markdown: trimmed,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } catch {
            return AttributedString(trimmed)
        }
    }

    private static func parseHeading(_ line: String) -> ChangelogMarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var rest = trimmed[...]
        while rest.first == "#" {
            level += 1
            rest = rest.dropFirst()
        }
        guard (1...6).contains(level), rest.first == " " else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func parseListItem(_ line: String) -> ChangelogMarkdownBlock? {
        var spaces = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            spaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let marker = line[index]
        guard marker == "-" || marker == "*" else { return nil }
        let afterMarker = line.index(after: index)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        let text = String(line[line.index(after: afterMarker)...])
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .listItem(depth: spaces / 2, text: text)
    }
}
