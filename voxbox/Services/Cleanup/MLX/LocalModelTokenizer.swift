import Foundation
import MLXLMCommon

/// `MLXLMCommon.Tokenizer` over `LocalBPETokenizer`. Special tokens bypass
/// the BPE model; the chat template is rendered by `ChatTemplateRenderer`.
/// Used only by `FoundationModelsMLXCleanupEngine` (macOS 27 catalog path).
nonisolated final class LocalModelTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let bpe: LocalBPETokenizer
    let added: AddedTokenTable
    let family: LocalModelFamily
    /// Qwen 3 defaults thinking ON in its template. Cleanup is not a
    /// reasoning task, so the catalog loader sets this to `false`.
    let defaultEnableThinking: Bool
    private let renderer: ChatTemplateRenderer

    init(
        bpe: LocalBPETokenizer,
        added: AddedTokenTable,
        family: LocalModelFamily,
        defaultEnableThinking: Bool = true
    ) {
        self.bpe = bpe
        self.added = added
        self.family = family
        self.defaultEnableThinking = defaultEnableThinking
        self.renderer = ChatTemplateRenderer(family: family)
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var ids: [Int] = []
        if addSpecialTokens, family.addsBOS, let bosToken, let bos = convertTokenToId(bosToken) {
            ids.append(bos)
        }
        for segment in added.split(text) {
            switch segment {
            case .special(let id): ids.append(id)
            case .text(let plain): ids.append(contentsOf: bpe.encode(plain))
            }
        }
        return ids
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        var output = ""
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            output += bpe.decode(run)
            run.removeAll()
        }
        for id in tokenIds {
            if let special = added.contentByID[id] {
                flush()
                if !skipSpecialTokens { output += special }
            } else {
                run.append(id)
            }
        }
        flush()
        return output
    }

    func convertTokenToId(_ token: String) -> Int? {
        added.idsByContent[token] ?? bpe.id(for: token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        added.contentByID[id] ?? bpe.token(for: id)
    }

    var bosToken: String? { family.bosToken }
    var eosToken: String? { family.eosToken }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let rendered = renderer.render(
            messages: messages,
            additionalContext: additionalContext,
            defaultEnableThinking: defaultEnableThinking)
        return encode(text: rendered, addSpecialTokens: true)
    }
}
