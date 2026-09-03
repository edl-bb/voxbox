import Foundation

/// One model call on the step-down ladder.
nonisolated struct CleanupAttempt: Equatable, Sendable {
    var intensity: FormattingIntensity
    /// Engine that actually answered, after any fallback.
    var engineName: String
    /// Engine the settings asked for.
    var requestedEngineName: String
    /// Straight from the model, before the post-pass.
    var rawOutput: String
    /// After preamble strip and tidy.
    var tidiedOutput: String
    var evaluation: GuardrailEvaluation?
    var verdict: GuardrailVerdict
    var casingAnomaly: Bool
    var durationMs: Int

    var fellBack: Bool { engineName != requestedEngineName }
}

/// Everything a take's cleanup did, for the pill, the DEBUG tuner, the
/// preview panels and the eval harness.
nonisolated struct TranscriptCleanupOutcome: Equatable, Sendable {
    /// Engine text as received.
    var rawInput: String
    /// After spelling, dictionary and Auto Edit: what the model saw.
    var modelInput: String
    /// Final text that gets pasted.
    var output: String
    var requested: CleanupOption
    /// Rung that produced `output`; nil when the raw (deterministic-only) text shipped.
    var landed: FormattingIntensity?
    var attempts: [CleanupAttempt]
    var totalDurationMs: Int
    /// Why the model stage did not run at all, if it did not.
    var skippedReason: String?

    var acceptedAttempt: CleanupAttempt? {
        attempts.last { $0.verdict.isAccepted }
    }
    var engineName: String? { acceptedAttempt?.engineName }
    var requestedEngineName: String? { attempts.first?.requestedEngineName }
    var fellBackToSystemModel: Bool { acceptedAttempt?.fellBack ?? false }
    var changeRatio: Double? { acceptedAttempt?.evaluation?.costRatio }
    var steppedDown: Bool {
        guard let landed, let requested = requested.intensity else { return false }
        return landed != requested
    }
    var guardrailTripped: Bool {
        attempts.contains { !$0.verdict.isAccepted }
    }
    var modelRan: Bool { !attempts.isEmpty }
    var error: String? {
        for attempt in attempts {
            switch attempt.verdict {
            case .engineError(let message): return message
            case .appleContentFilter: return "Apple Intelligence declined this text."
            default: continue
            }
        }
        return nil
    }

    /// Deterministic-only outcome (feature off, too short, unavailable).
    static func withoutModel(
        rawInput: String, modelInput: String, output: String, requested: CleanupOption,
        reason: String?, durationMs: Int
    ) -> TranscriptCleanupOutcome {
        TranscriptCleanupOutcome(
            rawInput: rawInput, modelInput: modelInput, output: output, requested: requested,
            landed: nil, attempts: [], totalDurationMs: durationMs, skippedReason: reason)
    }
}
