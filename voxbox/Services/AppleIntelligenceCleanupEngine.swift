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
    /// rulesets keep their own temperature. Never cap response tokens: a
    /// cap truncates silently.
    static func generationOptions(for request: FormattingRequest) -> GenerationOptions {
        if request.temperature <= 0 {
            return GenerationOptions(samplingMode: .greedy)
        }
        return GenerationOptions(temperature: request.temperature)
    }

    /// Cleanup edits the user's own words, which is exactly what Apple's
    /// `permissiveContentTransformations` guardrail is for. The default
    /// guardrail refuses ordinary dictation that merely mentions a sensitive
    /// word ("look at this pill").
    static var systemModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
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
