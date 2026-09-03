import XCTest

@testable import voxbox

final class CleanupPostPassTests: XCTestCase {

    // MARK: - Preamble and trailer

    func testStripsWrapperLinesCourtesyOpenersAndQuotes() {
        let dictation = "Send the deck to Sam by Thursday."
        for wrapped in [
            "Here is the cleaned text:\n\(dictation)",
            "Sure! Here's the tidied dictation: \(dictation)",
            "**Cleaned transcript:**\n\n\(dictation)",
            "\"\(dictation)\"",
            "“\(dictation)”",
            "Output: \(dictation)",
        ] {
            XCTAssertEqual(CleanupPostPass.stripModelPreamble(wrapped), dictation, wrapped)
        }
    }

    func testStripsALeakedRememberTrailer() {
        let text = "Send the deck to Sam by Thursday.\n\nREMEMBER: keep every word. Reply with only the text."
        XCTAssertEqual(CleanupPostPass.stripModelPreamble(text), "Send the deck to Sam by Thursday.")
    }

    func testStripsLeakedInstructionStages() {
        let compiled = CleanupPromptSet.compiled
        let dictation = "Send the deck to Sam by Thursday."
        XCTAssertEqual(
            CleanupPostPass.stripModelPreamble(compiled.outputOnly + "\n\n" + dictation), dictation)
        XCTAssertEqual(
            CleanupPostPass.stripModelPreamble(compiled.style + "\n" + dictation), dictation)
    }

    func testKeepsDictationThatMerelyStartsLikeAWrapper() {
        let agenda = "Here is the meeting agenda for tomorrow morning."
        XCTAssertEqual(CleanupPostPass.stripModelPreamble(agenda), agenda)
        let transcriptWord = "Transcript review is at two, then the retro."
        XCTAssertEqual(CleanupPostPass.stripModelPreamble(transcriptWord), transcriptWord)
    }

