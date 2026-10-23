import Foundation

/// The one implementation of the transcript cleanup chain. Real takes,
/// previews and the eval harness all run through `clean(raw:plan:)`, so
/// what the user sees in a preview is exactly what a take would paste.
///
///   1. Australian spelling (en-AU)
///   2. Dictionary rules
///   3. Auto Edit (deterministic filler strip)
///   4. Model stage: for each rung on the ladder, request → engine →
///      preamble strip → tidy → echo check → guardrail; accept or step
///      down. When nothing lands, Light and Polish ship the instant pass.
///   5. Question marks the model dropped, speaker vocabulary, dictated
///      lists (Light and Polish)
///   6. Australian spelling again (undoes any re-Americanising)
///   7. Smart trailing punctuation
final class TranscriptCleanupPipeline {
    nonisolated static let shared = TranscriptCleanupPipeline()

    /// Builds requests and runs engines. Injectable for tests.
    var engineProvider: (PostProcessingModel) -> CleanupEngine = { model in
        CleanupEngineFactory.engine(for: model)
    }
    var fallbackEngine: () -> CleanupEngine = { AppleIntelligenceCleanupEngine() }
    var selectedModel: () -> PostProcessingModel = { PostProcessingModelManager.shared.selectedModel }
    /// Seconds a model call may take before the take gives up on it.
    var deadline: (FormattingRequest) -> Double = { TranscriptCleanupPipeline.defaultDeadline(for: $0) }

    /// Generous next to measured speed (about 50 words a second of output
    /// on Apple Intelligence, under 1.5 s for a typical take): 8 s for a
    /// sentence, 30 s for a 300-word ramble, never more than a minute.
    nonisolated static func defaultDeadline(for request: FormattingRequest) -> Double {
        let words = Double(request.input.split(whereSeparator: { $0.isWhitespace }).count)
        return min(60, 6 + words * 0.08)
    }

    nonisolated init() {}

    func clean(raw: String, plan: CleanupPlan) async -> TranscriptCleanupOutcome {
        let started = Date()

        var text = raw
        if AustralianEnglishSpelling.isAustralianEnglish(plan.language) {
            text = AustralianEnglishSpelling.apply(to: text)
        }
        if plan.applyDictionary {
            text = DictionaryService.apply(to: text)
        }
        text = AutoEdit.apply(to: text, enabled: plan.autoEditEnabled)
        if Self.resolvesSelfCorrections(plan) {
            text = SpokenRepairs.resolve(text)
        }
        if plan.renderNumbersBeforeModel, let intensity = plan.option.intensity, plan.promptSet.rendersNumerals(intensity) {
            // "twelve thousand five hundred dollars" reached the model as
            // words, and it wrote "12,500" without the currency. As "$12,500"
            // it keeps the amount whole.
            text = SpokenNumbers.render(in: text)
        }
        let modelInput = text

        var outcome: TranscriptCleanupOutcome
        if let reason = Self.skipReason(for: plan, text: modelInput) {
            // Too short for the model, but Light and Polish still owe the
            // speaker their ums and numerals: run the instant pass alone.
            let output = Self.instantPass(modelInput, plan: plan)
            outcome = .withoutModel(
                rawInput: raw, modelInput: modelInput, output: output, requested: plan.option,
                reason: reason, durationMs: 0)
        } else {
            outcome = await runModelStage(modelInput, raw: raw, plan: plan)
        }

        var output = outcome.output
        if outcome.modelRan, !plan.option.isCustom {
            output = CleanupPostPass.restoreQuestionMarks(output, reference: modelInput)
        }
        if !plan.option.isCustom,
            plan.option.intensity == .lightCleanup || plan.option.intensity == .polish
        {
            output = CleanupPostPass.markDirectQuestions(output)
        }
        if outcome.landed == .polish, plan.promptSet.dropsSpokenScaffolding {
            output = CleanupPostPass.dropSpokenScaffolding(output)
        }
        if let speaker = plan.speaker, let intensity = plan.option.intensity,
            plan.promptSet.allowsSpeakerContext(intensity)
        {
            output = speaker.applyVocabulary(to: output)
        }
        if plan.includeMarkdown, let intensity = plan.option.intensity, plan.promptSet.allowsMarkdown(intensity) {
            output = CleanupPostPass.formatSpokenLists(output)
        }
        if AustralianEnglishSpelling.isAustralianEnglish(plan.language) {
            output = AustralianEnglishSpelling.apply(to: output)
        }
        if plan.smartTrailingPunctuation {
            output = SmartTrailingPunctuation.apply(to: output, enabled: true)
        }
        outcome.output = output
        outcome.totalDurationMs = Int(Date().timeIntervalSince(started) * 1000)

        if !plan.isPreview {
            TranscriptFormatterService.shared.record(outcome)
        }
        return outcome
    }

