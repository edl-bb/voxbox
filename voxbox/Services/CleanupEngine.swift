import Foundation
import FoundationModels

/// A backend that can execute one transcript-cleanup request. The formatter
/// picks an engine per request via `CleanupEngineFactory`, so runtimes can
/// be added or swapped without touching the cleanup pipeline.
protocol CleanupEngine {
    /// Whether the engine can run right now (model present, OS support, …).
    var isAvailable: Bool { get }
    /// Runs the request and returns the raw model output (the caller strips
    /// preambles and applies the change-ratio guardrail).
    func cleanup(_ request: FormattingRequest) async throws -> String
}

/// Apple FoundationModels — the ~3B system model that ships with macOS 26.
struct AppleIntelligenceCleanupEngine: CleanupEngine {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        let session = LanguageModelSession {
            request.instructionStages
        }
        let response = try await session.respond(
            to: request.input,
            options: GenerationOptions(temperature: request.temperature)
        )
        return response.content
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
