import XCTest

@testable import voxbox

final class TranscriptFormatterServiceTests: XCTestCase {

    // MARK: - Change-ratio guardrail

    func testIdenticalTextScoresZero() {
        XCTAssertEqual(
            TranscriptFormatterService.changeRatio(
                from: "hello world this is a test",
                to: "hello world this is a test"),
            0)
    }

    func testFormattingOnlyEditsScoreZero() {
        // Punctuation, casing and line breaks are invisible to the guardrail.
        XCTAssertEqual(
            TranscriptFormatterService.changeRatio(
                from: "hello world this is a test",
                to: "Hello, world!\n\nThis is a test."),
            0)
    }

    func testFillerRemovalDoesNotConsumeGuardrailBudget() {
        let ratio = TranscriptFormatterService.changeRatio(
            from: "um so I think uh we should ship the release",
            to: "so I think we should ship the release")
        XCTAssertEqual(ratio, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ratio, FormattingIntensity.lightCleanup.maximumChangeRatio)
    }

    func testFalseStartRepeatsDoNotConsumeGuardrailBudget() {
        let ratio = TranscriptFormatterService.changeRatio(
            from: "I was I was going to send the report tomorrow",
            to: "I was going to send the report tomorrow")
        XCTAssertEqual(ratio, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ratio, FormattingIntensity.lightCleanup.maximumChangeRatio)
    }

    func testPolishSizedCleanupStaysInsidePolishBudget() {
        let ratio = TranscriptFormatterService.changeRatio(
            from: "yeah um so i was i was gonna say we should uh probably just go ahead and ship it you know tomorrow if thats okay",
            to: "i was going to say we should ship it tomorrow if that is okay")
        XCTAssertLessThanOrEqual(ratio, FormattingIntensity.polish.maximumChangeRatio)
        XCTAssertGreaterThan(ratio, FormattingIntensity.formatting.maximumChangeRatio)
    }

    func testFullRewriteIsRejectedAtEveryLevel() {
        let ratio = TranscriptFormatterService.changeRatio(
            from: "please send the report to finance before the meeting tomorrow morning",
            to: "the quarterly numbers look great and everyone deserves a holiday")
        for level in FormattingIntensity.allCases {
            XCTAssertGreaterThan(ratio, level.maximumChangeRatio, "\(level) must reject a rewrite")
        }
    }

    func testEmptyInputsScoreZero() {
        XCTAssertEqual(TranscriptFormatterService.changeRatio(from: "", to: ""), 0)
    }

    // MARK: - Intensity scale

    func testIntensityBudgetsIncreaseWithLevel() {
        XCTAssertLessThan(
            FormattingIntensity.formatting.maximumChangeRatio,
            FormattingIntensity.lightCleanup.maximumChangeRatio)
        XCTAssertLessThan(
            FormattingIntensity.lightCleanup.maximumChangeRatio,
            FormattingIntensity.polish.maximumChangeRatio)
    }

    func testDefaultIntensityIsLightCleanup() {
        UserDefaults.standard.removeObject(forKey: TranscriptFormatterService.intensityKey)
        XCTAssertEqual(TranscriptFormatterService.intensity, .lightCleanup)
    }

    func testFeatureIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: TranscriptFormatterService.enabledKey)
        XCTAssertFalse(TranscriptFormatterService.isEnabled)
    }
}
