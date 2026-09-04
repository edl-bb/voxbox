import Foundation

/// Which runtime executes a post-processing (cleanup) model.
enum PostProcessingEngineKind: String, Codable, Sendable {
    /// Apple FoundationModels — the ~3B system model that ships with macOS 26.
    case appleSystem
    /// An MLX-format model downloaded from Hugging Face and run locally
    /// through the MLX runtime.
    case mlx
}

/// A model the cleanup pass can run on. Distinct from `AIModel` (speech →
/// text); these are text → text instruction followers.
struct PostProcessingModel: Identifiable, Equatable, Sendable {
    let variant: String
    let name: String
    let provider: String
    let details: String
    let kind: PostProcessingEngineKind
    /// Hugging Face repo ID for downloadable models, nil for the system model.
    let huggingFaceRepo: String?
    /// Approximate on-disk size; drives the progress denominator fallback
    /// and the size chip. 0 for the system model.
    let approxSizeBytes: Int64
    let minimumRAMGB: Int

    var id: String { variant }

    var sizeLabel: String {
        guard approxSizeBytes > 0 else { return "System" }
        return ByteCountFormatter.string(
            fromByteCount: approxSizeBytes, countStyle: .file)
    }

    var ramWarning: String? {
        let deviceRAM = DeviceCapability.current.ramGB
        guard minimumRAMGB > 0, deviceRAM < minimumRAMGB else { return nil }
        return "Needs \(minimumRAMGB) GB+ RAM to run well — your Mac has \(deviceRAM) GB"
    }

    static let appleSystemVariant = "apple-intelligence"

    /// Downloadable MLX models are parked until macOS 27's native
    /// `LanguageModel` support lands (see docs/byo-llm-post-processing.md).
    /// While false, the picker shows only Apple Intelligence and any stored
    /// `.mlx` selection resolves to it.
    static let downloadableModelsEnabled = false

    /// What the picker offers right now.
    static var offered: [PostProcessingModel] {
        downloadableModelsEnabled ? catalog : catalog.filter { $0.kind == .appleSystem }
    }

    /// Curated catalog: the zero-download system model first, then small
    /// instruction-followers suited to transcript cleanup (see
    /// docs/byo-llm-post-processing.md for the selection rationale).
    static let catalog: [PostProcessingModel] = [
        PostProcessingModel(
            variant: appleSystemVariant,
            name: "Apple Intelligence",
            provider: "Apple",
            details: "Built-in • ~3B system model • Runs on the Neural Engine, no download",
            kind: .appleSystem,
            huggingFaceRepo: nil,
            approxSizeBytes: 0,
            minimumRAMGB: 0
        ),
        PostProcessingModel(
            variant: "mlx-llama-3.2-1b-instruct-4bit",
            name: "Llama 3.2 1B Instruct",
            provider: "Meta",
            details: "Fastest download tier • Fine for punctuation and light cleanup",
            kind: .mlx,
            huggingFaceRepo: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            approxSizeBytes: 700_000_000,
            minimumRAMGB: 8
        ),
        PostProcessingModel(
            variant: "mlx-qwen3-1.7b-4bit",
            name: "Qwen 3 1.7B",
            provider: "Alibaba",
            details: "Best quality-per-byte at this size • Apache-2.0",
            kind: .mlx,
            huggingFaceRepo: "mlx-community/Qwen3-1.7B-4bit",
            approxSizeBytes: 1_000_000_000,
            minimumRAMGB: 8
        ),
        PostProcessingModel(
            variant: "mlx-llama-3.2-3b-instruct-4bit",
            name: "Llama 3.2 3B Instruct",
            provider: "Meta",
            details: "Strong instruction following • Good all-round cleanup",
            kind: .mlx,
            huggingFaceRepo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            approxSizeBytes: 1_800_000_000,
            minimumRAMGB: 16
        ),
        PostProcessingModel(
            variant: "mlx-qwen3-4b-4bit",
            name: "Qwen 3 4B",
            provider: "Alibaba",
            details: "Quality tier • Closest to the system model's polish",
            kind: .mlx,
            huggingFaceRepo: "mlx-community/Qwen3-4B-4bit",
            approxSizeBytes: 2_300_000_000,
            minimumRAMGB: 16
        ),
    ]

    static func model(for variant: String) -> PostProcessingModel? {
        catalog.first { $0.variant == variant }
    }
}

/// URL construction and manifest parsing for Hugging Face model repos.
/// Pure functions so they are unit-testable without networking.
enum HuggingFaceRepoAPI {
    /// One file in a repo, from the `?blobs=true` metadata response.
    struct RepoFile: Equatable, Sendable {
        let path: String
        let sizeBytes: Int64
    }

    /// Repo metadata endpoint; `blobs=true` includes per-file sizes.
    nonisolated static func metadataURL(repo: String) -> URL {
        URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!
    }

    /// Direct download URL for one file at the repo head.
    nonisolated static func fileURL(repo: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
    }

    /// Files worth downloading: weights, tokenizer and config assets.
    /// Repo housekeeping (readme, git metadata, images) is skipped.
    nonisolated static func isModelFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return false }
        let skippedExtensions = ["md", "png", "jpg", "jpeg", "gif", "svg", "pdf"]
        let ext = (name as NSString).pathExtension.lowercased()
        return !skippedExtensions.contains(ext)
    }

    /// Parses the `siblings` list of a `?blobs=true` metadata response into
    /// the downloadable files, housekeeping excluded.
    nonisolated static func modelFiles(fromMetadata data: Data) throws -> [RepoFile] {
        struct Metadata: Decodable {
            struct Sibling: Decodable {
                let rfilename: String
                let size: Int64?
            }
            let siblings: [Sibling]
        }
        let decoded = try JSONDecoder().decode(Metadata.self, from: data)
        return decoded.siblings
            .filter { isModelFile($0.rfilename) }
            .map { RepoFile(path: $0.rfilename, sizeBytes: $0.size ?? 0) }
    }
}
