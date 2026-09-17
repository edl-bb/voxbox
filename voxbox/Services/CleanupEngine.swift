import Foundation

/// A backend that can execute one transcript-cleanup request. The pipeline
/// picks an engine per request via `CleanupEngineFactory`, so runtimes can
/// be added or swapped without touching the cleanup chain.
nonisolated protocol CleanupEngine {
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

/// Chooses the engine for the selected post-processing model.
///
/// Routing is locked in CONTRACTS.md: Apple Intelligence for the system
/// model and for any MLX variant that is not on disk; the parked
/// `MLXCleanupEngine` stub when weights exist but the OS gate is off;
/// `FoundationModelsMLXCleanupEngine` when weights exist on macOS 27.
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
            if #available(macOS 27, *), OSCapabilities.customCleanupModels {
                return FoundationModelsMLXCleanupEngine(
                    model: model,
                    directory: PostProcessingModelManager.storageDir(for: model.variant))
            }
            return MLXCleanupEngine(
                model: model,
                directory: PostProcessingModelManager.storageDir(for: model.variant))
        }
    }
}