    /// Deterministic Light/Polish repairs without the model: unambiguous
    /// fillers and repeats, numerals, punctuation and casing tidy. Basic,
    /// Custom and Off return the text unchanged.
    static func instantPass(_ text: String, plan: CleanupPlan) -> String {
        guard let intensity = plan.option.intensity, intensity != .custom,
            plan.promptSet.stripsFillers(intensity) || plan.promptSet.rendersNumerals(intensity)
        else { return text }
        return CleanupPostPass.tidy(
            text, reference: text, markdownAllowed: false,
            numerals: plan.promptSet.rendersNumerals(intensity),
            spokenFillers: plan.promptSet.stripsFillers(intensity),
            joinFragments: plan.promptSet.joinsPauseFragments(intensity))
    }

    /// "Tuesday, no, sorry, Wednesday" → "Wednesday" before the model sees
    /// it: the on-device model drops the cue words but keeps both versions,
    /// and the filler strip then removes ", I mean," as a filler. English
    /// cues only, so other languages skip it.
    static func resolvesSelfCorrections(_ plan: CleanupPlan) -> Bool {
        guard plan.resolveSelfCorrections, let intensity = plan.option.intensity,
            plan.promptSet.stripsFillers(intensity)
        else { return false }
        let language = plan.language.lowercased()
        return language == "auto" || language.hasPrefix("en")
    }

    // MARK: - Prewarm

    /// Loads the model for the first rung `plan` will run, with the exact
    /// instructions, so the take's first request finds a warm session.
    /// Fire-and-forget; call when recording starts.
    static func prewarm(plan: CleanupPlan) {
        guard plan.option != .off, let intensity = ladder(for: plan).first else { return }
        let request = CleanupRequestBuilder.request(for: "", intensity: intensity, plan: plan)
        let model = PostProcessingModelManager.shared.selectedModel
        let engine = CleanupEngineFactory.engine(for: model)
        Task {
            await engine.prewarm(request)
        }
    }

    // MARK: - Model stage

    static let maximumModelWords = 900

    static func skipReason(for plan: CleanupPlan, text: String) -> String? {
        if plan.option == .off { return "Cleanup is off." }
        let words = CleanupGuardrail.legacyWords(in: text).count
        if words < plan.minimumWordCount {
            return "Too short for the model (\(words) words, minimum \(plan.minimumWordCount)); instant cleanup only."
        }
        // Instructions, a take this long and its reply overflow the on-device
        // model's 4,096-token context, and the guardrail's alignment grows
        // with input × output.
        if words > maximumModelWords {
            return "Too long for the on-device model (\(words) words, maximum \(maximumModelWords)); instant cleanup only."
        }
        return nil
    }

