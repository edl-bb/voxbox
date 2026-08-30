import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Runs cleanup on a locally downloaded MLX model (macOS 26 path — see the
/// macOS 27 note in `CleanupEngineFactory`).
struct MLXCleanupEngine: CleanupEngine {
    let model: PostProcessingModel
    let directory: URL

    var isAvailable: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path)
    }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        let container = try await MLXModelCache.shared.container(
            for: model.variant, directory: directory)

        // Cleanup output is roughly input-sized; the cap only exists to stop
        // a runaway generation from spinning the GPU indefinitely.
        let inputWords = TranscriptFormatterService.words(in: request.input).count
        let session = ChatSession(
            container,
            instructions: request.instructions,
            generateParameters: GenerateParameters(
                maxTokens: min(4096, inputWords * 4 + 256),
                temperature: Float(request.temperature))
        )
        return try await session.respond(to: request.input)
    }
}

/// Keeps exactly one MLX model resident: loading takes seconds and hundreds
/// of megabytes, so the active variant is cached and evicted when the user
/// switches or deletes models.
actor MLXModelCache {
    static let shared = MLXModelCache()

    private var loaded: (variant: String, container: ModelContainer)?

    func container(for variant: String, directory: URL) async throws -> ModelContainer {
        if let loaded, loaded.variant == variant {
            return loaded.container
        }
        // Release the previous model's weights before loading the next one.
        loaded = nil
        MLX.GPU.clearCache()
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)

        let configuration = ModelConfiguration(directory: directory)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration)
        loaded = (variant, container)
        return container
    }

    /// Drops the resident model (deleted from disk, or no longer selected).
    func unload() {
        loaded = nil
        MLX.GPU.clearCache()
    }
}
