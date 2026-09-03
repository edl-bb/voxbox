import Foundation

@testable import voxbox

/// A cleanup engine that answers from a script and records every request,
/// so pipeline tests can drive the step-down ladder without a model.
final class ScriptedCleanupEngine: CleanupEngine {
    struct Failure: Error, Equatable {
        var message: String
    }

    var isAvailable: Bool
    var displayName: String
    var script: (FormattingRequest) throws -> String
    private(set) var requests: [FormattingRequest] = []

    init(
        displayName: String = "Scripted",
        isAvailable: Bool = true,
        script: @escaping (FormattingRequest) throws -> String
    ) {
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.script = script
    }

    /// Answers by intensity; anything unscripted echoes the input.
    convenience init(displayName: String = "Scripted", answers: [FormattingIntensity: String]) {
        self.init(displayName: displayName) { request in
            answers[request.intensity] ?? request.input
        }
    }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        requests.append(request)
        return try script(request)
    }

    var intensitiesAsked: [FormattingIntensity] { requests.map(\.intensity) }
}

extension TranscriptCleanupPipeline {
    /// A pipeline wired to fakes; the model selection is the system model so
    /// engine names in outcomes are predictable.
    static func scripted(
        engine: CleanupEngine,
        fallback: CleanupEngine = ScriptedCleanupEngine(displayName: "Fallback", isAvailable: false) { $0.input },
        selected: PostProcessingModel = PostProcessingModel.catalog[0]
    ) -> TranscriptCleanupPipeline {
        let pipeline = TranscriptCleanupPipeline()
        pipeline.engineProvider = { _ in engine }
        pipeline.fallbackEngine = { fallback }
        pipeline.selectedModel = { selected }
        return pipeline
    }
}

extension CleanupPlan {
    /// A preview-style plan: no dictionary, no enabled gate, no minimum
    /// word count, compiled prompts. Tests override what they care about.
    static func test(
        _ option: CleanupOption,
        stepDown: Bool = true,
        autoEdit: Bool = false,
        language: String = "auto",
        minimumWordCount: Int = 0,
        markdown: Bool = false,
        smartTrailingPunctuation: Bool = true,
        isPreview: Bool = true
    ) -> CleanupPlan {
        CleanupPlan(
            option: option,
            includeMarkdown: markdown,
            language: language,
            autoEditEnabled: autoEdit,
            applyDictionary: false,
            smartTrailingPunctuation: smartTrailingPunctuation,
            minimumWordCount: minimumWordCount,
            allowStepDown: stepDown,
            isPreview: isPreview,
            promptSet: .compiled)
    }
}
