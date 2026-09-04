import XCTest

@testable import voxbox

final class LiveTextPlanningTests: XCTestCase {

    // MARK: - Keystroke replace plan

    func testReplacePlanTrimsSharedPrefixAndSuffixOnWordBoundaries() {
        let plan = KeystrokeReplacePlan.plan(
            typed: "Hello there my friend how are you", cleaned: "Hello there, my friend, how are you")
        XCTAssertEqual(plan.suffixGraphemes, 12, "‘ how are you’ including its leading space")
        XCTAssertEqual(plan.selectGraphemes, 15, "‘there my friend’")
        XCTAssertEqual(plan.replacement, "there, my friend,")
    }

    func testReplacePlanReplacesEverythingWhenTheFirstAndLastWordsChanged() {
        let plan = KeystrokeReplacePlan.plan(typed: "um hello 👋 there", cleaned: "Hello 👋 there, friend.")
        XCTAssertEqual(plan.suffixGraphemes, 0)
        XCTAssertEqual(plan.selectGraphemes, 16)
        XCTAssertEqual(plan.replacement, "Hello 👋 there, friend.")
    }

    func testReplacePlanForPureDeletionHasEmptyReplacement() {
        let plan = KeystrokeReplacePlan.plan(typed: "Hello there um my friend", cleaned: "Hello there my friend")
        XCTAssertEqual(plan.suffixGraphemes, 9)
        XCTAssertEqual(plan.selectGraphemes, 3)
        XCTAssertEqual(plan.replacement, "")
    }

    func testReplacePlanIsANoOpForIdenticalText() {
        let plan = KeystrokeReplacePlan.plan(typed: "Same words", cleaned: "Same words")
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.selectGraphemes, 0)
    }

    // MARK: - Divergence tail

    func testTailBeyondTypedWordsCountsWordsNotCharacters() {
        XCTAssertEqual(AppendPlan.tailBeyondTypedWords(typed: "I want to peak", stable: "I want to peek at the quote"), "at the quote")
        XCTAssertNil(AppendPlan.tailBeyondTypedWords(typed: "I want to peak", stable: "I want to peek"))
        XCTAssertNil(AppendPlan.tailBeyondTypedWords(typed: "one two three", stable: "one two"))
    }

    // MARK: - Early promotion

    private func sample(_ secondsAgo: TimeInterval, _ text: String, now: Date) -> StablePromotion.Sample {
        StablePromotion.Sample(time: now.addingTimeInterval(-secondsAgo), revisable: text)
    }

    func testPromotesWordsUnchangedForAFullWindowExceptTheLastTwo() {
        let now = Date()
        let samples = [
            sample(1.6, "hi jack just", now: now),
            sample(1.2, "hi jack just following", now: now),
            sample(0.7, "hi jack just following up on", now: now),
            sample(0.2, "hi jack just following up on the", now: now),
        ]
        XCTAssertEqual(
            StablePromotion.promotedPrefix(samples: samples, current: "hi jack just following up on the", now: now),
            "hi jack just",
            "the sample from 1.2 s ago anchors the window; its last word ‘following’ is unproven, and the newest two words of the current text stay revisable")
    }

    func testNothingIsPromotedWithoutASecondOfHistory() {
        let now = Date()
        let samples = [sample(0.6, "hi jack just following up", now: now), sample(0.1, "hi jack just following up on", now: now)]
        XCTAssertEqual(StablePromotion.promotedPrefix(samples: samples, current: "hi jack just following up on", now: now), "")
    }

    func testARevisedWordBlocksPromotionFromThatPoint() {
        let now = Date()
        let samples = [
            sample(1.5, "I want to peak at the quote", now: now),
            sample(0.9, "I want to peek at the quote from", now: now),
            sample(0.3, "I want to peek at the quote from the garage", now: now),
        ]
        XCTAssertEqual(
            StablePromotion.promotedPrefix(samples: samples, current: "I want to peek at the quote from the garage", now: now),
            "I want to", "agreement stops at peak/peek")
    }

    func testPartialLastWordIsNotPromoted() {
        let now = Date()
        let samples = [sample(1.4, "hello ther", now: now), sample(0.2, "hello there my friend now", now: now)]
        XCTAssertEqual(
            StablePromotion.promotedPrefix(samples: samples, current: "hello there my friend now", now: now),
            "hello")
    }

    func testDroppingAPromotedPrefixLeavesTheRestForTheHUD() {
        XCTAssertEqual(LiveDictationSession.dropping("hi jack", from: "hi jack just following"), "just following")
        XCTAssertEqual(LiveDictationSession.dropping("", from: "hi jack"), "hi jack")
        XCTAssertEqual(LiveDictationSession.dropping("other", from: "hi jack"), "hi jack")
    }
}
