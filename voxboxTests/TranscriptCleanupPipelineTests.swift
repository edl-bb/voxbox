import XCTest

@testable import voxbox

/// A cleanup engine that answers from a closure, so the pipeline's ladder,
/// fallback and guardrail behaviour can be exercised without a model.
private struct ScriptedCleanupEngine: CleanupEngine {
    var isAvailable: Bool = true
    var displayName: String = "Scripted"
    var respond: (FormattingRequest) throws -> String

    func cleanup(_ request: FormattingRequest) async throws -> String {
        try respond(request)
    }
}

private struct FailingLocalEngine: CleanupEngine {
    struct Boom: Error {}
    var isAvailable: Bool = true
    var displayName: String = "Broken local model"
    func cleanup(_ request: FormattingRequest) async throws -> String { throw Boom() }
}

@MainActor
final class TranscriptCleanupPipelineTests: XCTestCase {

    private let dictation =
        "um so I think uh we should ship the release on Thursday and then tell the customers about the new pricing page"
    private let faithful =
        "So I think we should ship the release on Thursday and then tell the customers about the new pricing page."
    private let summary = "Release Thursday; announce pricing."

    private func plan(_ option: CleanupOption, allowStepDown: Bool = true) -> CleanupPlan {
        var plan = CleanupPlan(
            option: option, includeMarkdown: false, language: "auto", autoEditEnabled: false,
            minimumWordCount: 0, allowStepDown: allowStepDown, isPreview: true, promptSet: .compiled)
        plan.applyDictionary = false
        plan.smartTrailingPunctuation = false
        return plan
    }

    private func pipeline(
        engine: CleanupEngine,
        fallback: CleanupEngine = ScriptedCleanupEngine(isAvailable: false) { _ in "" },
        model: PostProcessingModel = PostProcessingModel.catalog[0]
    ) -> TranscriptCleanupPipeline {
        let pipeline = TranscriptCleanupPipeline()
        pipeline.engineProvider = { _ in engine }
        pipeline.fallbackEngine = { fallback }
        pipeline.selectedModel = { model }
        return pipeline
    }

    // MARK: - Ladder