    private func runModelStage(_ input: String, raw: String, plan: CleanupPlan) async -> TranscriptCleanupOutcome {
        let model = selectedModel()
        var engine = engineProvider(model)
        let requestedName = model.name
        guard engine.isAvailable || fallbackEngine().isAvailable else {
            return .withoutModel(
                rawInput: raw, modelInput: input, output: input, requested: plan.option,
                reason: "No cleanup model is available on this Mac right now.", durationMs: 0)
        }

        if !plan.isPreview {
            NotificationCenter.default.post(name: .transcriptCleanupStarted, object: nil)
        }

        let ladder = Self.ladder(for: plan)
        var attempts: [CleanupAttempt] = []
        var landed: FormattingIntensity?
        var output = input

        for intensity in ladder {
            // Polish edits, and is judged against, the dictation without its
            // spoken scaffolding ("I meant to say,"): dropping it is not lost
            // content, and the comma that marks it is only reliable here.
            let rungInput = intensity == .polish && plan.promptSet.dropsSpokenScaffolding
                ? CleanupPostPass.dropSpokenScaffolding(input) : input
            let request = CleanupRequestBuilder.request(for: rungInput, intensity: intensity, plan: plan)
            let attemptStart = Date()
            let engineName: String
            let modelOutput: String
            do {
                (modelOutput, engineName) = try await run(request, on: engine, requestedName: requestedName)
                if engineName != engine.displayName {
                    // The selected local model failed and the system model
                    // answered: use it directly for any later rung rather
                    // than paying for the broken model again.
                    engine = fallbackEngine()
                }
            } catch let error as CleanupEngineError where error == .timedOut {
                attempts.append(
                    CleanupAttempt(
                        intensity: intensity, engineName: requestedName, requestedEngineName: requestedName,
                        rawOutput: "", tidiedOutput: "", evaluation: nil,
                        verdict: .engineError("timed out after \(Int(deadline(request))) s"),
                        casingAnomaly: false, durationMs: Self.ms(since: attemptStart)))
                AppLogger.warning(
                    "Cleanup model stalled at \(intensity.displayName); shipping the instant pass",
                    category: AppLogger.transcription)
                break  // A stalled model will not answer the next rung either.
            } catch let error as CleanupEngineError where error == .contentFilter {
                attempts.append(
                    CleanupAttempt(
                        intensity: intensity, engineName: requestedName, requestedEngineName: requestedName,
                        rawOutput: "", tidiedOutput: "", evaluation: nil, verdict: .appleContentFilter,
                        casingAnomaly: false, durationMs: Self.ms(since: attemptStart)))
                break  // The input itself is rejected; no rung will help.
            } catch {
                attempts.append(
                    CleanupAttempt(
                        intensity: intensity, engineName: requestedName, requestedEngineName: requestedName,
                        rawOutput: "", tidiedOutput: "", evaluation: nil,
                        verdict: .engineError(String(describing: error)),
                        casingAnomaly: false, durationMs: Self.ms(since: attemptStart)))
                AppLogger.warning(
                    "Cleanup engine failed at \(intensity.displayName); \(plan.allowStepDown ? "stepping down" : "keeping raw")",
                    category: AppLogger.transcription)
                continue
            }

            let stripped = CleanupPostPass.stripModelPreamble(
                modelOutput.trimmingCharacters(in: .whitespacesAndNewlines), promptSet: plan.promptSet,
                reference: rungInput)
            // A prompt set with no Markdown stage never asks for Markdown, so
            // any the model writes is residue to strip.
            let markdownAllowed = plan.includeMarkdown
                && (intensity == .custom || (plan.promptSet.allowsMarkdown(intensity) && !plan.promptSet.markdown.isEmpty))
            let tidy = CleanupPostPass.tidyWithDiagnostics(
                stripped, reference: rungInput, markdownAllowed: markdownAllowed,
                numerals: plan.promptSet.rendersNumerals(intensity),
                spokenFillers: plan.promptSet.stripsFillers(intensity),
                joinFragments: plan.promptSet.joinsPauseFragments(intensity))

            let evaluation: GuardrailEvaluation?
            let verdict: GuardrailVerdict
            if let echo = CleanupGuardrail.echoedInstruction(
                output: tidy.text, input: rungInput, instructions: request.instructions + "\n" + request.userPrompt)
            {
                evaluation = nil
                verdict = .instructionEcho(echo)
            } else if let budget = request.budget {
                let result = CleanupGuardrail.evaluate(
                    input: rungInput, output: tidy.text, budget: budget, lexicon: plan.promptSet.fillerLexicon)
                evaluation = result
                verdict = result.verdict
            } else {
                evaluation = nil
                verdict = tidy.text.isEmpty ? .emptyOutput
                    : (CleanupPostPass.looksLikeRefusal(tidy.text) ? .refusal : .notGoverned)
            }

            attempts.append(
                CleanupAttempt(
                    intensity: intensity, engineName: engineName, requestedEngineName: requestedName,
                    rawOutput: modelOutput, tidiedOutput: tidy.text, evaluation: evaluation, verdict: verdict,
                    casingAnomaly: tidy.casingAnomaly, durationMs: Self.ms(since: attemptStart)))

            if verdict.isAccepted {
                landed = intensity
                output = tidy.text
                break
            }
            AppLogger.info(
                "Cleanup \(intensity.displayName) vetoed: \(Self.describe(verdict)); "
                    + (plan.allowStepDown ? "stepping down" : "keeping raw"),
                category: AppLogger.transcription)
        }

        if landed == nil {
            output = Self.instantPass(input, plan: plan)
        }

        let outcome = TranscriptCleanupOutcome(
            rawInput: raw, modelInput: input, output: output, requested: plan.option, landed: landed,
            attempts: attempts, totalDurationMs: 0, skippedReason: nil)
        AppLogger.info(
            "Cleanup requested=\(plan.option.displayName) landed=\(landed?.displayName ?? "raw") "
                + "attempts=\(attempts.count) engine=\(outcome.engineName ?? "-")"
                + (outcome.fellBackToSystemModel ? " (fell back from \(requestedName))" : ""),
            category: AppLogger.transcription)
        return outcome
    }

