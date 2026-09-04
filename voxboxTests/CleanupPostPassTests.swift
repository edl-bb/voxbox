import XCTest

@testable import voxbox

final class CleanupPostPassTests: XCTestCase {

    // MARK: - Markdown residue

    func testStripsBoldBackticksAndHeadingsWhenMarkdownNotAllowed() {
        XCTAssertEqual(
            CleanupPostPass.tidy("# Update\n\n**Hello** there `friend`", reference: "hello there friend", markdownAllowed: false),
            "Update\n\nHello there friend")
    }

    func testKeepsMarkdownWhenAllowed() {
        XCTAssertEqual(
            CleanupPostPass.tidy("**Hello** there", reference: "hello there", markdownAllowed: true),
            "**Hello** there")
    }

    func testListMarkersSurviveEitherWay() {
        let text = "Three things:\n- apples\n- pears"
        XCTAssertEqual(
            CleanupPostPass.tidy(text, reference: "three things apples pears", markdownAllowed: false),
            "Three things:\n- Apples\n- Pears")
    }

    // MARK: - Whitespace

    func testWhitespaceCollapsesButParagraphBreaksSurvive() {
        XCTAssertEqual(
            CleanupPostPass.normaliseWhitespace("  First  line. \n\n\n\n second   paragraph \t\n"),
            "First line.\n\nsecond paragraph")
    }

    // MARK: - Punctuation

