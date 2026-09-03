import Foundation
import FoundationModels

/// A backend that can execute one transcript-cleanup request. The pipeline
/// picks an engine per request via `CleanupEngineFactory`, so runtimes can
/// be added or swapped without touching the cleanup chain.
protocol CleanupEngine {
    /// Whether the engine can run right now (model present, OS support, …).
    var isAvailable: Bool { get }
    /// Human name for outcomes and previews ("Apple Intelligence").
    var displayName: String { get }
    /// Runs the request and returns the raw model output (the caller strips
    /// preambles, tidies, and applies the guardrail).
    func cleanup(_ request: FormattingRequest) async throws -> String
}

nonisolated enum CleanupEngineError: Error, Equatable {
    /// The model's own content filter rejected the request. Stepping down
    /// will not help: the input is what was rejected.
    case contentFilter
}

/// Apple FoundationModels — the ~3B system model that ships with macOS 26.
struct AppleIntelligenceCleanupEngine: CleanupEngine {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var displayName: String {
        PostProcessingModel.catalog.first { $0.variant == PostProcessingModel.appleSystemVariant }?.name
            ?? "Apple Intelligence"
    }

    /// Built-in levels are deterministic: `temperature: 0` alone is not
    /// documented as greedy, so ask for greedy sampling explicitly. Custom
    /// rulesets keep their own temperature. Never cap response tokens: a
    /// cap truncates silently.
    static func generationOptions(for request: FormattingRequest) -> GenerationOptions {
        if request.temperature <= 0 {
            return GenerationOptions(sampling: .greedy)
        }
        return GenerationOptions(temperature: request.temperature)
    }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        let session = LanguageModelSession {
            request.instructionStages
        }
        do {
            let response = try await session.respond(
                to: request.userPrompt,
                options: Self.generationOptions(for: request)
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw CleanupEngineError.contentFilter
            default:
                throw error
            }
        }
    }
}

/// Chooses the engine for the selected post-processing model.
///
/// macOS 27 note: FoundationModels there opens a public `LanguageModel`
/// protocol with an Apple-provided MLX implementation. Once the app can
/// build against the macOS 27 SDK, add a bridged engine here and prefer it
/// under `#available(macOS 27, *)` for `.mlx` models; the direct
/// `MLXCleanupEngine` stays as the macOS 26 path. Only this factory should
/// need to change.
enum CleanupEngineFactory {
    static func engine(
        for model: PostProcessingModel,
        manager: PostProcessingModelManager = .shared
    ) -> CleanupEngine {
        switch model.kind {
        case .appleSystem:
            return AppleIntelligenceCleanupEngine()
        case .mlx:
            guard manager.isDownloaded(model.variant) else {
                // Selected but not on disk (deleted externally, fresh Mac):
                // fall back to the system model rather than fail cleanup.
                return AppleIntelligenceCleanupEngine()
            }
            return MLXCleanupEngine(
                model: model,
                directory: PostProcessingModelManager.storageDir(for: model.variant))
        }
    }
}
