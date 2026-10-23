import Foundation
import FoundationModels

/// `cleanup-eval --probe-sessions N`: does a pooled session stay the same
/// size when its history is cleared between takes? Sends N Light requests
/// through one session (clearing history after each, as the pool does) and
/// N through fresh sessions, and prints latency and transcript size.
enum SessionProbe {
    @MainActor
    static func run(count: Int) async {
        let text = "Um, so I was thinking we could, you know, maybe push the launch back a week, just because the onboarding flow isn't really ready yet and Jules is away."
        let request = CleanupRequestBuilder.request(for: text, intensity: .lightCleanup, includeMarkdown: false, language: "en-AU", promptSet: .v3)
        let model = AppleIntelligenceCleanupEngine.systemModel
        let stages = request.instructionStages
        let options = AppleIntelligenceCleanupEngine.generationOptions(for: request)

        print("Reused session, history cleared after each take:")
        let reused = LanguageModelSession(model: model) { stages }
        for i in 1...count {
            let start = ContinuousClock.now
            do {
                _ = try await reused.respond(to: request.userPrompt, options: options)
                let entriesBefore = reused.transcript.count
                if #available(macOS 27, *) { reused.transcript.history = [] }
                print(String(format: "  take %2d  %5d ms  transcript entries %d → %d", i, ms(since: start), entriesBefore, reused.transcript.count))
            } catch {
                print(String(format: "  take %2d  %5d ms  ERROR %@", i, ms(since: start), String(describing: error)))
            }
        }

        print("Fresh session per take:")
        for i in 1...min(count, 10) {
            let start = ContinuousClock.now
            let fresh = LanguageModelSession(model: model) { stages }
            do {
                _ = try await fresh.respond(to: request.userPrompt, options: options)
                print(String(format: "  take %2d  %5d ms", i, ms(since: start)))
            } catch {
                print(String(format: "  take %2d  %5d ms  ERROR %@", i, ms(since: start), String(describing: error)))
            }
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now)
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
