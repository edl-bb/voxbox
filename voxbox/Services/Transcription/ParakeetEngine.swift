import Foundation
import FluidAudio

/// Maps VoxBox catalog variants to FluidAudio model versions.
///
/// Keeping this in one place lets both the engine (loading) and the model
/// store (download / delete / existence checks) agree on which FluidAudio
/// model a given catalog variant refers to.
enum ParakeetCatalog {
    static let v3Variant = "parakeet-tdt-0.6b-v3"
    static let v2Variant = "parakeet-tdt-0.6b-v2"
    static let ctc110mVariant = "parakeet-tdt-ctc-110m"

    /// All Parakeet variants VoxBox ships.
    static let variants = [v3Variant, v2Variant, ctc110mVariant]

    /// FluidAudio model version for a given catalog variant.
    static func version(for variant: String) -> AsrModelVersion {
        switch variant {
        case v2Variant: return .v2
        case ctc110mVariant: return .tdtCtc110m
        default: return .v3
        }
    }
}

enum ParakeetEngineError: LocalizedError {
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let variant):
            return "\(variant) is not downloaded. Download it in Settings → AI Models first."
        }
    }
}

/// Speech-to-text engine backed by NVIDIA Parakeet, run on-device via
/// FluidAudio (CoreML / Apple Neural Engine).
///
/// Conforms to `SpeechToTextEngine` so `TranscriptionManager` can use it
/// interchangeably with `WhisperService`. State mirrors the Whisper engine's
/// surface so the existing UI works unchanged.
@Observable
class ParakeetEngine: SpeechToTextEngine {
    static let shared = ParakeetEngine()

    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage = ""
    var currentModelVariant = ""

    /// FluidAudio's actor that owns the loaded CoreML models.
    private var manager: AsrManager?
    private var activeLoadTask: Task<Void, Error>?
    private var activeLoadVariant = ""

    private init() {}

    func loadModel(variant: String) async throws {
        // Already loaded this exact model.
        if isInitialized, currentModelVariant == variant, manager != nil { return }

        if let activeLoadTask {
            if activeLoadVariant == variant {
                try await activeLoadTask.value
                return
            }
            _ = try? await activeLoadTask.value
            if isInitialized, currentModelVariant == variant, manager != nil { return }
        }

        let task = Task {
            try await self.performModelLoad(variant: variant)
        }
        activeLoadTask = task
        activeLoadVariant = variant
        defer {
            if activeLoadVariant == variant {
                activeLoadTask = nil
                activeLoadVariant = ""
            }
        }
        try await task.value
    }

    private func performModelLoad(variant: String) async throws {
        isLoading = true
        isInitialized = false
        loadingStage = "Preparing Parakeet model…"
        defer { isLoading = false }

        // Release any previously loaded model before loading a new one.
        if let manager {
            await manager.cleanup()
        }
        manager = nil

        let version = ParakeetCatalog.version(for: variant)
        loadingStage = "Loading Parakeet model…"

        // Never download implicitly: selecting/loading a model must not touch
        // the network. Models are fetched only through the explicit download
        // button (ModelDownloadService). If the cache is empty, fail with a
        // clear error instead of silently pulling hundreds of megabytes.
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        let cacheContents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        guard !cacheContents.isEmpty else {
            loadingStage = ""
            throw ParakeetEngineError.modelNotDownloaded(variant)
        }

        // Cache is populated, so this loads from disk without downloading.
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        self.manager = manager
        currentModelVariant = variant
        isInitialized = true
        loadingStage = ""
    }

    func transcribe(audioFile: URL, language: String) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }

        isTranscribing = true
        defer { isTranscribing = false }

        // One-shot (batch) transcription: a fresh decoder state per file.
        // The decoder state must match the model's decoder-layer count — the
        // TDT-CTC 110M model has 1 layer while the 0.6B models have 2 — or
        // transcription fails. `language: nil` lets the model auto-detect.
        let version = ParakeetCatalog.version(for: currentModelVariant)
        do {
            var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
            let result = try await manager.transcribe(audioFile, decoderState: &decoderState)
            return result.text
        } catch {
            print("❌ Parakeet transcription failed (\(currentModelVariant)): \(error)")
            throw error
        }
    }
}
