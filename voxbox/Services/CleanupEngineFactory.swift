import Foundation

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
