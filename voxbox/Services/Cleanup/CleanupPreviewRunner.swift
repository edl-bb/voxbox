import Combine
import Foundation

/// Runs previews one at a time, caches by text and option, and publishes a
/// per-card state so a comparison UI fills in progressively. Shared by the
/// onboarding cleanup step and the ruleset test panel.
@MainActor
final class CleanupPreviewRunner: ObservableObject {
    enum State: Equatable {
        case idle
        case queued
        case running
        case done(TranscriptCleanupOutcome)
        case failed(String)

        var isBusy: Bool { self == .queued || self == .running }
    }

    struct Key: Hashable {
        var text: String
        var option: CleanupOption
    }

    @Published private(set) var states: [Key: State] = [:]
    private var cache: [Key: TranscriptCleanupOutcome] = [:]
    private var task: Task<Void, Never>?

    /// Injectable so views can be exercised without a model.
    var preview: @MainActor (String, CleanupOption) async -> TranscriptCleanupOutcome = { text, option in
        await TranscriptCleanupPreview.preview(
            text: text, option: option, includeMarkdown: false, allowStepDown: false)
    }

    var isRunning: Bool { task != nil }

    func state(for option: CleanupOption, text: String) -> State {
        states[Key(text: text, option: option)] ?? .idle
    }

    func outcome(for option: CleanupOption, text: String) -> TranscriptCleanupOutcome? {
        if case .done(let outcome) = state(for: option, text: text) { return outcome }
        return nil
    }

    /// Cancels any run in flight, serves cached results immediately, and
    /// runs the rest in order.
    func run(text: String, options: [CleanupOption]) {
        cancel()
        var pending: [CleanupOption] = []
        for option in options {
            let key = Key(text: text, option: option)
            if let cached = cache[key] {
                states[key] = .done(cached)
            } else {
                states[key] = .queued
                pending.append(option)
            }
        }
        guard !pending.isEmpty else { return }
        task = Task { [weak self] in
            for option in pending {
                guard let self, !Task.isCancelled else { return }
                let key = Key(text: text, option: option)
                self.states[key] = .running
                let outcome = await self.preview(text, option)
                guard !Task.isCancelled else { return }
                self.cache[key] = outcome
                self.states[key] = .done(outcome)
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        for (key, state) in states where state.isBusy {
            states[key] = .idle
        }
    }

    /// Drop cached results (a ruleset edit changes what "custom" means).
    func invalidate() {
        cancel()
        cache.removeAll()
        states.removeAll()
    }
}
