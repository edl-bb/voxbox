import XCTest

@testable import voxbox

/// The asymmetric edit budget: fillers and false starts are free, grammar
/// normalisation is free, function words and near-spellings are half price,
/// and a summary trips the retention floor even when each edit is cheap.
final class CleanupGuardrailTests: XCTestCase {

    private let compiled = CleanupPromptSet.compiled
    private var basic: GuardrailBudget { compiled.budgets[.formatting]! }
    private var light: GuardrailBudget { compiled.budgets[.lightCleanup]! }
    private var polish: GuardrailBudget { compiled.budgets[.polish]! }

    private func evaluate(_ input: String, _ output: String, _ budget: GuardrailBudget) -> GuardrailEvaluation {
        CleanupGuardrail.evaluate(input: input, output: output, budget: budget)
    }

    // MARK: - Tokens

    func testTokensLowercaseExpandContractionsAndDropThousandsSeparators() {
        XCTAssertEqual(
            CleanupGuardrail.tokens("I'm gonna send 12,500 dollars, it’s fine"),
            ["i", "am", "going", "to", "send", "12500", "dollars", "it", "is", "fine"])
        XCTAssertEqual(CleanupGuardrail.tokens("they're we've you'll she'd don't"),
            ["they", "are", "we", "have", "you", "will", "she", "would", "do", "not"])
        XCTAssertEqual(CleanupGuardrail.tokens("Priya's deck"), ["priya", "deck"])
    }

    func testContentTokensDropPureFillersAndFillerPhrases() {
        let tokens = CleanupGuardrail.contentTokens(
            in: "um so I think, you know, we should sort of ship it, uh, today",
            lexicon: .compiled)
        XCTAssertEqual(tokens, ["so", "i", "think", "we", "should", "ship", "it", "today"])
    }

    // MARK: - Free edits

