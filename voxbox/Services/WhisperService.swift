@preconcurrency import AVFoundation
import Foundation
import WhisperKit

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()
    private static let placeholderPatterns = [
        #"\[(?:BLANK_AUDIO|SILENCE)\]"#,
        #"<\|[^|]*\|>"#,
        #"\[\s*S\s*\]"#,
    ]
    private static let noiseLabelTerms = [
        "applause",
        "background noise",
        "blank audio",
        "breathing",
        "cough",
        "coughing",
        "exhale",
        "heartbeat",
        "indistinct",
        "inaudible",
        "inhale",
        "laughing",
        "laughter",
        "loud noise",
        "muffled speech",
        "music",
        "noise",
        "silence",
        "sigh",
        "sighs",
        "sniffing",
        "static",
        "unclear speech",
        "unintelligible",
        "wind",
        "wind blowing",
        "wind noise",
    ]
    private static let bracketedNoisePattern: String = {
        let escaped = noiseLabelTerms.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        return #"[\[\(]\s*(?:"# + escaped + #")\s*[\]\)]"#
    }()

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage: String = ""  // Descriptive stage for UI
    var loadingModelVariant: String = ""
    var loadingStartedAt: Date?

    var currentModelVariant: String = ""  // No default - must be explicitly set
    var supportsLiveStreaming: Bool { true }
    private var lastLoadDuration: TimeInterval?
    private var liveSink: LiveAudioSampleSink?
    private var liveStreamer: AudioStreamTranscriber?
    private var liveStreamTask: Task<Void, Never>?
    private var liveStable = ""
    private var liveRevisable = ""

    @MainActor private var activeLoadTask: Task<Void, Error>?
    @MainActor private var activeLoadVariant: String = ""
    @MainActor private var activeLoadToken: UUID?

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
            }
        }
    }

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    @MainActor
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    @MainActor
    func loadModel(variant: String) async throws {
        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        if let activeLoadTask {
            let inFlightVariant = activeLoadVariant

            if inFlightVariant == variant {
                loadingStage = "Model is still warming up..."
                print("⏳ Model \(variant) load already in progress, waiting for completion")
                try await activeLoadTask.value
                return
            }

            loadingStage = "Finishing current model load..."
            print("⏳ Waiting for current model load (\(inFlightVariant)) to finish before loading \(variant)")
            do {
                try await activeLoadTask.value
            } catch {
                // If another model failed to warm up, still try the model the caller asked for.
                print(
                    "⚠️ In-flight model load (\(inFlightVariant)) failed while waiting: \(error.localizedDescription). Continuing with \(variant)."
                )
            }

            if isInitialized && variant == currentModelVariant && pipe != nil {
                print("✅ Model \(variant) became ready while waiting, skipping duplicate load")
                return
            }
        }

        let token = UUID()
        let task = Task { @MainActor in
            try await self.performModelLoad(variant: variant)
        }
        activeLoadTask = task
        activeLoadVariant = variant
        activeLoadToken = token

        defer {
            if activeLoadToken == token {
                activeLoadTask = nil
                activeLoadVariant = ""
                activeLoadToken = nil
            }
        }

        try await task.value
    }

    @MainActor
    private func performModelLoad(variant: String) async throws {
        let ramGB = Self.deviceRAMGB
        print("🔄 Initializing WhisperKit with model: \(variant)...")
        print("💻 Device RAM: \(ramGB) GB")

        if let model = AIModel.availableModels.first(where: { $0.variant == variant }),
            ramGB < model.minimumRAMGB
        {
            print(
                "⚠️ WARNING: Model \(variant) recommends \(model.minimumRAMGB)GB+ RAM, device has \(ramGB)GB. Loading may fail or be very slow."
            )
        }

        isLoading = true
        isInitialized = false
        loadingModelVariant = variant
        loadingStartedAt = Date()
        loadingStage = ModelLoadCopy.preparing

        // Release existing model to free memory
        if pipe != nil {
            loadingStage = "Switching models and freeing memory..."
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        do {
            // Prefer the current Application Support location; fall back to the legacy
            // Documents location so users who downloaded before the move keep working.
            let newModelFolder = ModelStorage.whisperKitModelsDir
                .appendingPathComponent(variant)
            var modelFolder = newModelFolder
            if !FileManager.default.fileExists(atPath: newModelFolder.path),
                let legacyFolder = ModelStorage.legacyModelsDir?.appendingPathComponent(variant),
                FileManager.default.fileExists(atPath: legacyFolder.path)
            {
                modelFolder = legacyFolder
            }

            // Use WhisperKitConfig with optimized settings.
            // `downloadBase` keeps any tokenizer configs WhisperKit fetches out of
            // ~/Documents (the root cause of model-load failures on macOS 15, #38).
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: ModelStorage.whisperKitBase,
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(),  // Uses GPU + Neural Engine
                verbose: false,
                logLevel: .error,
                prewarm: true,  // Built-in model specialization (replaces manual warmup)
                load: true,
                download: false  // Already downloaded via ModelDownloadService
            )

            loadingStage = ModelLoadCopy.preparing

            // Start a watchdog timer that will flag a timeout
            let loadStart = Date()

            pipe = try await WhisperKit(config)

            let loadDuration = Date().timeIntervalSince(loadStart)
            lastLoadDuration = loadDuration
            print("⏱️ Model loaded in \(String(format: "%.1f", loadDuration))s")

            currentModelVariant = variant
            isInitialized = true
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print("✅ WhisperKit initialized and prewarmed with \(variant)")
        } catch {
            isLoading = false
            loadingStage = ""
            loadingModelVariant = ""
            loadingStartedAt = nil
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            let options = decodingOptions(for: language)
            let results = try await pipe.transcribe(audioPath: audioFile.path, decodeOptions: options)
            let text = Self.normalizedTranscription(
                from: results.map { $0.text }.joined(separator: " "))

            print("Transcription complete (\(text.count) characters)")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribe a background audio chunk without affecting the global `isTranscribing` flag.
    /// Chunk files are automatically deleted after transcription.
    func transcribeChunk(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            // Chunk file may have been cleaned up already - return empty gracefully
            return ""
        }

        print("🔪 Chunk transcription started: \(audioFile.lastPathComponent)")

        let results = try await pipe.transcribe(
            audioPath: audioFile.path,
            decodeOptions: decodingOptions(for: language)
        )
        let text = Self.normalizedTranscription(from: results.map { $0.text }.joined(separator: " "))

        print("🔪 Chunk done (\(text.count) characters)")
        // Clean up temp chunk file after transcription
        try? FileManager.default.removeItem(at: audioFile)
        return text
    }

    private func decodingOptions(for language: String) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        // Whisper has no regional variants — collapse codes like "en-AU" to
        // their base language in case a caller bypasses TranscriptionManager.
        let baseLanguage = language.components(separatedBy: "-").first ?? language
        options.language = (language == "auto") ? nil : baseLanguage
        return options
    }

    static func normalizedTranscription(from rawText: String) -> String {
        var normalized = rawText

        for pattern in placeholderPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: bracketedNoisePattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        normalized = AutoEdit.apply(to: normalized)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Live streaming

    func startLive(
        language: String,
        onUpdate: @escaping @Sendable (LiveTranscriptSnapshot) -> Void
    ) async throws {
        cancelLive()
        guard let pipe, isInitialized, let tokenizer = pipe.tokenizer else {
            throw TranscriptionError.notInitialized
        }

        isTranscribing = true
        liveStable = ""
        liveRevisable = ""

        let sink = LiveAudioSampleSink()
        liveSink = sink
        let streamer = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: sink,
            decodingOptions: decodingOptions(for: language),
            useVAD: false,
            stateChangeCallback: { [weak self] _, newState in
                self?.publishLiveState(newState, onUpdate: onUpdate)
            }
        )
        liveStreamer = streamer
        liveStreamTask = Task {
            do {
                try await streamer.startStreamTranscription()
            } catch {
                AppLogger.error(
                    "Live WhisperKit stream failed",
                    error: error,
                    category: AppLogger.transcription)
            }
        }

        AudioRecordingService.shared.liveBufferHandler = { [weak sink] sampleBuffer in
            sink?.ingest(sampleBuffer)
        }
    }

    func finishLive() async throws -> String {
        AudioRecordingService.shared.liveBufferHandler = nil
        if let streamer = liveStreamer {
            await streamer.stopStreamTranscription()
        }
        _ = await liveStreamTask?.value
        let text = Self.normalizedTranscription(
            from: LiveTranscriptSnapshot(stable: liveStable, revisable: liveRevisable).fullText
        )
        teardownLive()
        return text
    }

    func cancelLive() {
        AudioRecordingService.shared.liveBufferHandler = nil
        liveStreamTask?.cancel()
        if let streamer = liveStreamer {
            Task { await streamer.stopStreamTranscription() }
        }
        teardownLive()
    }

    private func teardownLive() {
        liveStreamer = nil
        liveSink = nil
        liveStreamTask = nil
        liveStable = ""
        liveRevisable = ""
        isTranscribing = false
    }

    private func publishLiveState(
        _ state: AudioStreamTranscriber.State,
        onUpdate: @escaping @Sendable (LiveTranscriptSnapshot) -> Void
    ) {
        let snapshot = WhisperLiveHypothesis.snapshot(
            confirmed: Self.normalizedTranscription(
                from: state.confirmedSegments.map(\.text).joined(separator: " ")),
            unconfirmed: Self.normalizedTranscription(
                from: state.unconfirmedSegments.map(\.text).joined(separator: " ")),
            current: Self.normalizedTranscription(from: state.currentText),
            previousRevisable: liveRevisable
        )
        liveStable = snapshot.stable
        liveRevisable = snapshot.revisable
        onUpdate(snapshot)
    }

}

