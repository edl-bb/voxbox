import XCTest

@testable import voxbox

final class TranscriptFormatterServiceTests: XCTestCase {

    private let compiled = CleanupPromptSet.compiled

    // MARK: - Legacy change ratio (reporting only)

    func testIdenticalTextScoresZero() {
        XCTAssertEqual(
            TranscriptFormatterService.changeRatio(
                from: "hello world this is a test",
                to: "hello world this is a test"),
            0)
    }

    func testFormattingOnlyEditsScoreZero() {
        // Punctuation, casing and line breaks are invisible to the ratio.
        XCTAssertEqual(
            TranscriptFormatterService.changeRatio(
                from: "hello world this is a test",
                to: "Hello, world!\n\nThis is a test."),
            0)
    }

    func testFullRewriteScoresHigh() {
        let ratio = TranscriptFormatterService.changeRatio(
            from: "please send the report to finance before the meeting tomorrow morning",
            to: "the quarterly numbers look great and everyone deserves a holiday")
        XCTAssertGreaterThan(ratio, 0.8)
    }

    func testEmptyInputsScoreZero() {
        XCTAssertEqual(TranscriptFormatterService.changeRatio(from: "", to: ""), 0)
    }

    // MARK: - Intensity scale

    func testIntensityDisplayNames() {
        XCTAssertEqual(FormattingIntensity.formatting.displayName, "Basic")
        XCTAssertEqual(FormattingIntensity.lightCleanup.displayName, "Light cleanup")
        XCTAssertEqual(FormattingIntensity.polish.displayName, "Polish")
        XCTAssertEqual(FormattingIntensity.custom.displayName, "Custom")
    }

    func testIntensityBudgetsIncreaseWithLevel() throws {
        XCTAssertLessThan(
            try XCTUnwrap(FormattingIntensity.formatting.maximumChangeRatio),
            try XCTUnwrap(FormattingIntensity.lightCleanup.maximumChangeRatio))
        XCTAssertLessThan(
            try XCTUnwrap(FormattingIntensity.lightCleanup.maximumChangeRatio),
            try XCTUnwrap(FormattingIntensity.polish.maximumChangeRatio))
    }

    func testCustomLevelHasNoGuardrailBudget() {
        XCTAssertNil(FormattingIntensity.custom.maximumChangeRatio)
        XCTAssertNil(FormattingIntensity.custom.budget)
    }

    func testStepDownLaddersEndAtBasic() {
        XCTAssertEqual(FormattingIntensity.polish.stepDownLadder, [.polish, .lightCleanup, .formatting])
        XCTAssertEqual(FormattingIntensity.lightCleanup.stepDownLadder, [.lightCleanup, .formatting])
        XCTAssertEqual(FormattingIntensity.formatting.stepDownLadder, [.formatting])
        XCTAssertEqual(FormattingIntensity.custom.stepDownLadder, [.custom])
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

    // MARK: - Prompt assembly

    func testMarkdownStageOnlyForLightAndPolishAndOnlyWhenOn() {
        for level in FormattingIntensity.allCases {
            let on = level.instructions(includeMarkdownFormatting: true)
            let off = level.instructions(includeMarkdownFormatting: false)
            let expectsMarkdown = level == .lightCleanup || level == .polish
            XCTAssertEqual(
                on.contains(compiled.markdown), expectsMarkdown,
                "\(level) with the toggle on")
            XCTAssertFalse(off.contains(compiled.markdown), "\(level) off must omit the markdown stage")
            XCTAssertTrue(on.contains(compiled.outputOnly), "\(level) must end with the output-only stage")
            XCTAssertTrue(off.contains(compiled.outputOnly), "\(level) must end with the output-only stage")
        }
    }

    func testBasicNeverGetsMarkdownBecauseItMayNotAddCharacters() {
        XCTAssertFalse(compiled.allowsMarkdown(.formatting))
        XCTAssertFalse(compiled.allowsMarkdown(.custom))
        XCTAssertTrue(compiled.allowsMarkdown(.lightCleanup))
        XCTAssertTrue(compiled.allowsMarkdown(.polish))
    }

    func testPolishPromptWithoutMarkdownKeepsTheRest() {
        let polish = FormattingIntensity.polish.instructions(includeMarkdownFormatting: false)
        XCTAssertTrue(polish.contains("sounds like the intended word"))
        XCTAssertTrue(polish.contains("Do NOT add ideas"))
        XCTAssertTrue(polish.contains(compiled.style))
        XCTAssertFalse(polish.contains("Markdown"))
    }

    func testEveryBuiltInPromptAsksForSentenceCase() {
        for level in FormattingIntensity.builtInCases {
            let text = level.instructions(includeMarkdownFormatting: false)
            XCTAssertTrue(text.contains("sentence case"), "\(level) must carry the style rules")
            XCTAssertTrue(text.contains("Copy numbers, email"), "\(level) must protect numbers and emails")
        }
    }

    func testFormattingRequestPutsMarkdownInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"

        for level in [FormattingIntensity.lightCleanup, .polish] {
            let on = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: true)
            XCTAssertTrue(on.instructions.contains(compiled.markdown), "\(level)")
            XCTAssertFalse(on.input.contains(compiled.markdown))
            XCTAssertEqual(on.input, transcript)
            XCTAssertFalse(on.instructionStages.contains(transcript))

            let off = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: false)
            XCTAssertFalse(off.instructions.contains(compiled.markdown))
            XCTAssertEqual(off.input, transcript)
        }
    }

    func testOutputOnlyStageIsAlwaysInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"

        for level in FormattingIntensity.allCases {
            for includeMarkdown in [true, false] {
                let request = TranscriptFormatterService.request(
                    for: transcript, intensity: level, includeMarkdownFormatting: includeMarkdown)
                XCTAssertTrue(request.instructions.contains(compiled.outputOnly), "\(level)")
                XCTAssertFalse(request.input.contains(compiled.outputOnly))
                XCTAssertTrue(request.instructionStages.contains(compiled.outputOnly))
                XCTAssertEqual(request.input, transcript)
            }
        }
    }

    func testUserTurnWrapsTheTranscriptAndRepeatsTheContract() {
        let transcript = "send the deck to sam by thursday"
        for level in FormattingIntensity.builtInCases {
            let request = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: false)
            XCTAssertTrue(request.userPrompt.contains("DICTATION:\n" + transcript), "\(level)")
            XCTAssertTrue(request.userPrompt.hasSuffix(compiled.repeatSuffixes[level] ?? "!"), "\(level)")
            XCTAssertFalse(request.userPrompt.contains(CleanupPromptSet.transcriptPlaceholder))
        }
    }

    // MARK: - Preamble strip (compatibility shim)

    func testStripModelPreambleDropsLeakedMarkdownInstructions() {
        let dictation =
            "You need to update the control gate for the next release tomorrow morning"
        let leaked = compiled.markdown + "\n\n" + dictation
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
            "Here is the tidied dictation:\n",
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
}
