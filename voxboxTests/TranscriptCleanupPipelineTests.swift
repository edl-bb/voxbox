import XCTest

@testable import voxbox

final class TranscriptCleanupPipelineTests: XCTestCase {

    private let raw = "um so I think uh we should ship the release on thursday and tell priya"
    private let lightAnswer = "So I think we should ship the release on Thursday and tell Priya."
    private let summary = "Ship it Thursday."

    // MARK: - Ladder

    func testPolishVetoStepsDownToLight() async {
        let engine = ScriptedCleanupEngine(answers: [.polish: summary, .lightCleanup: lightAnswer])
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        XCTAssertEqual(engine.intensitiesAsked, [.polish, .lightCleanup])
        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, lightAnswer)
        XCTAssertEqual(outcome.attempts.count, 2)
        XCTAssertFalse(outcome.attempts[0].verdict.isAccepted)
        XCTAssertEqual(outcome.attempts[1].verdict, .accepted)
        XCTAssertTrue(outcome.steppedDown)
        XCTAssertTrue(outcome.guardrailTripped)
        XCTAssertEqual(outcome.requested, .polish)
        XCTAssertNil(outcome.skippedReason)
    }

    func testEveryRungVetoedShipsTheDeterministicText() async {
        let engine = ScriptedCleanupEngine { _ in self.summary }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        XCTAssertEqual(engine.intensitiesAsked, [.polish, .lightCleanup, .formatting])
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, raw)
        XCTAssertEqual(outcome.modelInput, raw)
        XCTAssertTrue(outcome.modelRan)
        XCTAssertFalse(outcome.steppedDown, "nothing landed, so nothing stepped down")
    }

    func testLightRequestedNeverTriesPolish() async {
        let engine = ScriptedCleanupEngine { _ in self.summary }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        _ = await pipeline.clean(raw: raw, plan: .test(.light))

        XCTAssertEqual(engine.intensitiesAsked, [.lightCleanup, .formatting])
    }

    func testStepDownDisabledMakesOneAttempt() async {
        let engine = ScriptedCleanupEngine { _ in self.summary }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish, stepDown: false))

        XCTAssertEqual(engine.intensitiesAsked, [.polish])
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.attempts.count, 1)
    }

    func testRefusalMovesToTheNextRung() async {
        let engine = ScriptedCleanupEngine(answers: [
            .polish: "Sorry, I can't help with that.", .lightCleanup: lightAnswer,
        ])
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        XCTAssertEqual(outcome.attempts.first?.verdict, .refusal)
        XCTAssertEqual(outcome.landed, .lightCleanup)
    }

    func testContentFilterAbortsTheLadder() async {
        let engine = ScriptedCleanupEngine { _ in throw CleanupEngineError.contentFilter }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        XCTAssertEqual(engine.intensitiesAsked, [.polish], "no rung can help when the input is rejected")
        XCTAssertEqual(outcome.attempts.count, 1)
        XCTAssertEqual(outcome.attempts.first?.verdict, .appleContentFilter)
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, raw)
        XCTAssertEqual(outcome.error, "Apple Intelligence declined this text.")
    }

    func testEngineErrorMovesToTheNextRung() async {
        let engine = ScriptedCleanupEngine { request in
            if request.intensity == .polish { throw ScriptedCleanupEngine.Failure(message: "boom") }
            return self.lightAnswer
        }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        guard case .engineError(let message)? = outcome.attempts.first?.verdict else {
            return XCTFail("expected engineError, got \(String(describing: outcome.attempts.first?.verdict))")
        }
        XCTAssertTrue(message.contains("boom"))
        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertNotNil(outcome.error)
    }

    // MARK: - Fallback engine

    func testLocalModelFailureRetriesOnTheSystemModel() async {
        let local = ScriptedCleanupEngine(displayName: "Qwen 3 1.7B") { _ in
            throw ScriptedCleanupEngine.Failure(message: "weights missing")
        }
        let system = ScriptedCleanupEngine(displayName: "Apple Intelligence") { _ in self.lightAnswer }
        let selected = PostProcessingModel.catalog.first { $0.variant == "mlx-qwen3-1.7b-4bit" }!
        let pipeline = TranscriptCleanupPipeline.scripted(engine: local, fallback: system, selected: selected)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.light))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.engineName, "Apple Intelligence")
        XCTAssertEqual(outcome.requestedEngineName, selected.name)
        XCTAssertTrue(outcome.fellBackToSystemModel)
        XCTAssertEqual(local.requests.count, 1)
        XCTAssertEqual(system.requests.count, 1)
    }

    func testNoAvailableEngineSkipsTheModelStage() async {
        let engine = ScriptedCleanupEngine(isAvailable: false) { _ in self.lightAnswer }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.light))

        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertFalse(outcome.modelRan)
        XCTAssertEqual(outcome.output, raw)
        XCTAssertNotNil(outcome.skippedReason)
    }

    // MARK: - Gates

    func testTooShortSkipsTheModel() async {
        let engine = ScriptedCleanupEngine { _ in self.lightAnswer }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: "hello there priya", plan: .test(.light, minimumWordCount: 8))

        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertEqual(outcome.output, "Hello there priya", "instant pass only: a sentence capital, nothing else")
        XCTAssertTrue(outcome.skippedReason?.contains("Too short") == true)
    }

    func testShortTakesStillGetTheInstantPassAtLight() async {
        let engine = ScriptedCleanupEngine { _ in self.lightAnswer }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let light = await pipeline.clean(
            raw: "um so, you know, I I owe you twenty dollars", plan: .test(.light, minimumWordCount: 12))
        XCTAssertTrue(engine.requests.isEmpty, "still no model call")
        XCTAssertEqual(light.output, "So I owe you $20")
        XCTAssertNil(light.landed)
        XCTAssertTrue(light.skippedReason?.contains("instant cleanup only") == true)

        let basic = await pipeline.clean(raw: "um so I I owe you twenty dollars", plan: .test(.basic, minimumWordCount: 12))
        XCTAssertEqual(basic.output, "um so I I owe you twenty dollars", "Basic never edits words")
    }

    func testOffSkipsTheModel() async {
        let engine = ScriptedCleanupEngine { _ in self.lightAnswer }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.off))

        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertEqual(outcome.skippedReason, "Cleanup is off.")
        XCTAssertEqual(outcome.output, raw)
    }

    func testPreviewIgnoresTheMinimumWordCount() async {
        let engine = ScriptedCleanupEngine { _ in "Hello there, Priya." }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await TranscriptCleanupPreview.preview(
            text: "hello there priya", option: .basic, includeMarkdown: false, autoEdit: false, pipeline: pipeline)

        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(outcome.output, "Hello there, Priya.")
        XCTAssertEqual(outcome.landed, .formatting)
    }

    // MARK: - Chain order

    func testAutoEditRunsBeforeTheModel() async {
        let engine = ScriptedCleanupEngine { $0.input }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: "um so I think we should ship", plan: .test(.basic, autoEdit: true))

        XCTAssertEqual(outcome.rawInput, "um so I think we should ship")
        XCTAssertEqual(outcome.modelInput, "So I think we should ship")
        XCTAssertEqual(engine.requests.first?.input, "So I think we should ship")
    }

    func testAustralianSpellingIsReappliedAfterTheModel() async {
        let engine = ScriptedCleanupEngine { _ in "We need to organize the color palette." }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(
            raw: "we need to organise the colour palette", plan: .test(.light, language: "en-AU"))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, "We need to organise the colour palette.")
        XCTAssertTrue(
            engine.requests.first?.instructionStages.contains(CleanupPromptSet.compiled.australianSpelling) == true)
    }

    func testSmartTrailingPunctuationRunsLast() async {
        let engine = ScriptedCleanupEngine { _ in "roy@example.com." }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: "roy@example.com", plan: .test(.basic))

        XCTAssertEqual(outcome.landed, .formatting)
        XCTAssertEqual(outcome.output, "roy@example.com")
    }

    func testPreambleIsStrippedAndTidiedBeforeTheGuardrail() async {
        let engine = ScriptedCleanupEngine { _ in
            "Here is the cleaned text:\n\n**" + self.lightAnswer + "**\n\nREMEMBER: keep every word."
        }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.light))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, lightAnswer)
        XCTAssertEqual(outcome.attempts.first?.tidiedOutput, lightAnswer)
        XCTAssertTrue(outcome.attempts.first?.rawOutput.contains("REMEMBER") == true, "raw output is kept for the tuner")
    }

    // MARK: - Requests

    func testBasicNeverGetsTheMarkdownStageEvenWhenEnabled() async {
        let engine = ScriptedCleanupEngine { $0.input }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        _ = await pipeline.clean(raw: raw, plan: .test(.basic, markdown: true))
        _ = await pipeline.clean(raw: raw, plan: .test(.light, markdown: true))

        let markdown = CleanupPromptSet.compiled.markdown
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertFalse(engine.requests[0].instructionStages.contains(markdown))
        XCTAssertTrue(engine.requests[1].instructionStages.contains(markdown))
    }

    func testPolishSeesFlattenedSentenceBreaksAndLightDoesNot() async {
        let engine = ScriptedCleanupEngine { $0.input }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)
        let text = "It should be. Based on the model. There are things I think so."

        let polish = await pipeline.clean(raw: text, plan: .test(.polish, stepDown: false))
        XCTAssertEqual(engine.requests.last?.input, "It should be based on the model there are things I think so.")
        XCTAssertEqual(polish.modelInput, text, "History and diagnostics keep the engine text")
        XCTAssertEqual(polish.landed, .polish, "punctuation-only differences cost nothing")

        _ = await pipeline.clean(raw: text, plan: .test(.light, stepDown: false))
        XCTAssertEqual(engine.requests.last?.input, text)
    }

    func testCustomRulesetIsVerbatimWrappedAndUngoverned() async {
        let ruleset = CustomCleanupRuleset(name: "Haiku", instructions: "Rewrite the dictation as a haiku.", temperature: 0.6)
        let haiku = "Ship it on Thursday.\nPriya waits for the release.\nThe team breathes at last."
        let engine = ScriptedCleanupEngine { _ in haiku }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.custom(ruleset)))

        let request = engine.requests[0]
        XCTAssertEqual(request.instructionStages, ["Rewrite the dictation as a haiku."])
        XCTAssertEqual(request.intensity, .custom)
        XCTAssertNil(request.budget)
        XCTAssertEqual(request.temperature, 0.6, accuracy: 0.0001)
        XCTAssertTrue(request.userPrompt.contains("DICTATION:\n" + raw))
        XCTAssertFalse(request.userPrompt.contains("REMEMBER:"))

        XCTAssertEqual(outcome.attempts.first?.verdict, .notGoverned)
        XCTAssertEqual(outcome.landed, .custom)
        XCTAssertEqual(outcome.output, haiku)
        XCTAssertNil(outcome.changeRatio)
    }

    func testCustomWithoutAUsableRulesetDegradesToGovernedLight() {
        let empty = CustomCleanupRuleset(name: "Empty", instructions: "   ")
        XCTAssertEqual(CleanupOption(intensity: .custom, ruleset: empty), .light)
        XCTAssertEqual(CleanupOption(intensity: .custom, ruleset: nil), .light)
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: .test(.custom(empty))), [.custom])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: .test(.light)), [.lightCleanup, .formatting])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: .test(.light, stepDown: false)), [.lightCleanup])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: .test(.off)), [])
    }

    // MARK: - Recording

    func testRealTakesRecordTheOutcomeAndPreviewsDoNot() async {
        let engine = ScriptedCleanupEngine { $0.input }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)
        let marker = "marker \(UUID().uuidString) we should ship the release on thursday"

        let preview = await pipeline.clean(raw: marker, plan: .test(.light, isPreview: true))
        XCTAssertNotEqual(TranscriptFormatterService.shared.lastOutcome?.rawInput, marker)
        XCTAssertEqual(preview.landed, .lightCleanup)

        _ = await pipeline.clean(raw: marker, plan: .test(.light, isPreview: false))
        XCTAssertEqual(TranscriptFormatterService.shared.lastOutcome?.rawInput, marker)
    }

    func testOutcomeDurationsAreRecorded() async {
        let engine = ScriptedCleanupEngine { _ in self.lightAnswer }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)

        let outcome = await pipeline.clean(raw: raw, plan: .test(.light))

        XCTAssertGreaterThanOrEqual(outcome.totalDurationMs, 0)
        XCTAssertEqual(outcome.attempts.count, 1)
        XCTAssertGreaterThanOrEqual(outcome.attempts[0].durationMs, 0)
    }

    // MARK: - Compare

    func testCompareReportsEachOptionInOrder() async {
        let engine = ScriptedCleanupEngine { $0.input }
        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine)
        var seen: [CleanupOption] = []

        for option in [CleanupOption.basic, .light, .polish] {
            let outcome = await TranscriptCleanupPreview.preview(
                text: raw, option: option, includeMarkdown: false, autoEdit: false, pipeline: pipeline)
            XCTAssertEqual(outcome.requested, option)
            seen.append(option)
        }
        XCTAssertEqual(seen, [.basic, .light, .polish])
        XCTAssertEqual(engine.intensitiesAsked, [.formatting, .lightCleanup, .polish])
    }
}
