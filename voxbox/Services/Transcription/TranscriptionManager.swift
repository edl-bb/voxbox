import Foundation

/// Unified entry point the UI uses for model loading and transcription.
///
/// It routes each call to the correct `SpeechToTextEngine` based on the
/// selected model's `TranscriptionEngineKind`, so views are fully decoupled
/// from any specific backend (Apple, Parakeet, or Whisper).
///
/// Display-state properties mirror the active engine.
@Observable
class TranscriptionManager {
    static let shared = TranscriptionManager()

    // MARK: - Engines

    private let whisper = WhisperService.shared
    private let parakeet = ParakeetEngine.shared
    private let apple = AppleSpeechEngine.shared

    /// Which backend currently owns the loaded model. Drives display state.
    private(set) var activeKind: TranscriptionEngineKind = .whisper

    private init() {}

    /// Resolve the engine responsible for a given engine kind.
    private func engine(for kind: TranscriptionEngineKind) -> any SpeechToTextEngine {
        switch kind {
        case .whisper:
            return whisper
        case .parakeet:
            return parakeet
        case .apple:
            return apple
        }
    }

    // MARK: - Display state
    //
    // These switch on `activeKind` and read the concrete `@Observable` engine
    // directly so SwiftUI observation tracks the active backend's state.

    var isInitialized: Bool {
        switch activeKind {
        case .whisper: return whisper.isInitialized
        case .parakeet: return parakeet.isInitialized
        case .apple: return apple.isInitialized
        }
    }
    var isLoading: Bool {
        whisper.isLoading || parakeet.isLoading || apple.isLoading
    }
    var isTranscribing: Bool {
        switch activeKind {
        case .whisper: return whisper.isTranscribing
        case .parakeet: return parakeet.isTranscribing
        case .apple: return apple.isTranscribing
        }
    }
    var loadingStage: String {
        // Read the engine that is actually loading. `activeKind` only flips
        // after load finishes, so a first Parakeet load used to show Whisper's
        // empty stage ("Loading…") on the model card.
        if apple.isLoading { return apple.loadingStage }
        if parakeet.isLoading { return parakeet.loadingStage }
        if whisper.isLoading { return whisper.loadingStage }
        switch activeKind {
        case .whisper: return whisper.loadingStage
        case .parakeet: return parakeet.loadingStage
        case .apple: return apple.loadingStage
        }
    }
    var currentModelVariant: String {
        switch activeKind {
        case .whisper: return whisper.currentModelVariant
        case .parakeet: return parakeet.currentModelVariant
        case .apple: return apple.currentModelVariant
        }
    }

    // MARK: - Actions

    /// Load the user's selected model, or restore Whisper's last model.
    func initialize() async throws {
        let selected = UserDefaults.standard.string(forKey: ModelSelection.defaultsKey)
            ?? ModelSelection.none
        if selected != ModelSelection.none {
            try await loadModel(variant: selected)
            return
        }
        if activeKind == .whisper {
            try await whisper.initialize()
        }
    }

    /// Load a specific model variant, routing to its owning engine.
    func loadModel(variant: String) async throws {
        let kind = AIModel.engineKind(for: variant)
        try await engine(for: kind).loadModel(variant: variant)
        activeKind = kind
    }

    /// Transcribe an audio file with the currently active engine.
    ///
    /// The raw engine output is passed through the user's dictionary rules so
    /// custom replacements and spoken snippets apply uniformly regardless of
    /// which backend produced the text. Smart trailing punctuation runs last,
    /// after snippets have expanded, so a dictation that resolves to an email,
    /// URL, number, or single token loses the model's sentence-final period.
    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        try await transcribeCleaned(audioFile: audioFile, language: language).text
    }

    /// Engine text plus the cleaned transcript. The chain (spelling →
    /// dictionary → Auto Edit → on-device AI → trailing punctuation) is
    /// `TranscriptCleanupPipeline`, shared with live takes and previews.
    func transcribeCleaned(audioFile: URL, language: String = "auto") async throws -> CleanedTranscript {
        let kind = AIModel.engineKind(for: currentModelVariant)
        // Regional English variants (en-AU) decode as plain "en"; the regional
        // spelling pass runs inside the pipeline.
        let engineLanguage = AustralianEnglishSpelling.engineLanguage(for: language)
        let raw = try await engine(for: kind).transcribe(audioFile: audioFile, language: engineLanguage)
        let outcome = await TranscriptCleanupPipeline.shared.clean(
            raw: raw, plan: .fromSettings(language: language))
        return CleanedTranscript(raw: outcome.rawInput, text: outcome.output)
    }

    var supportsLiveStreaming: Bool {
        engine(for: AIModel.engineKind(for: resolvedVariant)).supportsLiveStreaming
    }

    /// `onUpdate` runs on the main actor in arrival order; engines must not
    /// hop through their own `Task` before calling it.
    func startLive(
        language: String,
        onUpdate: @escaping @MainActor (LiveTranscriptSnapshot) -> Void
    ) async throws {
        let variant = resolvedVariant
        guard StreamingMode.modelSupportsLive(variant) else {
            throw LiveStreamingError.modelDoesNotStream
        }
        let kind = AIModel.engineKind(for: variant)
        if currentModelVariant != variant || !isInitialized {
            try await loadModel(variant: variant)
        }
        let engineLanguage = AustralianEnglishSpelling.engineLanguage(for: language)
        switch kind {
        case .apple:
            try await apple.startLive(language: engineLanguage, onUpdate: onUpdate)
        case .whisper:
            try await whisper.startLive(language: engineLanguage, onUpdate: onUpdate)
        case .parakeet:
            throw LiveStreamingError.modelDoesNotStream
        }
    }

    func finishLive() async throws -> String {
        switch AIModel.engineKind(for: resolvedVariant) {
        case .apple:
            return try await apple.finishLive()
        case .whisper:
            return try await whisper.finishLive()
        case .parakeet:
            throw LiveStreamingError.modelDoesNotStream
        }
    }

    func cancelLive() {
        apple.cancelLive()
        whisper.cancelLive()
    }

    private var resolvedVariant: String {
        if !currentModelVariant.isEmpty { return currentModelVariant }
        return UserDefaults.standard.string(forKey: ModelSelection.defaultsKey)
            ?? ModelSelection.none
    }
}

enum LiveStreamingError: LocalizedError {
    case modelDoesNotStream

    var errorDescription: String? {
        switch self {
        case .modelDoesNotStream:
            return "The selected model cannot stream. Turn off streaming or switch to Apple Speech or a Whisper model."
        }
    }
}

// MARK: - WhisperService conformance

/// `WhisperService` already exposes the full `SpeechToTextEngine` surface, so
/// conformance requires no changes to the Whisper code path.
extension WhisperService: SpeechToTextEngine {}
