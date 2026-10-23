import Foundation
import FoundationModels
import MLXFoundationModels
import MLXLLM
import MLXLMCommon

/// Cleanup on a downloaded MLX catalog model through Foundation Models.
///
/// `import MLXLLM` is load-bearing: without it, `loadModelContainer` throws
/// `noModelFactoryAvailable` because `MLXFoundationModels` does not depend
/// on the LLM factory trampoline.
@available(macOS 27, *)
nonisolated struct FoundationModelsMLXCleanupEngine: CleanupEngine {
    let model: PostProcessingModel
    let directory: URL

    /// config.json, tokenizer.json and at least one safetensors shard.
    static func hasModelFiles(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path),
            fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
            let contents = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    var isAvailable: Bool { Self.hasModelFiles(in: directory) }

    var displayName: String { model.name }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        guard isAvailable else { throw MLXCleanupEngineError.runtimeUnavailable }
        let stages = request.instructionStages
        let languageModel = makeLanguageModel()
        // A catalog model's refusal is not Apple's content filter, so it is
        // not mapped to `CleanupEngineError.contentFilter`: as an ordinary
        // engine error it makes the pipeline retry on the system model
        // instead of abandoning cleanup for the take.
        return try await CleanupSessionPool.shared.respond(
            request: request,
            variant: model.variant
        ) {
            LanguageModelSession(model: languageModel) {
                stages
            }
        }
    }

    /// Loads weights and runs the one-token Metal warmup via the session
    /// pool. `session.prewarm()` already does that; do not add a second
    /// generate-and-reset.
    func prewarm(_ request: FormattingRequest) async {
        guard isAvailable else { return }
        let stages = request.instructionStages
        let languageModel = makeLanguageModel()
        await CleanupSessionPool.shared.prewarm(
            key: CleanupSessionPool.Key(request: request, variant: model.variant)
        ) {
            LanguageModelSession(model: languageModel) {
                stages
            }
        }
    }

    /// Local Application Support directory + catalog extra EOS tokens.
    /// `load` reuses the configuration (so extra EOS tokens reach the
    /// factory) rather than the directory-only free function, which would
    /// drop them.
    func makeLanguageModel() -> MLXLanguageModel {
        let dir = directory
        let loader = CatalogTokenizerLoader(familyHint: LocalModelFamily.detect(variant: model.variant))
        return MLXLanguageModel(
            configuration: ModelConfiguration(
                directory: dir,
                extraEOSTokens: model.extraEOSTokens),
            capabilities: [],
            weightsLocation: { _ in dir },
            load: { configuration, _ in
                let context = try await LLMModelFactory.shared._load(
                    configuration: configuration.resolved(
                        modelDirectory: dir, tokenizerDirectory: dir),
                    tokenizerLoader: loader)
                return ModelContainer(context: context)
            })
    }
}
