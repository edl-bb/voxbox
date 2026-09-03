import XCTest

@testable import voxbox

final class AutoEditTests: XCTestCase {

    private func edit(_ text: String) -> String {
        AutoEdit.apply(to: text, enabled: true)
    }

    func testDisabledOnlyTrims() {
        XCTAssertEqual(AutoEdit.apply(to: "  um hello  ", enabled: false), "um hello")
    }

    func testTextWithoutFillersIsUntouched() {
        XCTAssertEqual(edit("hello there"), "hello there")
        XCTAssertEqual(edit("roy@example.com"), "roy@example.com")
        XCTAssertEqual(edit("first line.\n\nsecond paragraph"), "first line.\n\nsecond paragraph")
    }

    func testStripsFillersAndTheirCommas() {
        XCTAssertEqual(edit("Um, so we go"), "So we go")
        XCTAssertEqual(edit("I think, uh, we should ship"), "I think, we should ship")
        XCTAssertEqual(edit("we should um ship it"), "we should ship it")
        XCTAssertEqual(edit("ah yes er no"), "Yes no")
    }

    func testKeepsOneCommaWhenTheFillerSatBetweenTwo() {
        XCTAssertEqual(edit("Yes, um, we should ship"), "Yes, we should ship")
    }

    func testKeepsATerminalMarkAndDropsTheOrphanedOne() {
        XCTAssertEqual(edit("ready. Um. Next"), "ready. Next")
        XCTAssertEqual(edit("Is it done? Um. Yes"), "Is it done? Yes")
    }

    func testNoOrphanCommaOrFullStopIsLeftBehind() {
        let result = edit("I was going to say, um. Then I stopped.")
        XCTAssertFalse(result.contains(",."))
        XCTAssertFalse(result.contains(" ."))
        XCTAssertFalse(result.contains(" ,"))
        XCTAssertEqual(result, "I was going to say. Then I stopped.")
    }

    func testWordsContainingFillerLettersSurvive() {
        XCTAssertEqual(edit("hum along rather quickly and umbrella"), "hum along rather quickly and umbrella")
        XCTAssertEqual(edit("Her father came"), "Her father came")
    }

    func testParagraphBreaksSurvive() {
        XCTAssertEqual(
            edit("First line, um, done.\n\n\nsecond paragraph  here"),
            "First line, done.\n\nsecond paragraph here")
    }

    func testCapitalisesOnlyAfterAStrippedSentenceStart() {
        XCTAssertEqual(edit("um so hi Priya. uh can you send it"), "So hi Priya. Can you send it")
        XCTAssertEqual(edit("Done.\n\num next point"), "Done.\n\nNext point")
        XCTAssertEqual(edit("um roy@example.com"), "roy@example.com", "an email is never capitalised")
        XCTAssertEqual(edit("um iPhone is fine"), "iPhone is fine", "mixed case is left alone")
    }
}
