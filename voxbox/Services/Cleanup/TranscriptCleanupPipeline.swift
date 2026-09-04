import Foundation

/// The one implementation of the transcript cleanup chain. Real takes,
/// previews and the eval harness all run through `clean(raw:plan:)`, so
/// what the user sees in a preview is exactly what a take would paste.
///
///   1. Australian spelling (en-AU)
///   2. Dictionary rules
///   3. Auto Edit (deterministic filler strip)
///   4. Model stage: for each rung on the ladder, request → engine →
///      preamble strip → tidy → guardrail; accept or step down
///   5. Australian spelling again (undoes any re-Americanising)
///   6. Smart trailing punctuation
final class TranscriptCleanupPipeline {
    static let shared = TranscriptCleanupPipeline()

    /// Builds requests and runs engines. Injectable for tests.
    var engineProvider: (PostProcessingModel) -> CleanupEngine = { model in
        CleanupEngineFactory.engine(for: model)
    }
    var fallbackEngine: () -> CleanupEngine = { AppleIntelligenceCleanupEngine() }
    var selectedModel: () -> PostProcessingModel = { PostProcessingModelManager.shared.selectedModel }

    init() {}

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
        let modelInput = text

        var outcome: TranscriptCleanupOutcome
        if let reason = Self.skipReason(for: plan, text: modelInput) {
            outcome = .withoutModel(
                rawInput: raw, modelInput: modelInput, output: modelInput, requested: plan.option,
                reason: reason, durationMs: 0)
        } else {
            outcome = await runModelStage(modelInput, raw: raw, plan: plan)
        }

        var output = outcome.output
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

    // MARK: - Model stage

    static func skipReason(for plan: CleanupPlan, text: String) -> String? {
        if plan.option == .off { return "Cleanup is off." }
        let words = CleanupGuardrail.legacyWords(in: text).count
        if words < plan.minimumWordCount {
            return "Too short for the model (\(words) words, minimum \(plan.minimumWordCount))."
        }
        return nil
    }

    private func runModelStage(_ input: String, raw: String, plan: CleanupPlan) async -> TranscriptCleanupOutcome {
        let model = selectedModel()
        let engine = engineProvider(model)
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
            let request = CleanupRequestBuilder.request(for: input, intensity: intensity, plan: plan)
            let attemptStart = Date()
            let engineName: String
            let modelOutput: String
            do {
                (modelOutput, engineName) = try await run(request, on: engine, requestedName: requestedName)
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
                modelOutput.trimmingCharacters(in: .whitespacesAndNewlines), promptSet: plan.promptSet)
            let markdownAllowed = plan.includeMarkdown && (intensity == .custom || plan.promptSet.allowsMarkdown(intensity))
            let tidy = CleanupPostPass.tidyWithDiagnostics(
                stripped, reference: input, markdownAllowed: markdownAllowed,
                numerals: plan.promptSet.rendersNumerals(intensity),
                spokenFillers: plan.promptSet.stripsFillers(intensity))

            let evaluation: GuardrailEvaluation?
            let verdict: GuardrailVerdict
            if let budget = request.budget {
                let result = CleanupGuardrail.evaluate(
                    input: input, output: tidy.text, budget: budget, lexicon: plan.promptSet.fillerLexicon)
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
            return (try await engine.cleanup(request), engine.displayName)
        } catch let error as CleanupEngineError where error == .contentFilter {
            throw error
        } catch {
            let fallback = fallbackEngine()
            guard !(engine is AppleIntelligenceCleanupEngine), fallback.isAvailable else { throw error }
            AppLogger.warning(
                "Local cleanup model failed (\(String(describing: error))); retrying on the system model",
                category: AppLogger.transcription)
            return (try await fallback.cleanup(request), fallback.displayName)
        }
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    static func describe(_ verdict: GuardrailVerdict) -> String {
        switch verdict {
        case .accepted: return "accepted"
        case .notGoverned: return "not governed"
        case .changeRatioExceeded(let ratio, let budget):
            return "change ratio \(String(format: "%.2f", ratio)) over budget \(String(format: "%.2f", budget))"
        case .retentionTooLow(let kept, let floor):
            return "retained \(String(format: "%.2f", kept)) below floor \(String(format: "%.2f", floor))"
        case .protectedTokenAltered(let token): return "protected token altered (\(token.count) chars)"
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
        return request(
            for: text, intensity: effective, includeMarkdown: plan.includeMarkdown,
            language: plan.language, promptSet: plan.promptSet)
    }

    static func request(
        for text: String,
        intensity: FormattingIntensity,
        includeMarkdown: Bool,
        language: String = "auto",
        promptSet: CleanupPromptSet = .compiled
    ) -> FormattingRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FormattingRequest(
            instructionStages: promptSet.instructionStages(
                for: intensity, includeMarkdown: includeMarkdown, language: language),
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
            temperature: ruleset.temperature.clamped(to: CustomRulesetStore.temperatureRange),
            budget: nil)
    }
}