    func testLightCleanupIsAcceptedWhenTheModelStaysFaithful() async {
        var seen: [FormattingIntensity] = []
        let engine = ScriptedCleanupEngine { request in
            seen.append(request.intensity)
            return self.faithful
        }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.light))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, faithful)
        XCTAssertEqual(seen, [.lightCleanup])
        XCTAssertFalse(outcome.steppedDown)
        XCTAssertFalse(outcome.guardrailTripped)
        XCTAssertEqual(outcome.engineName, "Scripted")
        XCTAssertEqual(outcome.rawInput, dictation)
        XCTAssertEqual(outcome.modelInput, dictation)
    }

    func testPolishSummaryStepsDownToLight() async {
        let engine = ScriptedCleanupEngine { request in
            request.intensity == .polish ? self.summary : self.faithful
        }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.polish))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, faithful)
        XCTAssertEqual(outcome.attempts.map(\.intensity), [.polish, .lightCleanup])
        XCTAssertTrue(outcome.steppedDown)
        XCTAssertTrue(outcome.guardrailTripped)
        XCTAssertFalse(outcome.attempts[0].verdict.isAccepted)
        XCTAssertTrue(outcome.attempts[1].verdict.isAccepted)
    }

    func testEveryRungVetoedShipsTheDeterministicText() async {
        let engine = ScriptedCleanupEngine { _ in self.summary }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.polish))

        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, dictation)
        XCTAssertEqual(outcome.attempts.map(\.intensity), [.polish, .lightCleanup, .formatting])
        XCTAssertTrue(outcome.guardrailTripped)
        XCTAssertNil(outcome.error)
    }

    func testStepDownCanBeDisabledForPreviews() async {
        let engine = ScriptedCleanupEngine { _ in self.summary }
        let outcome = await pipeline(engine: engine).clean(
            raw: dictation, plan: plan(.polish, allowStepDown: false))

        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.attempts.count, 1)
        XCTAssertEqual(outcome.output, dictation)
    }

    func testPreambleIsStrippedBeforeTheGuardrailSeesIt() async {
        let engine = ScriptedCleanupEngine { _ in
            "Here is the cleaned text:\n\n" + self.faithful + "\n\nREMEMBER: keep every word."
        }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.light))
        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, faithful)
        XCTAssertTrue(outcome.attempts[0].rawOutput.hasPrefix("Here is the cleaned text:"))
        XCTAssertEqual(outcome.attempts[0].tidiedOutput, faithful)
    }

    // MARK: - Custom rulesets

    func testCustomRulesetRunsUngovernedOnASingleRung() async {
        let ruleset = CustomCleanupRuleset(
            name: "Terse", instructions: "Summarise to one line.", temperature: 0.4)
        var received: FormattingRequest?
        let engine = ScriptedCleanupEngine { request in
            received = request
            return self.summary
        }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.custom(ruleset)))

        XCTAssertEqual(outcome.landed, .custom)
        XCTAssertEqual(outcome.output, summary)
        XCTAssertEqual(outcome.attempts.count, 1)
        XCTAssertEqual(outcome.attempts[0].verdict, .notGoverned)
        XCTAssertNil(outcome.attempts[0].evaluation)
        XCTAssertEqual(received?.instructionStages, ["Summarise to one line."])
        XCTAssertEqual(received?.temperature ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertNil(received?.budget)
    }

    func testCustomRulesetStillRejectsAnEmptyAnswer() async {
        let ruleset = CustomCleanupRuleset(name: "Silent", instructions: "Say nothing.")
        let engine = ScriptedCleanupEngine { _ in "   " }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.custom(ruleset)))
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, dictation)
        XCTAssertEqual(outcome.attempts[0].verdict, .emptyOutput)
    }

    func testCustomOptionWithoutUsableRulesetDegradesToLight() {
        XCTAssertEqual(CleanupOption(intensity: .custom, ruleset: nil), .light)
        XCTAssertEqual(
            CleanupOption(intensity: .custom, ruleset: CustomCleanupRuleset(name: "Blank", instructions: "  ")),
            .light)
        let usable = CustomCleanupRuleset(name: "Real", instructions: "Do things.")
        XCTAssertEqual(CleanupOption(intensity: .custom, ruleset: usable), .custom(usable))
        XCTAssertEqual(CleanupOption(intensity: .formatting, ruleset: usable), .basic)
        XCTAssertEqual(CleanupOption(intensity: .polish, ruleset: usable), .polish)
    }

    func testLadderMatchesTheRequestedOption() {
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.off)), [])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.basic)), [.formatting])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.light)), [.lightCleanup, .formatting])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.polish)), [.polish, .lightCleanup, .formatting])
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.polish, allowStepDown: false)), [.polish])
        let ruleset = CustomCleanupRuleset(name: "R", instructions: "x")
        XCTAssertEqual(TranscriptCleanupPipeline.ladder(for: plan(.custom(ruleset))), [.custom])
    }

    // MARK: - Errors and fallback

    func testContentFilterAbortsTheLadder() async {
        var calls = 0
        let engine = ScriptedCleanupEngine { _ in
            calls += 1
            throw CleanupEngineError.contentFilter
        }
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.polish))

        XCTAssertEqual(calls, 1, "no rung can help when the input itself is rejected")
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, dictation)
        XCTAssertEqual(outcome.attempts.map(\.verdict), [.appleContentFilter])
        XCTAssertEqual(outcome.error, "Apple Intelligence declined this text.")
    }

    func testBrokenLocalModelFallsBackToTheSystemModel() async {
        let fallback = ScriptedCleanupEngine(displayName: "Apple Intelligence") { _ in self.faithful }
        let outcome = await pipeline(
            engine: FailingLocalEngine(), fallback: fallback, model: PostProcessingModel.catalog[1]
        ).clean(raw: dictation, plan: plan(.light))

        XCTAssertEqual(outcome.landed, .lightCleanup)
        XCTAssertEqual(outcome.output, faithful)
        XCTAssertEqual(outcome.engineName, "Apple Intelligence")
        XCTAssertEqual(outcome.requestedEngineName, PostProcessingModel.catalog[1].name)
        XCTAssertTrue(outcome.fellBackToSystemModel)
    }

    func testEngineErrorWithoutFallbackStepsDownAndRecordsTheError() async {
        let outcome = await pipeline(engine: FailingLocalEngine()).clean(raw: dictation, plan: plan(.light))
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, dictation)
        XCTAssertEqual(outcome.attempts.count, 2)
        XCTAssertNotNil(outcome.error)
    }

    func testNoAvailableEngineSkipsTheModelStage() async {
        let unavailable = ScriptedCleanupEngine(isAvailable: false) { _ in self.faithful }
        let outcome = await pipeline(engine: unavailable).clean(raw: dictation, plan: plan(.light))
        XCTAssertNil(outcome.landed)
        XCTAssertFalse(outcome.modelRan)
        XCTAssertEqual(outcome.output, dictation)
        XCTAssertEqual(outcome.skippedReason, "No cleanup model is available on this Mac right now.")
    }

    // MARK: - Skip gates

    func testOffAndShortTakesSkipTheModel() async {
        var calls = 0
        let engine = ScriptedCleanupEngine { _ in
            calls += 1
            return self.faithful
        }
        let off = await pipeline(engine: engine).clean(raw: dictation, plan: plan(.off))
        XCTAssertEqual(off.skippedReason, "Cleanup is off.")
        XCTAssertEqual(off.output, dictation)

        var short = plan(.light)
        short.minimumWordCount = 8
        let outcome = await pipeline(engine: engine).clean(raw: "just three words", plan: short)
        XCTAssertEqual(outcome.skippedReason, "Too short for the model (3 words, minimum 8).")
        XCTAssertEqual(calls, 0)
    }

    func testAutoEditRunsBeforeTheModelAndIsRecordedAsModelInput() async {
        var received: String?
        let engine = ScriptedCleanupEngine { request in
            received = request.input
            return self.faithful
        }
        var withAutoEdit = plan(.light)
        withAutoEdit.autoEditEnabled = true
        let outcome = await pipeline(engine: engine).clean(raw: dictation, plan: withAutoEdit)

        XCTAssertEqual(outcome.rawInput, dictation)
        XCTAssertTrue(outcome.modelInput.hasPrefix("So I think we should"), outcome.modelInput)
        XCTAssertFalse(outcome.modelInput.contains(" uh "))
        XCTAssertEqual(received, outcome.modelInput)
    }

    // MARK: - Prompt set and samples

    func testAustralianEnglishAddsTheSpellingStage() {
        let compiled = CleanupPromptSet.compiled
        let au = compiled.instructionStages(for: .lightCleanup, includeMarkdown: false, language: "en-AU")
        let us = compiled.instructionStages(for: .lightCleanup, includeMarkdown: false, language: "en-US")
        XCTAssertTrue(au.contains(compiled.australianSpelling))
        XCTAssertFalse(us.contains(compiled.australianSpelling))
        XCTAssertEqual(au.last, compiled.outputOnly)
        XCTAssertEqual(au.first, compiled.role)
    }

    func testDebugOverlayReplacesFieldsAndParsesBudgets() {
        let suite = "voxbox.tests.cleanup-debug.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            TranscriptCleanupDebug.parseBudget("0.2, 3, 0.8"),
            GuardrailBudget(maxCostRatio: 0.2, minFreeEdits: 3, minRetention: 0.8))
        XCTAssertNil(TranscriptCleanupDebug.parseBudget("nonsense"))
        XCTAssertEqual(TranscriptCleanupDebug.parseTokens("Um, UH , , er"), ["um", "uh", "er"])

        #if DEBUG
            TranscriptCleanupDebug.setOverlay("Tidy it.", for: .light, defaults: defaults)
            TranscriptCleanupDebug.setOverlay("no placeholder here", for: .wrapTemplate, defaults: defaults)
            let overlaid = TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults)
            XCTAssertEqual(overlaid.light, "Tidy it.")
            XCTAssertEqual(overlaid.wrapTemplate, CleanupPromptSet.compiled.wrapTemplate,
                "a wrap template without {{transcript}} must be ignored")
            TranscriptCleanupDebug.setOverlay(nil, for: .light, defaults: defaults)
            XCTAssertNil(TranscriptCleanupDebug.overlayValue(.light, defaults: defaults))
        #endif
    }

    func testBuiltInSamplesAreLongEnoughAndCoverProtectedTokens() {
        for sample in CleanupSampleTranscripts.allCases {
            XCTAssertGreaterThanOrEqual(
                sample.wordCount, TranscriptFormatterService.minimumWordCount, sample.title)
            XCTAssertFalse(sample.title.isEmpty)
        }
        XCTAssertEqual(Set(CleanupSampleTranscripts.allCases.map(\.id)).count, CleanupSampleTranscripts.allCases.count)
        let all = CleanupSampleTranscripts.allCases.map(\.text).joined(separator: " ")
        let tokens = CleanupGuardrail.protectedTokens(in: all)
        XCTAssertTrue(tokens.contains { if case .email = $0 { return true } else { return false } })
        XCTAssertTrue(tokens.contains { if case .url = $0 { return true } else { return false } })
    }
}
