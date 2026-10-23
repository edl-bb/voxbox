import Foundation
import FoundationModels
import os

/// One cached `LanguageModelSession` per (variant, instruction fingerprint,
/// temperature). Instructions live on the session; each `respond` sends only
/// this take’s `userPrompt`. Prior takes are stripped from the transcript
/// after every turn so they never become conversation history.
///
/// A pooled session is leased to one request at a time. A session throws
/// `concurrentRequests` if asked to respond while it is already responding,
/// and the actor is reentrant across `await`, so without the lease a preview
/// and a real take with the same instructions could share one session (and
/// one would clear the other's history mid-generation). An overlapping
/// request gets a one-off session instead of waiting.
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
    private var leased: Set<Key> = []

    /// Sessions are reused only where the transcript can be cleared between
    /// takes (macOS 27). On 26 `transcript.history` is get-only, so a reused
    /// session would carry every earlier take into the next one, growing
    /// toward the 4,096-token context window and leaking earlier dictations
    /// into later edits. The eval harness flips this to measure reuse.
    nonisolated(unsafe) static var reusesSessions: Bool = {
        if #available(macOS 27, *) { return true }
        return false
    }()

    var entryCount: Int { sessions.count }

    func hasSession(for key: Key) -> Bool {
        sessions[key] != nil
    }

    func isLeased(_ key: Key) -> Bool {
        leased.contains(key)
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

    /// Takes the pooled session for `key` if it is free; nil when another
    /// request holds it. Pair with `release(_:)`.
    func lease<S: Sendable>(_ key: Key, makeSession: @Sendable () -> S) -> S? {
        guard !leased.contains(key) else { return nil }
        leased.insert(key)
        return session(for: key, makeSession: makeSession)
    }

    func release(_ key: Key) {
        leased.remove(key)
    }

    /// Loads the model and caches the instructions' prefix for `key` so the
    /// next take with the same instructions starts warm. Skipped while the
    /// session is responding.
    func prewarm(key: Key, makeSession: @Sendable () -> LanguageModelSession) async {
        guard Self.reusesSessions, !leased.contains(key) else { return }
        let pooled = session(for: key, makeSession: makeSession)
        pooled.prewarm()
    }

    func respond(
        request: FormattingRequest,
        variant: String,
        makeSession: @Sendable () -> LanguageModelSession
    ) async throws -> String {
        let key = Key(request: request, variant: variant)
        let pooled = Self.reusesSessions ? lease(key, makeSession: makeSession) : nil
        let session = pooled ?? makeSession()
        defer {
            if pooled != nil {
                forgetPriorTakes(on: session)
                release(key)
            }
        }
        let started = ContinuousClock.now
        do {
            let response = try await session.respond(
                to: Self.respondInput(for: request),
                options: AppleIntelligenceCleanupEngine.generationOptions(for: request)
            )
            Self.log.info(
                "respond variant=\(variant, privacy: .public) \(started.duration(to: .now)) pooled=\(pooled != nil) entries=\(self.sessions.count)"
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // A session that overflowed or failed mid-turn may hold a
            // partial transcript; start the next take on a fresh one.
            if pooled != nil { sessions[key] = nil }
            throw error
        }
    }

    func invalidate(variant: String) {
        sessions = sessions.filter { $0.key.variant != variant }
        Self.log.info("invalidate variant=\(variant, privacy: .public) entries=\(self.sessions.count)")
    }

    /// macOS 27 can rewrite `transcript.history`; sessions are only pooled
    /// there (see `reusesSessions`).
    private func forgetPriorTakes(on session: LanguageModelSession) {
        if #available(macOS 27, *) {
            session.transcript.history = []
        }
    }
}
