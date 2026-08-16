import AVFoundation
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
        let desired = preferredLocale(language: language)

        if SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: desired)
        {
            return .speech(SpeechTranscriber(locale: locale, preset: .transcription))
        }

        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: desired) {
            return .dictation(DictationTranscriber(locale: locale, preset: .shortDictation))
        }

        if SpeechTranscriber.isAvailable,
            let fallback = await SpeechTranscriber.installedLocales.first
        {
            return .speech(SpeechTranscriber(locale: fallback, preset: .transcription))
        }

        if let fallback = await DictationTranscriber.installedLocales.first {
            return .dictation(DictationTranscriber(locale: fallback, preset: .shortDictation))
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
}
