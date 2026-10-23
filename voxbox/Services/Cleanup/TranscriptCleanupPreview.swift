import Foundation
import FoundationModels

/// Run any text through the cleanup chain the way a real take would, but
/// without the enabled gate or the minimum word count. Onboarding, the
/// ruleset test panel and the eval harness use this.
enum TranscriptCleanupPreview {
    static func preview(
        text: String,
        option: CleanupOption,
        includeMarkdown: Bool = false,
        language: String = "auto",
        autoEdit: Bool = false,
        allowStepDown: Bool = false,
        promptSet: CleanupPromptSet = .compiled,
        speaker: SpeakerContext? = TranscriptFormatterService.speakerContext,
        pipeline: TranscriptCleanupPipeline = .shared
    ) async -> TranscriptCleanupOutcome {
        let plan = CleanupPlan(
            option: option,
            includeMarkdown: includeMarkdown,
            language: language,
            autoEditEnabled: autoEdit,
            smartTrailingPunctuation: SmartTrailingPunctuation.isEnabled,
            minimumWordCount: 0,
            allowStepDown: allowStepDown,
            isPreview: true,
            promptSet: promptSet,
            speaker: speaker)
        return await pipeline.clean(raw: text, plan: plan)
    }

    /// Sequential comparison; `onResult` fires per option so a UI can fill
    /// in progressively. Stops early when the task is cancelled.
    static func compare(
        text: String,
        options: [CleanupOption],
        includeMarkdown: Bool = false,
        language: String = "auto",
        onResult: @MainActor (CleanupOption, TranscriptCleanupOutcome) -> Void
    ) async {
        for option in options {
            if Task.isCancelled { return }
            let outcome = await preview(
                text: text, option: option, includeMarkdown: includeMarkdown, language: language)
            if Task.isCancelled { return }
            onResult(option, outcome)
        }
    }

    /// Load the system model before the first real call so the first
    /// preview does not pay the cold-start latency. Goes through the
    /// session pool so the first Basic cleanup reuses this session.
    static func prewarm() async {
        guard TranscriptFormatterService.isModelAvailable else { return }
        let stages = CleanupPromptSet.compiled.instructionStages(
            for: .formatting, includeMarkdown: false, language: "auto")
        let key = CleanupSessionPool.Key(
            variant: PostProcessingModel.appleSystemVariant,
            instructionFingerprint: stages.joined(separator: "\n\n"),
            temperature: 0)
        let model = AppleIntelligenceCleanupEngine.systemModel
        await CleanupSessionPool.shared.prewarm(key: key) {
            LanguageModelSession(model: model) {
                stages
            }
        }
    }
}