    func testRefusalDetection() {
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("Sorry, I can't help with that."))
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("I’m unable to process this request."))
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("As an AI language model I cannot"))
        XCTAssertFalse(CleanupPostPass.looksLikeRefusal("Sorry I missed the call, ring me back."))
        XCTAssertFalse(CleanupPostPass.looksLikeRefusal("Sure thing, see you at two."))
    }

    // MARK: - Punctuation and whitespace

    func testNormalisePunctuationRemovesDoublesAndStraySpaces() {
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("Hello ,, world .."), "Hello, world.")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("Really ?. Yes !!"), "Really? Yes!")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("one, . two"), "one. two")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("etc.Next thing"), "etc. Next thing")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("Wait... what"), "Wait... what")
    }

    func testNormaliseWhitespaceCollapsesRunsButKeepsParagraphs() {
        XCTAssertEqual(
            CleanupPostPass.normaliseWhitespace("  one   two \n\n\n\n three  \t four \r\n"),
            "one two\n\nthree four")
    }

    func testTrailingEllipsisBecomesAFullStopUnlessDictated() {
        XCTAssertEqual(CleanupPostPass.fixTrailingEllipsis("See you there...", reference: "see you there"), "See you there.")
        XCTAssertEqual(CleanupPostPass.fixTrailingEllipsis("See you there…", reference: "see you there"), "See you there.")
        XCTAssertEqual(
            CleanupPostPass.fixTrailingEllipsis("See you there...", reference: "see you there..."),
            "See you there...")
    }

    func testAutoEditCapitalisesAfterALeadingFillerAndKeepsParagraphs() {
        XCTAssertEqual(AutoEdit.apply(to: "um so we should ship it", enabled: true), "So we should ship it")
        XCTAssertEqual(
            AutoEdit.apply(to: "we need eggs, um, milk and bread", enabled: true),
            "We need eggs, milk and bread", "one comma survives when the filler sat between two")
        XCTAssertEqual(AutoEdit.apply(to: "ready. Um. Next thing", enabled: true), "Ready. Next thing")
        XCTAssertEqual(
            AutoEdit.apply(to: "first point, uh, done.\n\nsecond point", enabled: true),
            "First point, done.\n\nSecond point")
        XCTAssertEqual(AutoEdit.apply(to: "  um hello  ", enabled: false), "um hello")
        XCTAssertEqual(
            AutoEdit.apply(to: "the hum of the server rather than", enabled: true),
            "The hum of the server rather than", "fillers are whole words only")
    }

    func testTidyLeavesEmailsAndURLsAlone() {
        let email = "Send it to sam.reilly@northwindlabs.com , thanks"
        XCTAssertEqual(
            CleanupPostPass.tidy(email, reference: email, markdownAllowed: false),
            "Send it to sam.reilly@northwindlabs.com, thanks")
        let url = "the build is at https://staging.voxbox.app/v2.1 , have a play"
        XCTAssertEqual(
            CleanupPostPass.tidy(url, reference: url, markdownAllowed: false),
            "The build is at https://staging.voxbox.app/v2.1, have a play")
        let two = "mail sam@x.io ,, then open www.voxbox.app .."
        XCTAssertEqual(
            CleanupPostPass.tidy(two, reference: two, markdownAllowed: false),
            "Mail sam@x.io, then open www.voxbox.app.")
    }

    // MARK: - Casing

    func testCapitalisesSentenceStartsOnlyForLowercaseWords() {
        XCTAssertEqual(
            CleanupPostPass.capitaliseSentenceStarts("hello there. how are you? fine\n\nnew paragraph"),
            "Hello there. How are you? Fine\n\nNew paragraph")
        XCTAssertEqual(CleanupPostPass.capitaliseSentenceStarts("iPhone is here. eBay too"), "iPhone is here. eBay too")
        XCTAssertEqual(
            CleanupPostPass.capitaliseSentenceStarts("items:\n- first\n- second\n1. third"),
            "Items:\n- First\n- Second\n1. Third")
    }

    func testAllCapsWordsTheSpeakerDictatedInLowercaseAreRestored() {
        let input = "please send the report to finance today"
        XCTAssertEqual(
            CleanupPostPass.tidy("PLEASE SEND the report to finance today", reference: input, markdownAllowed: false),
            "Please send the report to finance today")
    }

    func testTitleCaseRunsAreUndoneButSingleNamesStay() {
        let input = "please send the report to priya in finance today"
        XCTAssertEqual(
            CleanupPostPass.repairCasing("Please Send The Report To Priya In Finance Today", reference: input),
            "please send the report to priya in finance today")
        XCTAssertEqual(
            CleanupPostPass.repairCasing("Please send the report to Priya in finance today", reference: input),
            "Please send the report to Priya in finance today")
    }

    func testAllCapsDictatedByTheSpeakerIsKept() {
        let input = "the API returned a 500 from AWS"
        XCTAssertEqual(
            CleanupPostPass.tidy("The API returned a 500 from AWS.", reference: input, markdownAllowed: false),
            "The API returned a 500 from AWS.")
    }

    func testCasingAnomalyFlagsShoutedOutput() {
        let result = CleanupPostPass.tidyWithDiagnostics(
            "THIS IS ALL CAPS OUTPUT HERE", reference: "some other words entirely", markdownAllowed: false)
        XCTAssertTrue(result.casingAnomaly)
        let calm = CleanupPostPass.tidyWithDiagnostics(
            "This is calm output here.", reference: "this is calm output here", markdownAllowed: false)
        XCTAssertFalse(calm.casingAnomaly)
    }

    // MARK: - Markdown residue

    func testMarkdownResidueIsStrippedOnlyWhenMarkdownIsNotAllowed() {
        let output = "**Hello** `there`\n## Heading\n- item"
        XCTAssertEqual(CleanupPostPass.stripMarkdownResidue(output), "Hello there\nHeading\n- item")
        XCTAssertEqual(
            CleanupPostPass.tidy(output, reference: "hello there heading item", markdownAllowed: false),
            "Hello there\nHeading\n- Item")
        XCTAssertEqual(
            CleanupPostPass.tidy(output, reference: "hello there heading item", markdownAllowed: true),
            "**Hello** `there`\n## Heading\n- Item")
    }
}
