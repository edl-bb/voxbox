import Foundation

/// The two chat formats the catalog ships. Detected from the catalog variant
/// or, when loading from disk, Hugging Face `config.json` `model_type`.
nonisolated enum LocalModelFamily: String, Equatable, Sendable {
    case llama3
    case qwen3

    enum DetectError: Error, Equatable {
        case configMissing
        case unsupportedModelType(String)
    }

    /// Catalog variants (`mlx-llama-…`, `mlx-qwen3-…`).
    static func detect(variant: String) -> LocalModelFamily? {
        let lower = variant.lowercased()
        if lower.contains("llama") { return .llama3 }
        if lower.contains("qwen") { return .qwen3 }
        return nil
    }

    /// `model_type` values from Hugging Face `config.json`.
    static func detect(modelType: String) -> LocalModelFamily? {
        switch modelType.lowercased() {
        case "llama": return .llama3
        case "qwen3", "qwen2": return .qwen3
        default: return nil
        }
    }

    static func detect(in directory: URL) throws -> LocalModelFamily {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { throw DetectError.configMissing }
        struct Config: Decodable { let model_type: String? }
        let type = (try? JSONDecoder().decode(Config.self, from: data))?.model_type ?? ""
        guard let family = detect(modelType: type) else {
            throw DetectError.unsupportedModelType(type)
        }
        return family
    }

    /// Whether the chat prompt starts with a beginning-of-sequence token.
    var addsBOS: Bool { self == .llama3 }

    var bosToken: String? {
        switch self {
        case .llama3: return "<|begin_of_text|>"
        case .qwen3: return nil
        }
    }

    var eosToken: String {
        switch self {
        case .llama3: return "<|eot_id|>"
        case .qwen3: return "<|im_end|>"
        }
    }
}
