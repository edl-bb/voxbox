import Foundation

/// Owns one live take: engine updates, AppKit field rewrite, HUD snapshot.
@MainActor
@Observable
final class LiveDictationSession {
    static let shared = LiveDictationSession()

    private(set) var snapshot = LiveTranscriptSnapshot.empty
    private(set) var isLive = false
    /// True when words are going into the other app’s field.
    private(set) var writingToField = false

    private let inserter = TargetFieldInserter()
    private var language = "auto"

    private init() {}

    var hudText: String { snapshot.fullText }

    func start(language: String) async throws {
        cancel()
        self.language = language
        snapshot = .empty
        _ = inserter.begin()
        writingToField = false
        isLive = true
        try await TranscriptionManager.shared.startLive(
            language: language,
            onUpdate: { next in
                Task { @MainActor in
                    LiveDictationSession.shared.apply(next)
                }
            }
        )
    }

    func apply(_ next: LiveTranscriptSnapshot) {
        guard isLive else { return }
        snapshot = next
        guard inserter.isActive else { return }
        let text = next.fullText
        guard !text.isEmpty else { return }
        writingToField = inserter.update(text)
    }

    func finish() async throws -> (text: String, alreadyInField: Bool) {
        guard isLive else { return ("", false) }
        let raw: String
        do {
            raw = try await TranscriptionManager.shared.finishLive()
        } catch {
            raw = snapshot.fullText
            if raw.isEmpty { throw error }
        }
        let cleaned = await Self.clean(raw, language: language)
        let delivered = inserter.isActive && inserter.update(cleaned)
        if delivered {
            inserter.reset()
        } else {
            inserter.revert()
        }
        writingToField = delivered
        isLive = false
        snapshot = LiveTranscriptSnapshot(stable: cleaned, revisable: "")
        return (cleaned, delivered)
    }

    func cancel() {
        guard isLive || inserter.isActive else {
            snapshot = .empty
            return
        }
        TranscriptionManager.shared.cancelLive()
        inserter.revert()
        writingToField = false
        isLive = false
        snapshot = .empty
    }

    private static func clean(_ text: String, language: String) async -> String {
        var next = text
        if AustralianEnglishSpelling.isAustralianEnglish(language) {
            next = AustralianEnglishSpelling.apply(to: next)
        }
        next = DictionaryService.apply(to: next)
        next = AutoEdit.apply(to: next)
        if TranscriptFormatterService.shouldFormat(next) {
            NotificationCenter.default.post(name: .transcriptCleanupStarted, object: nil)
            next = await TranscriptFormatterService.shared.format(next)
        }
        return SmartTrailingPunctuation.apply(to: next)
    }
}
