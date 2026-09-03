@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Catalog identity for the built-in Apple SpeechAnalyzer starter.
///
/// One variant covers the system speech assets for the user's locale.
/// Those assets are installed through `AssetInventory`, not Hugging Face.
enum AppleSpeechCatalog {
    nonisolated static let variant = "apple-speech"

    /// Locale the user (or the system) is asking for.
    static func preferredLocale(language: String) -> Locale {
        if language == "auto" || language.isEmpty {
            return Locale.current
        }
        return Locale(identifier: language)
    }

    /// SpeechTranscriber when the new model is available for the locale;
    /// otherwise DictationTranscriber. See wayfinder research on
    /// [Apple SpeechAnalyzer starter transcription engine](https://github.com/edl-bb/voxbox/issues/8).
    static func makeModule(language: String) async throws -> AppleSpeechModule {
        try await makeModule(language: language, live: false)
    }

    static func makeLiveModule(language: String) async throws -> AppleSpeechModule {
        try await makeModule(language: language, live: true)
    }

    private static func makeModule(language: String, live: Bool) async throws -> AppleSpeechModule {
        let desired = preferredLocale(language: language)
        let speechPreset: SpeechTranscriber.Preset =
            live ? .progressiveTranscription : .transcription
        let dictationPreset: DictationTranscriber.Preset =
            live ? .progressiveLongDictation : .shortDictation

        if SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: desired)
        {
            return .speech(SpeechTranscriber(locale: locale, preset: speechPreset))
        }

        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: desired) {
            return .dictation(DictationTranscriber(locale: locale, preset: dictationPreset))
        }

        if SpeechTranscriber.isAvailable,
            let fallback = await SpeechTranscriber.installedLocales.first
        {
            return .speech(SpeechTranscriber(locale: fallback, preset: speechPreset))
        }

        if let fallback = await DictationTranscriber.installedLocales.first {
            return .dictation(DictationTranscriber(locale: fallback, preset: dictationPreset))
        }

        throw AppleSpeechEngineError.localeNotSupported(language)
    }

    /// True when the locale asset for the starter is already on this Mac.
    static func isInstalled(language: String = "auto") async -> Bool {
        guard let module = try? await makeModule(language: language) else { return false }
        let status = await AssetInventory.status(forModules: [module.speechModule])
        if status == .installed { return true }
        return await localeAssetInstalled(for: module)
    }

    private static func localeAssetInstalled(for module: AppleSpeechModule) async -> Bool {
        switch module {
        case .speech(let transcriber):
            guard let selected = transcriber.selectedLocales.first else { return false }
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains {
                $0.identifier(.bcp47) == selected.identifier(.bcp47)
            }
        case .dictation(let transcriber):
            guard let selected = transcriber.selectedLocales.first else { return false }
            let installed = await DictationTranscriber.installedLocales
            return installed.contains {
                $0.identifier(.bcp47) == selected.identifier(.bcp47)
            }
        }
    }
}

