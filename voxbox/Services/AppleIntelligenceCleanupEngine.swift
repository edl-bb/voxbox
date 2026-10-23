import Foundation
import FoundationModels

/// Apple FoundationModels — the ~3B system model that ships with macOS 26.
nonisolated struct AppleIntelligenceCleanupEngine: CleanupEngine {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var displayName: String {
        PostProcessingModel.catalog.first { $0.variant == PostProcessingModel.appleSystemVariant }?.name
            ?? "Apple Intelligence"
    }

    /// Built-in levels are deterministic: `temperature: 0` alone is not
    /// documented as greedy, so ask for greedy sampling explicitly. Custom
    /// rulesets keep their own temperature.
    static func generationOptions(for request: FormattingRequest) -> GenerationOptions {
        let limit = responseTokenLimit(for: request)
        if request.temperature <= 0 {
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: limit)
        }
        return GenerationOptions(temperature: request.temperature, maximumResponseTokens: limit)
    }

    /// A cleaned take is about as long as the dictation (roughly 1.3 tokens
    /// a word), so the cap leaves well over twice that before it bites. It
    /// exists to stop a runaway: a small model that loops can otherwise
    /// generate until the context window fills (37 s in the macOS 27 eval).
    /// A truncated reply then fails the guardrail's retention floor, which
    /// is the right outcome. Custom rulesets may legitimately expand text, so
    /// they get more room.
    static func responseTokenLimit(for request: FormattingRequest) -> Int {
        let words = request.input.split(whereSeparator: { $0.isWhitespace }).count
        if request.intensity == .custom {
            return max(512, words * 5 + 256)
        }
        return max(256, words * 3 + 128)
    }

    /// Cleanup edits the user's own words, which is exactly what Apple's
    /// `permissiveContentTransformations` guardrail is for. The default
    /// guardrail refuses ordinary dictation that merely mentions a sensitive
    /// word ("look at this pill").
    static var systemModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    func prewarm(_ request: FormattingRequest) async {
        guard isAvailable else { return }
        let model = Self.systemModel
        let stages = request.instructionStages
        await CleanupSessionPool.shared.prewarm(
            key: CleanupSessionPool.Key(request: request, variant: PostProcessingModel.appleSystemVariant)
        ) {
            LanguageModelSession(model: model) {
                stages
            }
        }
    }

    func cleanup(_ request: FormattingRequest) async throws -> String {
        let model = Self.systemModel
        let stages = request.instructionStages
        do {
            return try await CleanupSessionPool.shared.respond(
                request: request,
                variant: PostProcessingModel.appleSystemVariant
            ) {
                LanguageModelSession(model: model) {
                    stages
                }
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw CleanupEngineError.contentFilter
            default:
                throw error
            }
        }
    }
}