    func testDoubledAndMisSpacedPunctuation() {
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("word ,, next .. end"), "word, next. end")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("Is it done?. Wow!. Really?? Yes!!"), "Is it done? Wow! Really? Yes!")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("first ,. second . , third"), "first. second. third")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation(", leading comma"), "leading comma")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("wait... what"), "wait... what", "a real ellipsis stays")
    }

    func testSpaceAfterSentencePunctuationOnlyBeforeANewSentence() {
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("and so on etc.Next point"), "and so on etc. Next point")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("hello,world"), "hello, world")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("open report.pdf and index.html"), "open report.pdf and index.html")
        XCTAssertEqual(CleanupPostPass.normalisePunctuation("costs 2.5 dollars"), "costs 2.5 dollars")
    }

    func testEmailsAndURLsAreLeftAlone() {
        XCTAssertEqual(
            CleanupPostPass.tidy(
                "Email sam.reilly@northwindlabs.com ,, now or see https://staging.voxbox.app/x.y ..",
                reference: "email sam.reilly@northwindlabs.com now or see https://staging.voxbox.app/x.y",
                markdownAllowed: false),
            "Email sam.reilly@northwindlabs.com, now or see https://staging.voxbox.app/x.y.")
    }

    // MARK: - Trailing ellipsis

    func testTrailingEllipsisBecomesAFullStopUnlessDictated() {
        XCTAssertEqual(CleanupPostPass.fixTrailingEllipsis("I think so...", reference: "I think so"), "I think so.")
        XCTAssertEqual(CleanupPostPass.fixTrailingEllipsis("I think so…", reference: "I think so"), "I think so.")
        XCTAssertEqual(CleanupPostPass.fixTrailingEllipsis("wait…", reference: "wait..."), "wait…")
    }

    // MARK: - Casing

    func testSentenceStartsAreCapitalisedWhenLowercase() {
        XCTAssertEqual(
            CleanupPostPass.capitaliseSentenceStarts("hello there. how are you? fine!\n\nnew paragraph"),
            "Hello there. How are you? Fine!\n\nNew paragraph")
        XCTAssertEqual(CleanupPostPass.capitaliseSentenceStarts("iPhone is great. iPhone rocks"), "iPhone is great. iPhone rocks")
        XCTAssertEqual(CleanupPostPass.capitaliseSentenceStarts("sam@x.com is here"), "sam@x.com is here")
        XCTAssertEqual(CleanupPostPass.capitaliseSentenceStarts("items:\n1. apples\n2. pears"), "Items:\n1. Apples\n2. Pears")
    }

    func testAllCapsWordsRevertToTheDictatedForm() {
        XCTAssertEqual(
            CleanupPostPass.tidy(
                "The STAGING build is up so have a PLAY",
                reference: "the staging build is up so have a play", markdownAllowed: false),
            "The staging build is up so have a play")
    }

    func testAllCapsAcronymTheSpeakerDictatedInCapsStays() {
        XCTAssertEqual(
            CleanupPostPass.tidy("Ask the API team", reference: "ask the API team", markdownAllowed: false),
            "Ask the API team")
    }

    func testTitleCaseRunsRevertButSentenceStartStaysCapital() {
        XCTAssertEqual(
            CleanupPostPass.tidy(
                "The Staging Build Is Up so have a play",
                reference: "the staging build is up so have a play", markdownAllowed: false),
            "The staging build is up so have a play")
    }

    func testSingleCapitalisedWordsAreTreatedAsNames() {
        XCTAssertEqual(
            CleanupPostPass.tidy("Hi Priya, just following up", reference: "hi priya just following up", markdownAllowed: false),
            "Hi Priya, just following up")
    }

    func testTheWordIStaysCapitalInsideARun() {
        XCTAssertEqual(
            CleanupPostPass.repairCasing("And I Think We Should go", reference: "and i think we should go"),
            "And I think we should go")
    }

    func testCasingAnomalyFlagsALoudOutput() {
        let shouting = CleanupPostPass.tidyWithDiagnostics(
            "WE SHOULD SHIP THE RELEASE ON THURSDAY AND TELL PRIYA",
            reference: "we should ship the update on thursday and tell priya", markdownAllowed: false)
        // Words the speaker dictated revert; the one they never said stays loud.
        XCTAssertEqual(shouting.text, "We should ship the RELEASE on thursday and tell priya")
        let calm = CleanupPostPass.tidyWithDiagnostics(
            "We should ship the release on Thursday.", reference: "we should ship the release on thursday",
            markdownAllowed: false)
        XCTAssertFalse(calm.casingAnomaly)
    }

    // MARK: - Filler backstop

    func testBackstopStripsFillersPhrasesAndRepeats() {
        XCTAssertEqual(
            CleanupPostPass.stripSpokenFillers(
                "Hey team, quick update. Um, three things. First, the build is up so, you know, have a play. Second, I'm, I'm gonna move the retro. And third, if you've got capacity, uh, shout."),
            "Hey team, quick update. Three things. First, the build is up so have a play. Second, I'm gonna move the retro. And third, if you've got capacity, shout.")
        XCTAssertEqual(CleanupPostPass.stripSpokenFillers("the the second slide"), "the second slide")
        XCTAssertEqual(CleanupPostPass.stripSpokenFillers("following up on, on the thing"), "following up on the thing")
        XCTAssertEqual(CleanupPostPass.stripSpokenFillers("Yes, you know, we should ship."), "Yes, we should ship.")
        XCTAssertEqual(CleanupPostPass.stripSpokenFillers("You know, we should ship."), "we should ship.")
        XCTAssertEqual(
            CleanupPostPass.tidy("You know, we should ship.", reference: "", markdownAllowed: false, spokenFillers: true),
            "We should ship.", "tidy adds the sentence capital")
    }

    func testBackstopLeavesContentAlone() {
        for text in [
            "I mean it this time.",
            "You know what I mean?",
            "It's the kind of thing we do.",
            "I had had enough by then.",
            "I know that that is true.",
            "It was very very late.",
            "Basically it looks like rain.",
        ] {
            XCTAssertEqual(CleanupPostPass.stripSpokenFillers(text), text)
        }
    }

    func testTidyAppliesTheBackstopOnlyWhenAsked() {
        let text = "So, you know, I I think we should ship"
        XCTAssertEqual(
            CleanupPostPass.tidy(text, reference: text, markdownAllowed: false, spokenFillers: true),
            "So I think we should ship")
        XCTAssertEqual(CleanupPostPass.tidy(text, reference: text, markdownAllowed: false), text)
    }

    // MARK: - Pause fragments

    func testPauseFragmentsFoldOntoThePreviousSentence() {
        XCTAssertEqual(
            CleanupPostPass.joinPauseFragments(
                "People talk in faster sections and slower sections. And the pauses land anywhere. But the meaning is continuous. Which is the point."),
            "People talk in faster sections and slower sections, and the pauses land anywhere, but the meaning is continuous, which is the point.")
        XCTAssertEqual(
            CleanupPostPass.joinPauseFragments("Is that right? And then we ship. So that needs work."),
            "Is that right? And then we ship. So that needs work.", "questions and 'So' are left alone")
        XCTAssertEqual(
            CleanupPostPass.joinPauseFragments("Version 2.0. And done.\n\nAnd a new paragraph."),
            "Version 2.0. And done.\n\nAnd a new paragraph.", "digits, short words and paragraph starts are not joined")
        XCTAssertEqual(
            CleanupPostPass.tidy("It was late. And we left.", reference: "", markdownAllowed: false, joinFragments: true),
            "It was late, and we left.")
        XCTAssertEqual(
            CleanupPostPass.tidy("It was late. And we left.", reference: "", markdownAllowed: false),
            "It was late. And we left.", "only when asked (Polish)")
        XCTAssertTrue(CleanupPromptSet.compiled.joinsPauseFragments(.polish))
        XCTAssertFalse(CleanupPromptSet.compiled.joinsPauseFragments(.lightCleanup))
    }

    func testFlattenSentenceBreaksLeavesQuestionsParagraphsAndIAlone() {
        XCTAssertEqual(
            CleanupPostPass.flattenSentenceBreaks("It should be. Based on the model. There are things. I think so."),
            "It should be based on the model there are things I think so.")
        XCTAssertEqual(
            CleanupPostPass.flattenSentenceBreaks("Is that right? Yes it is! Fine. Then we ship.\n\nNew paragraph. Starts here."),
            "Is that right? Yes it is! Fine then we ship.\n\nNew paragraph starts here.")
        XCTAssertEqual(
            CleanupPostPass.flattenSentenceBreaks("Version 2.0. Next e.g. This one."),
            "Version 2.0. Next e.g. This one.", "digits and abbreviations are not sentence ends we can judge")
    }

    // MARK: - Preamble

    func testStripsLabelsWrappersTrailersAndQuotes() {
        let dictation = "Hello there, just following up on the deck."
        let variants = [
            "DICTATION:\n" + dictation,
            "Cleaned dictation: " + dictation,
            "Here is the cleaned text:\n\n" + dictation,
            "Sure! Here's the cleaned dictation: " + dictation,
            "**Here's the tidied text:**\n" + dictation,
            "Output: " + dictation,
            dictation + "\n\nREMEMBER: keep every word. Reply with only the text.",
            "\"" + dictation + "\"",
            "“" + dictation + "”",
            CleanupPromptSet.compiled.role + "\n\n" + dictation,
            CleanupPromptSet.compiled.outputOnly + "\n" + dictation,
        ]
        for variant in variants {
            XCTAssertEqual(CleanupPostPass.stripModelPreamble(variant), dictation, "variant: \(variant.prefix(40))")
        }
    }

    func testKeepsDictationThatMerelyStartsLikeAWrapper() {
        for text in [
            "Here is the meeting agenda for tomorrow morning.",
            "Output from the build looks fine.",
            "Transcript review is at three.",
            "Remember to call mum back.",
        ] {
            XCTAssertEqual(CleanupPostPass.stripModelPreamble(text), text)
        }
    }

    func testRefusalDetection() {
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("I'm sorry, but I can't help with that."))
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("Sorry, I can’t assist with this request."))
        XCTAssertTrue(CleanupPostPass.looksLikeRefusal("As an AI, I cannot do that."))
        XCTAssertFalse(CleanupPostPass.looksLikeRefusal("I can help you tomorrow."))
        XCTAssertFalse(CleanupPostPass.looksLikeRefusal("Sorry I missed your call, ring me back."))
    }
}