    static func ladder(for plan: CleanupPlan) -> [FormattingIntensity] {
        let start: FormattingIntensity
        switch plan.option {
        case .off: return []
        case .basic: start = .formatting
        case .light: start = .lightCleanup
        case .polish: start = .polish
        case .custom: return [.custom]  // Ungoverned: nothing to step down to.
        }
        guard plan.allowStepDown else { return [start] }
        return start.stepDownLadder
    }

    /// Runs on `engine`; a local-model failure retries once on the system
    /// model so a broken download degrades instead of skipping cleanup.
    private func run(
        _ request: FormattingRequest, on engine: CleanupEngine, requestedName: String
    ) async throws -> (output: String, engineName: String) {
        do {
            return (try await cleanup(request, on: engine), engine.displayName)
        } catch let error as CleanupEngineError where error == .contentFilter {
            throw error
        } catch {
            let fallback = fallbackEngine()
            guard !(engine is AppleIntelligenceCleanupEngine), fallback.isAvailable else { throw error }
            AppLogger.warning(
                "Local cleanup model failed (\(String(describing: error))); retrying on the system model",
                category: AppLogger.transcription)
            return (try await cleanup(request, on: fallback), fallback.displayName)
        }
    }

    private func cleanup(_ request: FormattingRequest, on engine: CleanupEngine) async throws -> String {
        nonisolated(unsafe) let engine = engine
        return try await CleanupDeadline.run(seconds: deadline(request)) {
            try await engine.cleanup(request)
        }
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    nonisolated static func describe(_ verdict: GuardrailVerdict) -> String {
        switch verdict {
        case .accepted: return "accepted"
        case .notGoverned: return "not governed"
        case .changeRatioExceeded(let ratio, let budget):
            return "change ratio \(String(format: "%.2f", ratio)) over budget \(String(format: "%.2f", budget))"
        case .retentionTooLow(let kept, let floor):
            return "retained \(String(format: "%.2f", kept)) below floor \(String(format: "%.2f", floor))"
        case .protectedTokenAltered(let token): return "protected token altered (\(token.count) chars)"
        case .instructionEcho(let run): return "echoed its instructions (\(run.split(separator: " ").count)-word run)"
        case .emptyOutput: return "empty output"
        case .refusal: return "model refused"
        case .appleContentFilter: return "Apple content filter"
        case .engineError(let message): return "engine error: \(message)"
        }
    }
}

/// Builds the request for one rung, or for a custom ruleset.
nonisolated enum CleanupRequestBuilder {
    static func request(for text: String, intensity: FormattingIntensity, plan: CleanupPlan) -> FormattingRequest {
        if case .custom(let ruleset) = plan.option, intensity == .custom {
            return request(for: text, ruleset: ruleset, promptSet: plan.promptSet)
        }
        let effective: FormattingIntensity = intensity == .custom ? .lightCleanup : intensity
        let modelText = plan.promptSet.flattensSentenceBreaks(effective)
            ? CleanupPostPass.flattenSentenceBreaks(text) : text
        return request(
            for: modelText, intensity: effective, includeMarkdown: plan.includeMarkdown,
            language: plan.language, promptSet: plan.promptSet, speaker: plan.speaker)
    }

    static func request(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdown: Bool,
        language: String = "auto",
        promptSet: CleanupPromptSet = .compiled,
        speaker: SpeakerContext? = nil
    ) -> FormattingRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormattingRequest(
            instructionStages: promptSet.instructionStages(
                for: intensity, includeMarkdown: includeMarkdown, language: language, speaker: speaker),
            input: trimmed,
            userPrompt: promptSet.userPrompt(for: trimmed, intensity: intensity),
            intensity: intensity,
            temperature: 0,
            budget: promptSet.budget(for: intensity))
    }

    /// The user's instructions go to the model exactly as written, with the
    /// wrap template around the transcript and no built-in stages, suffix,
    /// or governor.
    static func request(
        for text: String,
        ruleset: CustomCleanupRuleset,
        promptSet: CleanupPromptSet = .compiled
    ) -> FormattingRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormattingRequest(
            instructionStages: [ruleset.instructions.trimmingCharacters(in: .whitespacesAndNewlines)],
            input: trimmed,
            userPrompt: promptSet.userPrompt(for: trimmed, intensity: nil),
            intensity: .custom,
            temperature: DoubleClamp.clamp(ruleset.temperature, to: CustomCleanupRuleset.temperatureRange),
            budget: nil)
    }
}
