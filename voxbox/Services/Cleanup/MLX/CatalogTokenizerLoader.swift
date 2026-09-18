import Foundation
import MLXLMCommon

/// Loads a catalog model's tokenizer from its Application Support directory.
/// Used only by `FoundationModelsMLXCleanupEngine` — the macOS 26
/// `MLXCleanupEngine` stub stays throwing and does not use this path.
///
/// WhisperKit pins swift-transformers 0.1.8, which has no Jinja
/// `applyChatTemplate`, so this loader uses `LocalBPETokenizer` plus
/// `ChatTemplateRenderer` instead of `#huggingFaceTokenizerLoader()`.
nonisolated struct CatalogTokenizerLoader: TokenizerLoader {
    /// Preferred when the catalog variant is known; otherwise `config.json`.
    var familyHint: LocalModelFamily?

    func load(from directory: URL) async throws -> any Tokenizer {
        let family: LocalModelFamily
        if let familyHint {
            family = familyHint
        } else {
            family = try LocalModelFamily.detect(in: directory)
        }
        let bpe = try LocalBPETokenizer(directory: directory)
        let table = try AddedTokenTable(directory: directory)
        return LocalModelTokenizer(
            bpe: bpe,
            added: table,
            family: family,
            // Cleanup is not a reasoning task: empty think tags even when
            // MLXLanguageModel passes a nil additionalContext.
            defaultEnableThinking: family == .qwen3 ? false : true)
    }
}