/// The concrete SpeechAnalyzer module chosen for a transcription.
enum AppleSpeechModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let transcriber): return transcriber
        case .dictation(let transcriber): return transcriber
        }
    }

    func collectText() async throws -> String {
        switch self {
        case .speech(let transcriber):
            var combined = ""
            for try await result in transcriber.results {
                combined += String(result.text.characters)
            }
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        case .dictation(let transcriber):
            var combined = ""
            for try await result in transcriber.results {
                combined += String(result.text.characters)
            }
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum AppleSpeechEngineError: LocalizedError {
    case assetsNotInstalled
    case localeNotSupported(String)
    case fileUnreadable

    var errorDescription: String? {
        switch self {
        case .assetsNotInstalled:
            return "Apple speech assets are not installed. Install them in Settings → AI Models first."
        case .localeNotSupported(let language):
            return "Apple speech does not support the “\(language)” locale on this Mac."
        case .fileUnreadable:
            return "The recording could not be opened for Apple speech transcription."
        }
    }
}

/// Speech-to-text engine backed by Apple SpeechAnalyzer (macOS 26+).
///
/// Prefers `SpeechTranscriber` (Apple’s current general-purpose model) and
/// falls back to `DictationTranscriber` when that model is unavailable for
/// the locale. File transcription uses `analyzeSequence(from:)`.
@Observable
class AppleSpeechEngine: SpeechToTextEngine {
    static let shared = AppleSpeechEngine()

    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage = ""
    var currentModelVariant = ""
    var supportsLiveStreaming: Bool { true }

    private var liveAnalyzer: SpeechAnalyzer?
    private let liveTap = AppleLiveAudioTap()
    private var liveResultsTask: Task<Void, Never>?
    private var liveStable = ""
    private var liveRevisable = ""

    private init() {}

    func loadModel(variant: String) async throws {
        if isInitialized, currentModelVariant == variant { return }

        isLoading = true
        isInitialized = false
        loadingStage = ModelLoadCopy.preparing
        defer { isLoading = false }

        guard await AppleSpeechCatalog.isInstalled() else {
            loadingStage = ""
            throw AppleSpeechEngineError.assetsNotInstalled
        }

        currentModelVariant = variant
        isInitialized = true
        loadingStage = ""
    }

    func transcribe(audioFile: URL, language: String) async throws -> String {
        guard await AppleSpeechCatalog.isInstalled(language: language) else {
            throw AppleSpeechEngineError.assetsNotInstalled
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let module = try await AppleSpeechCatalog.makeModule(language: language)
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioFile)
        } catch {
            throw AppleSpeechEngineError.fileUnreadable
        }

        async let transcription = module.collectText()

        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await transcription
    }

    func startLive(
        language: String,
        onUpdate: @escaping @MainActor (LiveTranscriptSnapshot) -> Void
    ) async throws {
        cancelLive()
        guard await AppleSpeechCatalog.isInstalled(language: language) else {
            throw AppleSpeechEngineError.assetsNotInstalled
        }

        isTranscribing = true
        liveStable = ""
        liveRevisable = ""

        let module = try await AppleSpeechCatalog.makeLiveModule(language: language)
        let analyzer = SpeechAnalyzer(modules: [module.speechModule])
        liveAnalyzer = analyzer
        liveTap.outputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.speechModule])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        liveTap.input = continuation
        try await analyzer.start(inputSequence: stream)

        liveResultsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.collectLive(from: module, onUpdate: onUpdate)
            } catch {
                AppLogger.error("Live Apple speech failed", error: error, category: AppLogger.transcription)
            }
        }

        AudioRecordingService.shared.liveBufferHandler = { [liveTap] sampleBuffer in
            liveTap.ingest(sampleBuffer)
        }
    }

    func finishLive() async throws -> String {
        AudioRecordingService.shared.liveBufferHandler = nil
        liveTap.finish()
        if let analyzer = liveAnalyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await liveResultsTask?.value
        let text = (liveStable + liveRevisable)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        teardownLive()
        return text
    }

    func cancelLive() {
        AudioRecordingService.shared.liveBufferHandler = nil
        liveTap.finish()
        liveResultsTask?.cancel()
        liveResultsTask = nil
        if let analyzer = liveAnalyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        teardownLive()
    }

    private func teardownLive() {
        liveAnalyzer = nil
        liveTap.reset()
        liveStable = ""
        liveRevisable = ""
        isTranscribing = false
    }

    private func collectLive(
        from module: AppleSpeechModule,
        onUpdate: @escaping @MainActor (LiveTranscriptSnapshot) -> Void
    ) async throws {
        switch module {
        case .speech(let transcriber):
            for try await result in transcriber.results {
                applyLiveResult(String(result.text.characters), isFinal: result.isFinal, onUpdate: onUpdate)
            }
        case .dictation(let transcriber):
            for try await result in transcriber.results {
                applyLiveResult(String(result.text.characters), isFinal: result.isFinal, onUpdate: onUpdate)
            }
        }
    }

    private func applyLiveResult(
        _ text: String,
        isFinal: Bool,
        onUpdate: @escaping @MainActor (LiveTranscriptSnapshot) -> Void
    ) {
        if isFinal {
            // Same seam rule as `fullText`, so the stable text stays a
            // prefix of what the field already shows.
            liveStable = LiveTranscriptSnapshot.join(liveStable, text)
            liveRevisable = ""
        } else if !liveStable.isEmpty, text.hasPrefix(liveStable) {
            liveRevisable = String(text.dropFirst(liveStable.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            liveRevisable = text
        }
        onUpdate(LiveTranscriptSnapshot(stable: liveStable, revisable: liveRevisable))
    }
}

/// Audio-queue tap for Apple Speech live ingest. Kept off `@Observable`
/// so the capture callback is not MainActor-isolated.
nonisolated final class AppleLiveAudioTap: @unchecked Sendable {
    var input: AsyncStream<AnalyzerInput>.Continuation?
    var converter: AVAudioConverter?
    var outputFormat: AVAudioFormat?

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let input,
            let pcm = Self.pcmBuffer(from: sampleBuffer)
        else { return }
        let converted = convertForAnalyzer(pcm) ?? pcm
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        input?.finish()
        input = nil
    }

    func reset() {
        input = nil
        converter = nil
        outputFormat = nil
    }

    private func convertForAnalyzer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = outputFormat, buffer.format != target else { return buffer }
        if converter == nil || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
