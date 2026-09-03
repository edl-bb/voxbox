import XCTest

@testable import voxbox

final class CleanupGuardrailTests: XCTestCase {

    private let basic = CleanupPromptSet.compiled.budgets[.formatting]!
    private let light = CleanupPromptSet.compiled.budgets[.lightCleanup]!
    private let polish = CleanupPromptSet.compiled.budgets[.polish]!

    private func evaluate(_ input: String, _ output: String, _ budget: GuardrailBudget) -> GuardrailEvaluation {
        CleanupGuardrail.evaluate(input: input, output: output, budget: budget)
    }

    // MARK: - Tokens

    func testTokensLowercaseExpandContractionsAndJoinThousands() {
        XCTAssertEqual(
            CleanupGuardrail.tokens("I'm gonna send it, it's 12,500 dollars."),
            ["i", "am", "going", "to", "send", "it", "it", "is", "12500", "dollars"])
        XCTAssertEqual(CleanupGuardrail.tokens("We can't and won't"), ["we", "can", "not", "and", "will", "not"])
        XCTAssertEqual(CleanupGuardrail.tokens("Priya’s deck"), ["priya", "deck"], "possessive drops the s")
    }

    func testSpokenNumbersCollapseToTheDigitForm() {
        XCTAssertEqual(CleanupGuardrail.tokens("twelve thousand five hundred dollars"), ["12500", "dollars"])
        XCTAssertEqual(CleanupGuardrail.tokens("$12,500"), ["12500"])
        XCTAssertEqual(CleanupGuardrail.tokens("one hundred and five people"), ["105", "people"])
        XCTAssertEqual(CleanupGuardrail.tokens("twenty percent off"), ["20", "percent", "off"])
        XCTAssertEqual(CleanupGuardrail.tokens("two point five"), ["2", "5"])
        XCTAssertEqual(CleanupGuardrail.tokens("2.5"), ["2", "5"])
        XCTAssertEqual(CleanupGuardrail.tokens("forty-two"), ["42"])
        XCTAssertEqual(CleanupGuardrail.tokens("one of the reasons"), ["1", "of", "the", "reasons"], "both sides normalise the same way")
    }