/// Maps WhisperKit’s windowed decode onto a stable prefix plus a tail that
/// does not restart from empty every time the unconfirmed window is re-run.
enum WhisperLiveHypothesis {
    static let waitingCopy = "Waiting for speech..."

    static func snapshot(
        confirmed: String,
        unconfirmed: String,
        current: String,
        previousRevisable: String
    ) -> LiveTranscriptSnapshot {
        let stable = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = current == waitingCopy
            ? ""
            : current.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = unconfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawHypothesis = window.isEmpty ? pending : window
        let hypothesis = stripConfirmedPrefix(rawHypothesis, confirmed: stable)

        let revisable: String
        if isCovered(by: stable, tail: previousRevisable) {
            revisable = hypothesis
        } else if hypothesis.isEmpty || shouldHold(previous: previousRevisable, next: hypothesis) {
            revisable = previousRevisable
        } else {
            revisable = hypothesis
        }
        return LiveTranscriptSnapshot(stable: stable, revisable: revisable)
    }

    static func stripConfirmedPrefix(_ text: String, confirmed: String) -> String {
        guard !confirmed.isEmpty, text.hasPrefix(confirmed) else { return text }
        return String(text.dropFirst(confirmed.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After a window confirms, the old tail is already in `stable`. Drop it
    /// so the next window does not reprint those words.
    static func isCovered(by stable: String, tail: String) -> Bool {
        guard !tail.isEmpty else { return true }
        return stable.hasSuffix(tail) || stable.hasSuffix(" " + tail)
    }

    /// Hold the last tail while a window restarts or shrinks. Take the next
    /// hypothesis only when it extends the tail or replaces it at similar length.
    static func shouldHold(previous: String, next: String) -> Bool {
        guard !previous.isEmpty else { return false }
        if next.hasPrefix(previous) { return false }
        if previous.hasPrefix(next) { return true }
        return next.count < max(8, (previous.count * 2) / 3)
    }
}
