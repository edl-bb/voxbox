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

    func testFillerRemovalScoresProportionally() {
        // 2 fillers removed from 10 words → ratio 0.2, inside light-cleanup's 0.35.
        let ratio = TranscriptFormatterService.changeRatio(
            from: "um so I think uh we should ship the release",
            to: "so I think we should ship the release")
        XCTAssertEqual(ratio, 0.2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ratio, FormattingIntensity.lightCleanup.maximumChangeRatio)
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