    func testNumeralRewriteIsFreeAtLight() {
        let result = evaluate(
            "the total was twelve thousand five hundred dollars and twenty percent is due friday",
            "The total was $12,500 and 20% is due Friday.", light)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testContentTokensDropPureFillersAndPhrases() {
        XCTAssertEqual(
            CleanupGuardrail.contentTokens(in: "um so, you know, I mean we should uh ship", lexicon: .compiled),
            ["so", "we", "should", "ship"])
    }

    // MARK: - Free edits

    func testFormattingOnlyEditsCostNothingAndPassBasic() {
        let result = evaluate("hello world this is a test", "Hello, world!\n\nThis is a test.", basic)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.retention, 1)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testDeletingPureFillersIsFree() {
        let result = evaluate(
            "um so I think uh we should ship the release",
            "So I think we should ship the release.", basic)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testDeletingFillerPhrasesAndDeletableWordsIsFree() {
        let result = evaluate(
            "it was, you know, like basically really good, I mean it was great",
            "It was really good, it was great.", light)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.retention, 1, "words the level was told to drop are not lost content")
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testInsertingADeletableWordStillCosts() {
        let result = evaluate("it was really good", "It was like really good.", light)
        XCTAssertEqual(result.cost, 1, "'like' is free to delete, not to add")
    }

    func testCollapsingAFalseStartIsFree() {
        let result = evaluate(
            "I was I was going to send the report to finance tomorrow morning",
            "I was going to send the report to finance tomorrow morning.", light)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testFalseStartWithSharedPrefixIsFree() {
        // "want... wanted": the abandoned token shares four letters with the next kept one.
        let result = evaluate("I want wanted to call you back", "I wanted to call you back.", light)
        XCTAssertEqual(result.cost, 0)
    }

    func testExpandingContractionsIsFree() {
        let result = evaluate("I'm gonna send it and we can't wait", "I am going to send it and we cannot wait.", basic)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.verdict, .accepted)
    }

    // MARK: - Half-price edits

    func testFunctionWordInsertCostsHalf() {
        let result = evaluate("send report tomorrow please", "Send the report tomorrow, please.", light)
        XCTAssertEqual(result.cost, 0.5)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testNearSpellingFixCostsHalf() {
        let result = evaluate("did you recieve the invoice yesterday", "Did you receive the invoice yesterday?", light)
        XCTAssertEqual(result.cost, 0.5)
    }

    // MARK: - Full-price edits

    func testDeletingAContentWordCostsOne() {
        let result = evaluate(
            "please send the quarterly report to finance", "Please send the report to finance.", polish)
        XCTAssertEqual(result.cost, 1)
    }

    func testReplacingAContentWordCostsOne() {
        let result = evaluate("please send the report to finance", "Please send the invoice to finance.", polish)
        XCTAssertEqual(result.cost, 1)
    }

    // MARK: - Budgets

    func testAbsoluteFloorLetsShortTakesAffordEdits() {
        // Eight words at Light: 20% is 1.6 edits, but the floor is 3.
        let input = "please send the quarterly report to finance today"
        let two = evaluate(input, "Please send the monthly report to marketing today.", light)
        XCTAssertEqual(two.cost, 2)
        XCTAssertEqual(two.verdict, .accepted)

        let four = evaluate(input, "Kindly send the monthly report to marketing tonight.", light)
        XCTAssertEqual(four.cost, 4)
        guard case .changeRatioExceeded = four.verdict else {
            return XCTFail("expected changeRatioExceeded, got \(four.verdict)")
        }
    }

    func testBasicRejectsASingleWordSwapOnAShortTake() {
        // Basic's floor is one edit; two content swaps trip it.
        let result = evaluate(
            "please send the report to finance today",
            "Please send the invoice to marketing today.", basic)
        XCTAssertEqual(result.cost, 2)
        XCTAssertFalse(result.verdict.isAccepted)
    }

    func testRetentionFloorVetoesASummaryWhoseDeletionsFitTheBudget() {
        let generous = GuardrailBudget(maxCostRatio: 5, minFreeEdits: 0, minRetention: 0.65)
        let result = evaluate(
            "please review the quarterly budget numbers before the finance meeting on thursday and send your comments to priya by wednesday evening",
            "Please review the budget numbers and send comments to Priya.", generous)
        guard case .retentionTooLow(let kept, let floor) = result.verdict else {
            return XCTFail("expected retentionTooLow, got \(result.verdict)")
        }
        XCTAssertEqual(floor, 0.65)
        XCTAssertLessThan(kept, 0.65)
    }

    func testHalfLengthSummaryIsRejectedAtPolish() {
        let result = evaluate(
            "please review the quarterly budget numbers before the finance meeting on thursday and send your comments to priya by wednesday evening",
            "Please review the budget numbers and send comments to Priya.", polish)
        XCTAssertFalse(result.verdict.isAccepted)
    }

    func testFullRewriteIsRejectedAtEveryBuiltInLevel() {
        for budget in [basic, light, polish] {
            let result = evaluate(
                "please send the report to finance before the meeting tomorrow morning",
                "The quarterly numbers look great and everyone deserves a holiday.", budget)
            XCTAssertFalse(result.verdict.isAccepted, "\(budget) must reject a rewrite")
        }
    }

    // MARK: - Protected tokens

    func testEmailMustSurvive() {
        let result = evaluate(
            "send it to sam.reilly@northwindlabs.com by thursday",
            "Send it to sam.reilly@northwind.com by Thursday.", polish)
        XCTAssertEqual(result.verdict, .protectedTokenAltered("sam.reilly@northwindlabs.com"))
    }

    func testEmailCaseChangeIsFine() {
        let result = evaluate(
            "send it to Sam.Reilly@northwindlabs.com by thursday",
            "Send it to sam.reilly@northwindlabs.com by Thursday.", basic)
        XCTAssertEqual(result.verdict, .accepted)
    }

    func testURLMustSurviveAndTrailingPunctuationIsIgnored() {
        let ok = evaluate(
            "the build is up at https://staging.voxbox.app so have a play",
            "The build is up at https://staging.voxbox.app. So have a play.", basic)
        XCTAssertEqual(ok.verdict, .accepted)

        let broken = evaluate(
            "the build is up at https://staging.voxbox.app so have a play",
            "The build is up at https://staging.voxbox.com so have a play.", polish)
        XCTAssertEqual(broken.verdict, .protectedTokenAltered("https://staging.voxbox.app"))
    }

    func testNumbersCompareWithoutSeparators() {
        let result = evaluate("the total was 12500 dollars", "The total was 12,500 dollars.", basic)
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.cost, 0)
    }

    func testDroppedNumberIsAVeto() {
        let result = evaluate("call me on 0412 345 678 tonight", "Call me on 0412 345 tonight.", polish)
        XCTAssertEqual(result.verdict, .protectedTokenAltered("678"))
    }

    func testProtectedTokenExtraction() {
        let tokens = CleanupGuardrail.protectedTokens(
            in: "Email sam@x.com or see https://x.com/a, total 1,250.50 on 3 May.")
        XCTAssertEqual(
            tokens,
            [.email("sam@x.com"), .url("https://x.com/a"), .number("125050"), .number("3")])
    }

    // MARK: - Degenerate outputs

    func testEmptyOutputAndRefusalAreVetoes() {
        XCTAssertEqual(evaluate("some dictated words here", "   ", light).verdict, .emptyOutput)
        XCTAssertEqual(
            evaluate("some dictated words here", "Sorry, I can't help with that request.", light).verdict,
            .refusal)
    }

    // MARK: - Alignment

    func testAlignedEditsKeepTheTailWhenARunRepeats() {
        let edits = CleanupGuardrail.alignedEdits(["i", "was", "i", "was", "going"], ["i", "was", "going"])
        XCTAssertEqual(edits.filter { if case .delete = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(edits.filter { if case .keep = $0 { return true } else { return false } }.count, 3)
    }

    func testAlignedEditsHandleEmptySides() {
        XCTAssertEqual(CleanupGuardrail.alignedEdits([], ["a"]), [.insert("a")])
        XCTAssertEqual(CleanupGuardrail.alignedEdits(["a"], []), [.delete("a")])
    }

    // MARK: - Legacy ratio

    func testLegacyRatioStillReportsFillerRemovalAsZero() {
        XCTAssertEqual(
            CleanupGuardrail.legacyChangeRatio(
                from: "um so I think uh we should ship the release",
                to: "so I think we should ship the release"),
            0, accuracy: 0.001)
    }
}
