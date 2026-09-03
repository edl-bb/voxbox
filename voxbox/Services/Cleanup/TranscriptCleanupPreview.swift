import Foundation
import FoundationModels

/// Run any text through the cleanup chain the way a real take would, but
/// without the enabled gate or the minimum word count. Onboarding, the
/// ruleset test panel and the eval harness use this.
enum TranscriptCleanupPreview {
    static func preview(
        text: String,
        option: CleanupOption,
        includeMarkdown: Bool = TranscriptFormatterService.isMarkdownFormattingEnabled,
        language: String = "auto",
        autoEdit: Bool = AutoEdit.isEnabled,
        allowStepDown: Bool = false,
        promptSet: CleanupPromptSet = .resolved(),
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
            promptSet: promptSet)
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
            await onResult(option, outcome)
        }
    }

    /// Load the system model before the first real call so the first
    /// preview does not pay the cold-start latency.
    static func prewarm() async {
        guard TranscriptFormatterService.isModelAvailable else { return }
        let session = LanguageModelSession {
            CleanupPromptSet.compiled.instructionStages(
                for: .formatting, includeMarkdown: false, language: "auto")
        }
        await session.prewarm()
    }
}
