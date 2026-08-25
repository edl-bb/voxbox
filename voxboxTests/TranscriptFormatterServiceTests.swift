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

    func testIntensityDisplayNames() {
        XCTAssertEqual(FormattingIntensity.formatting.displayName, "Basic")
        XCTAssertEqual(FormattingIntensity.lightCleanup.displayName, "Light cleanup")
        XCTAssertEqual(FormattingIntensity.polish.displayName, "Polish")
    }

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

    func testMarkdownFormattingDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: TranscriptFormatterService.markdownFormattingKey)
        XCTAssertTrue(TranscriptFormatterService.isMarkdownFormattingEnabled)
    }

    func testMarkdownStageIncludedOnlyWhenToggleIsOn() {
        let fragment = FormattingPromptStage.markdownFormatting
        let outputOnly = FormattingPromptStage.outputTranscriptOnly
        for level in FormattingIntensity.allCases {
            let on = level.instructions(includeMarkdownFormatting: true)
            let off = level.instructions(includeMarkdownFormatting: false)
            XCTAssertTrue(on.contains(fragment), "\(level) on must include the markdown stage")
            XCTAssertFalse(off.contains(fragment), "\(level) off must omit the markdown stage")
            XCTAssertTrue(on.contains(outputOnly), "\(level) on must include the output-only stage")
            XCTAssertTrue(off.contains(outputOnly), "\(level) off must include the output-only stage")
        }
    }

    func testPolishPromptWithoutMarkdownKeepsTheRest() {
        let polish = FormattingIntensity.polish.instructions(includeMarkdownFormatting: false)
        XCTAssertTrue(polish.contains("phonetically similar"))
        XCTAssertTrue(polish.contains("polish the delivery, never the message."))
        XCTAssertFalse(polish.contains("markdown formatting"))
    }

    func testFormattingRequestPutsMarkdownInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"
        let fragment = FormattingPromptStage.markdownFormatting

        for level in FormattingIntensity.allCases {
            let on = TranscriptFormatterService.request(
                for: transcript,
                intensity: level,
                includeMarkdownFormatting: true)
            XCTAssertTrue(
                on.instructions.contains(fragment),
                "\(level) instructions must include the markdown stage")
            XCTAssertFalse(
                on.input.contains(fragment),
                "\(level) input must not include the markdown stage")
            XCTAssertEqual(on.input, transcript)
            XCTAssertFalse(on.instructionStages.contains(transcript))

            let off = TranscriptFormatterService.request(
                for: transcript,
                intensity: level,
                includeMarkdownFormatting: false)
            XCTAssertFalse(off.instructions.contains(fragment))
            XCTAssertEqual(off.input, transcript)
        }
    }

    func testStripModelPreambleDropsLeakedMarkdownInstructions() {
        let dictation =
            "You need to update the control gate for the next release tomorrow morning"
        let leaked =
            FormattingPromptStage.markdownFormatting + "\n\n" + dictation
        XCTAssertEqual(TranscriptFormatterService.stripModelPreamble(leaked), dictation)
        XCTAssertEqual(TranscriptFormatterService.stripModelPreamble(dictation), dictation)
    }

    func testStripModelPreambleDropsBoldCleanedTextWrapper() {
        let dictation =
            "You need to update the control gate for the next release tomorrow morning"
        let wrappers = [
            "**Here is the cleaned text:**\n\n",
            "Here is the cleaned text:\n",
            "Here's the cleaned transcript:\n",
            "Sure, here is the cleaned text:\n",
            "Cleaned text: ",
        ]
        for prefix in wrappers {
            XCTAssertEqual(
                TranscriptFormatterService.stripModelPreamble(prefix + dictation),
                dictation,
                "should strip wrapper \(prefix)")
        }
    }

    func testStripModelPreambleKeepsNormalOpeningSentence() {
        let dictation = "Here is the meeting agenda for tomorrow morning."
        XCTAssertEqual(TranscriptFormatterService.stripModelPreamble(dictation), dictation)
        let other = "Please send the report to finance before the meeting tomorrow."
        XCTAssertEqual(TranscriptFormatterService.stripModelPreamble(other), other)
    }

    func testOutputOnlyStageIsAlwaysInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"
        let fragment = FormattingPromptStage.outputTranscriptOnly

        for level in FormattingIntensity.allCases {
            for includeMarkdown in [true, false] {
                let request = TranscriptFormatterService.request(
                    for: transcript,
                    intensity: level,
                    includeMarkdownFormatting: includeMarkdown)
                XCTAssertTrue(
                    request.instructions.contains(fragment),
                    "\(level) instructions must include the output-only stage")
                XCTAssertFalse(
                    request.input.contains(fragment),
                    "\(level) input must not include the output-only stage")
                XCTAssertTrue(request.instructionStages.contains(fragment))
                XCTAssertEqual(request.input, transcript)
            }
        }
    }
}
