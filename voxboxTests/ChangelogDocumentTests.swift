import XCTest
@testable import voxbox

final class ChangelogDocumentTests: XCTestCase {
    func testParseHeadingReadsVersionAndDate() {
        let heading = ChangelogDocument.parseHeading("## [1.1.0] - 2026-08-16")
        XCTAssertEqual(heading?.version, "1.1.0")
        XCTAssertEqual(heading?.date, "2026-08-16")
    }

    func testParseHeadingIgnoresUnreleased() {
        XCTAssertNil(ChangelogDocument.parseHeading("## [Unreleased]"))
    }

    func testParseKeepsNestedMarkdownAndDropsFooter() {
        let text = """
            # Changelog

            ## [Unreleased]

            ## [1.10.0] - 2026-08-18
            - Ten-dot-zero only.

            ## [1.1.0] - 2026-08-16
            - Parent item.
            - Nested group:
                - Child item.

            ### Security fix
            - Logging fix.

            ## [1.0.0] - 2026-08-15
            - First VoxBox release.

            _**Note:** For SpeakType's change history._
            """

        let entries = ChangelogDocument.parse(text)
        XCTAssertEqual(entries.map(\.version), ["1.10.0", "1.1.0", "1.0.0"])

        XCTAssertEqual(entries[0].markdown, "- Ten-dot-zero only.")
        XCTAssertEqual(
            entries[1].markdown,
            """
            - Parent item.
            - Nested group:
                - Child item.

            ### Security fix
            - Logging fix.
            """
        )
        XCTAssertEqual(entries[2].markdown, "- First VoxBox release.")
        XCTAssertFalse(entries[2].markdown.contains("SpeakType"))
    }

    func testParseSkipsEmptyUnreleased() {
        let entries = ChangelogDocument.parse("""
            ## [Unreleased]

            ## [1.0.0] - 2026-08-15
            - First release.
            """)
        XCTAssertEqual(entries.map(\.version), ["1.0.0"])
    }

    func testParsesRepoChangelog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = ChangelogDocument.parse(text)
        XCTAssertTrue(entries.contains { $0.version == "1.1.0" })
        XCTAssertTrue(entries.contains { $0.version == "1.0.0" })
        let first = try XCTUnwrap(entries.first { $0.version == "1.0.0" })
        XCTAssertTrue(first.markdown.contains("    - English (Australia)"))
        XCTAssertFalse(first.markdown.contains("SpeakType Changelog"))
    }

    func testMarkdownBlocksPreserveHeadingsAndNestedLists() {
        let markdown = """
            - Parent item.
            - Nested group:
                - Child item.

            ### Security fix
            - Logging with `/tmp` path.
            """
        XCTAssertEqual(
            ChangelogMarkdown.blocks(in: markdown),
            [
                .listItem(depth: 0, text: "Parent item."),
                .listItem(depth: 0, text: "Nested group:"),
                .listItem(depth: 2, text: "Child item."),
                .heading(level: 3, text: "Security fix"),
                .listItem(depth: 0, text: "Logging with `/tmp` path."),
            ]
        )
    }

    func testMarkdownBlocksParseRepoChangelogNestedSection() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let first = try XCTUnwrap(ChangelogDocument.parse(text).first { $0.version == "1.0.0" })
        let blocks = ChangelogMarkdown.blocks(in: first.markdown)
        XCTAssertTrue(blocks.contains { $0 == .heading(level: 4, text: "Security fix") })
        XCTAssertTrue(
            blocks.contains {
                if case .listItem(let depth, let text) = $0 {
                    return depth == 2 && text.hasPrefix("English (Australia)")
                }
                return false
            }
        )
    }
}
