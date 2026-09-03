import FoundationModels
import XCTest

@testable import voxbox

final class TranscriptFormatterServiceTests: XCTestCase {

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

    func testStepDownLadders() {
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

    func testMarkdownStageOnlyForLightAndPolishWhenToggleIsOn() {
        let fragment = CleanupPromptSet.compiled.markdown
        let outputOnly = CleanupPromptSet.compiled.outputOnly
        for level in [FormattingIntensity.lightCleanup, .polish] {
            let on = level.instructions(includeMarkdownFormatting: true)
            let off = level.instructions(includeMarkdownFormatting: false)
            XCTAssertTrue(on.contains(fragment), "\(level) on must include the markdown stage")
            XCTAssertFalse(off.contains(fragment), "\(level) off must omit the markdown stage")
            XCTAssertTrue(on.contains(outputOnly))
            XCTAssertTrue(off.contains(outputOnly))
        }
        for level in [FormattingIntensity.formatting, .custom] {
            XCTAssertFalse(
                level.instructions(includeMarkdownFormatting: true).contains(fragment),
                "\(level) is told to change no word, so it never gets the markdown stage")
        }
    }

    func testEveryBuiltInLevelCarriesRoleStyleAndOutputOnly() {
        let set = CleanupPromptSet.compiled
        for level in FormattingIntensity.builtInCases {
            let stages = level.instructionStages(includeMarkdownFormatting: false)
            XCTAssertEqual(stages.first, set.role)
            XCTAssertTrue(stages.contains(set.style))
            XCTAssertEqual(stages.last, set.outputOnly)
            XCTAssertFalse(stages.contains(set.australianSpelling), "AU stage only for en-AU")
        }
    }

    func testAustralianSpellingStageOnlyForEnAU() {
        let set = CleanupPromptSet.compiled
        XCTAssertTrue(
            FormattingIntensity.lightCleanup.instructionStages(includeMarkdownFormatting: false, language: "en-AU")
                .contains(set.australianSpelling))
        XCTAssertFalse(
            FormattingIntensity.lightCleanup.instructionStages(includeMarkdownFormatting: false, language: "en")
                .contains(set.australianSpelling))
    }

    func testPolishPromptWithoutMarkdownKeepsTheRest() {
        let polish = FormattingIntensity.polish.instructions(includeMarkdownFormatting: false)
        XCTAssertTrue(polish.contains("sounds like the intended word"))
        XCTAssertTrue(polish.contains("Do NOT add ideas"))
        XCTAssertFalse(polish.contains("Markdown"))
    }

    func testFormattingRequestPutsMarkdownInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"
        let fragment = CleanupPromptSet.compiled.markdown

        for level in [FormattingIntensity.lightCleanup, .polish] {
            let on = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: true)
            XCTAssertTrue(on.instructions.contains(fragment))
            XCTAssertFalse(on.input.contains(fragment))
            XCTAssertEqual(on.input, transcript)
            XCTAssertFalse(on.instructionStages.contains(transcript))

            let off = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: false)
            XCTAssertFalse(off.instructions.contains(fragment))
            XCTAssertEqual(off.input, transcript)
        }
    }

    func testUserPromptWrapsTranscriptAndRepeatsTheRule() {
        let transcript = "please send the report to finance tomorrow morning"
        for level in FormattingIntensity.builtInCases {
            let request = TranscriptFormatterService.request(
                for: transcript, intensity: level, includeMarkdownFormatting: false)
            XCTAssertTrue(request.userPrompt.contains("DICTATION:\n" + transcript), "\(level)")
            XCTAssertTrue(request.userPrompt.contains("REMEMBER:"), "\(level) repeats its rule")
            XCTAssertEqual(request.input, transcript, "input stays the bare dictation")
            XCTAssertEqual(request.intensity, level)
            XCTAssertEqual(request.temperature, 0)
            XCTAssertEqual(request.budget, level.budget)
        }
    }

    func testOutputOnlyStageIsAlwaysInInstructionsNotInput() {
        let transcript =
            "You need to update the control gate for the next release tomorrow morning"
        let fragment = CleanupPromptSet.compiled.outputOnly

        for level in FormattingIntensity.allCases {
            for includeMarkdown in [true, false] {
                let request = TranscriptFormatterService.request(
                    for: transcript, intensity: level, includeMarkdownFormatting: includeMarkdown)
                XCTAssertTrue(request.instructions.contains(fragment), "\(level)")
                XCTAssertFalse(request.input.contains(fragment), "\(level)")
                XCTAssertTrue(request.instructionStages.contains(fragment))
                XCTAssertEqual(request.input, transcript)
            }
        }
    }

    // MARK: - Preamble shim

    func testStripModelPreambleDropsLeakedMarkdownInstructions() {
        let dictation =
            "You need to update the control gate for the next release tomorrow morning"
        let leaked = CleanupPromptSet.compiled.markdown + "\n\n" + dictation
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

    // MARK: - Engine options

    func testBuiltInLevelsUseGreedySamplingAndCustomKeepsTemperature() {
        let deterministic = TranscriptFormatterService.request(
            for: "text", intensity: .lightCleanup, includeMarkdownFormatting: false)
        XCTAssertNil(
            AppleIntelligenceCleanupEngine.generationOptions(for: deterministic).temperature,
            "temperature 0 requests greedy sampling, not a temperature")

        let warm = TranscriptFormatterService.request(
            for: "text",
            ruleset: CustomCleanupRuleset(name: "Warm", instructions: "Rewrite.", temperature: 0.7))
        XCTAssertEqual(
            AppleIntelligenceCleanupEngine.generationOptions(for: warm).temperature, 0.7)
    }
}
