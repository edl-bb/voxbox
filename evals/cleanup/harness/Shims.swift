import Foundation

// Stand-ins for app types the cleanup chain references but the eval does not
// need. The harness compiles the app's real cleanup sources next to these;
// see scripts/cleanup-eval.sh for the file list.

extension Notification.Name {
    static let transcriptCleanupStarted = Notification.Name("transcriptCleanupStarted")
    static let transcriptCleanupFinished = Notification.Name("transcriptCleanupFinished")
}

/// The eval always runs the system model; MLX catalog models need the app
/// target (mlx-swift is not part of this build).
final class PostProcessingModelManager {
    static let shared = PostProcessingModelManager()

    var selectedModel: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == PostProcessingModel.appleSystemVariant }!
    }
}

enum CleanupEngineFactory {
    static func engine(for model: PostProcessingModel) -> CleanupEngine {
        AppleIntelligenceCleanupEngine()
    }
}

/// Dictionary rules are per-user; the eval runs without them.
enum DictionaryService {
    nonisolated static func apply(to text: String) -> String { text }
}
