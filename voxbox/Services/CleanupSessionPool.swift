import Foundation
import FoundationModels
import os

/// One cached `LanguageModelSession` per (variant, instruction fingerprint,
/// temperature). Instructions live on the session; each `respond` sends only
/// this take’s `userPrompt`. Prior takes are stripped from the transcript
/// after every turn so they never become conversation history.
actor CleanupSessionPool {
    static let shared = CleanupSessionPool()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "voxbox",
        category: "CleanupSessionPool")

    struct Key: Hashable, Sendable {
        var variant: String
        var instructionFingerprint: String
        var temperature: Double

        init(variant: String, instructionFingerprint: String, temperature: Double) {
            self.variant = variant
            self.instructionFingerprint = instructionFingerprint
            self.temperature = temperature
        }

        init(request: FormattingRequest, variant: String) {
            self.init(
                variant: variant,
                instructionFingerprint: request.instructions,
                temperature: request.temperature)
        }
    }

    private var sessions: [Key: any Sendable] = [:]

    var entryCount: Int { sessions.count }

    func hasSession(for key: Key) -> Bool {
        sessions[key] != nil
    }

    /// Input to `LanguageModelSession.respond(to:)`: this take only.
    static func respondInput(for request: FormattingRequest) -> String {
        request.userPrompt
    }

    /// Get-or-create. `makeSession` runs only on a miss. Tests use this with
    /// a dummy token; production `prewarm` / `respond` pass a real session.
    func session<S: Sendable>(for key: Key, makeSession: @Sendable () -> S) -> S {
        if let existing = sessions[key] as? S {
            Self.log.debug(
                "reuse variant=\(key.variant, privacy: .public) temperature=\(key.temperature)")
            return existing
        }
        let created = makeSession()
        sessions[key] = created
        Self.log.info(
            "create variant=\(key.variant, privacy: .public) temperature=\(key.temperature) entries=\(self.sessions.count)"
        )
        return created
    }

    func prewarm(key: Key, makeSession: @Sendable () -> LanguageModelSession) async {
        let pooled = session(for: key, makeSession: makeSession)
        // Apple's prewarm is synchronous fire-and-forget; Preview still
        // `await`s this actor method so the session exists before return.
        pooled.prewarm()
    }

    func respond(
        request: FormattingRequest,
        variant: String,
        makeSession: @Sendable () -> LanguageModelSession
    ) async throws -> String {
        let key = Key(request: request, variant: variant)
        let pooled = session(for: key, makeSession: makeSession)
        let started = ContinuousClock.now
        defer { forgetPriorTakes(on: pooled) }
        let response = try await pooled.respond(
            to: Self.respondInput(for: request),
            options: AppleIntelligenceCleanupEngine.generationOptions(for: request)
        )
        let elapsed = started.duration(to: .now)
        Self.log.info(
            "respond variant=\(variant, privacy: .public) \(elapsed) entries=\(self.sessions.count)"
        )
        return response.content
    }

    func invalidate(variant: String) {
        sessions = sessions.filter { $0.key.variant != variant }
        Self.log.info("invalidate variant=\(variant, privacy: .public) entries=\(self.sessions.count)")
    }

    /// macOS 27 can rewrite `transcript.history`. On 26 the property is
    /// get-only, so reuse still shares the session object (weights stay hot)
    /// but Apple keeps that session’s turns.
    private func forgetPriorTakes(on session: LanguageModelSession) {
        if #available(macOS 27, *) {
            session.transcript.history = []
        }
    }
}