    func testIdenticalTextIsAcceptedAtZeroCost() {
        let result = evaluate("hello world this is a test", "Hello world, this is a test.", basic)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.retention, 1)
    }

    func testDroppingFillersCostsNothingEvenUnderBasic() {
        let result = evaluate(
            "um so I think uh we should you know ship the release",
            "So I think we should ship the release.", basic)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.cost, 0)
    }

    func testDroppingDeletableWordsIsFreeButInsertingThemIsNot() {
        let dropped = evaluate(
            "it was like really good and basically we all enjoyed the show",
            "It was really good and we all enjoyed the show.", light)
        XCTAssertEqual(dropped.cost, 0)
        XCTAssertEqual(dropped.retention, 1, "free deletions do not count against retention")
        XCTAssertEqual(dropped.verdict, .accepted)

        let inserted = evaluate("it was really good", "It was, like, really good.", light)
        XCTAssertEqual(inserted.cost, 1)
    }

    func testAdjacentRepeatIsFree() {
        let result = evaluate("I was I was going to send it", "I was going to send it.", basic)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testFalseStartWithSharedStemIsFree() {
        let result = evaluate("I want wanted to go home", "I wanted to go home.", basic)
        XCTAssertEqual(result.cost, 0)
    }

    func testContractionsAreNormalisedBeforeComparing() {
        let result = evaluate("I'm gonna send it and we can't wait", "I am going to send it and we cannot wait.", basic)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    // MARK: - Half-price edits

    func testInsertingAFunctionWordCostsHalf() {
        let result = evaluate("send report to finance", "Send the report to finance.", light)
        XCTAssertEqual(result.cost, 0.5)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testNearSpellingFixCostsHalf() {
        let result = evaluate(
            "legal should see it for there review", "Legal should see it for their review.", polish)
        XCTAssertEqual(result.cost, 0.5)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testUnrelatedSubstitutionCostsOne() {
        let result = evaluate("send the deck on friday", "Send the deck on monday.", polish)
        XCTAssertEqual(result.cost, 1)
    }

    // MARK: - Vetoes

    private let longDictation =
        "um so I think uh we should ship the release on Thursday and then tell the customers about the new pricing page"
    private let summary = "Release Thursday; announce pricing."

    func testASummaryIsRejectedAtEveryBuiltInLevel() {
        for (level, budget) in compiled.budgets {
            let result = evaluate(longDictation, summary, budget)
            XCTAssertFalse(result.verdict.isAccepted, "\(level) must reject a summary")
            XCTAssertLessThan(result.retention, 0.5)
        }
    }

    func testFaithfulCleanupOfTheSameDictationPassesLight() {
        let result = evaluate(
            longDictation,
            "So I think we should ship the release on Thursday and then tell the customers about the new pricing page.",
            light)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.cost, 0)
    }

    func testRetentionFloorCatchesCheapDeletionsThatAddUpToASummary() {
        // Eighteen function words at half price cost 8.5, inside Polish's
        // allowance of 9; the floor still refuses an output that kept one.
        let result = evaluate(
            "the a an of to in on and or is are was be it that at for with", "It.", polish)
        XCTAssertEqual(result.cost, 8.5)
        guard case .retentionTooLow(let kept, let floor) = result.verdict else {
            return XCTFail("expected retentionTooLow, got \(result.verdict)")
        }
        XCTAssertLessThan(kept, floor)
    }

    func testChattyShortTakeIsNotVetoedForDroppingItsFillers() {
        // The old retention rule counted every deletion, so a short take made
        // mostly of fillers tripped Light even at zero cost.
        let result = evaluate(
            "so like I just think we should basically ship it",
            "I think we should ship it.", light)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testShortTakesGetTheAbsoluteFreeEditFloor() {
        // Six content tokens at 5 % would allow 0.3 edits; the floor of one
        // lets Basic still fix one word.
        XCTAssertEqual(basic.minFreeEdits, 1)
        let result = evaluate("send it to sam on friday", "Send it to sam on monday.", basic)
        XCTAssertEqual(result.cost, 1)
        XCTAssertEqual(result.verdict, .accepted)
        let twoEdits = evaluate("send it to sam on friday", "Post it to sam on monday.", basic)
        XCTAssertEqual(twoEdits.cost, 2)
        guard case .changeRatioExceeded = twoEdits.verdict else {
            return XCTFail("expected changeRatioExceeded, got \(twoEdits.verdict)")
        }
    }

    func testEmptyOutputAndRefusalsAreVetoed() {
        XCTAssertEqual(evaluate("hello there friend", "   ", light).verdict, .emptyOutput)
        XCTAssertEqual(
            evaluate("hello there friend", "Sorry, I can't help with that request.", light).verdict,
            .refusal)
    }

    // MARK: - Protected tokens

    func testProtectedTokensAreExtracted() {
        let tokens = CleanupGuardrail.protectedTokens(
            in: "Email sam.reilly@northwindlabs.com, see https://staging.voxbox.app. Total 12,500 by 2pm.")
        XCTAssertTrue(tokens.contains(.email("sam.reilly@northwindlabs.com")))
        XCTAssertTrue(tokens.contains(.url("https://staging.voxbox.app")))
        XCTAssertTrue(tokens.contains(.number("12500")))
        XCTAssertTrue(tokens.contains(.number("2")))
    }

    func testNumbersMaySwapSeparatorsButNotDigits() {
        let same = evaluate("put 12,500 into the tracker", "Put 12500 into the tracker.", basic)
        XCTAssertEqual(same.verdict, .accepted)
        let altered = evaluate("put 12,500 into the tracker", "Put 12,000 into the tracker.", polish)
        XCTAssertEqual(altered.verdict, .protectedTokenAltered("12500"))
    }

    func testEmailsAndURLsMustSurviveVerbatim() {
        let email = evaluate(
            "send it to sam@northwindlabs.com today please",
            "Send it to sam@northwind.com today please.", polish)
        XCTAssertEqual(email.verdict, .protectedTokenAltered("sam@northwindlabs.com"))

        let url = evaluate(
            "the build is at https://staging.voxbox.app so have a play",
            "The build is at https://staging.voxbox.app, so have a play.", light)
        XCTAssertEqual(url.verdict, .accepted)
    }

    func testProtectedRangesCoverEmailsAndURLsOnly() {
        let text = "mail sam@x.io or open www.voxbox.app now"
        let ranges = CleanupGuardrail.protectedRanges(in: text)
        let ns = text as NSString
        XCTAssertEqual(Set(ranges.map { ns.substring(with: $0) }), ["sam@x.io", "www.voxbox.app"])
    }

    // MARK: - Alignment

    func testAlignedEditsReportKeepDeleteInsertSubstitute() {
        let edits = CleanupGuardrail.alignedEdits(["a", "b", "c"], ["a", "x", "c", "d"])
        XCTAssertEqual(edits, [.keep("a"), .substitute("b", "x"), .keep("c"), .insert("d")])
        XCTAssertEqual(CleanupGuardrail.alignedEdits([], ["a"]), [.insert("a")])
        XCTAssertEqual(CleanupGuardrail.alignedEdits(["a"], []), [.delete("a")])
    }

    func testSimilarWordsNeedASharedStemOrTwoCharacterDistance() {
        XCTAssertTrue(CleanupGuardrail.areSimilarWords("there", "their"))
        XCTAssertTrue(CleanupGuardrail.areSimilarWords("pasting", "pacing"))
        XCTAssertTrue(CleanupGuardrail.areSimilarWords("wanted", "wants"))
        XCTAssertFalse(CleanupGuardrail.areSimilarWords("peak", "peek"))
        XCTAssertFalse(CleanupGuardrail.areSimilarWords("friday", "monday"))
    }
}
