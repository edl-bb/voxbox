import Foundation

/// A backend that can execute one transcript-cleanup request. The pipeline
/// picks an engine per request via `CleanupEngineFactory`, so runtimes can
/// be added or swapped without touching the cleanup chain.
nonisolated protocol CleanupEngine {
    /// Whether the engine can run right now (model present, OS support, …).
    var isAvailable: Bool { get }
    /// Human name for outcomes and previews ("Apple Intelligence").
    var displayName: String { get }
    /// Runs the request and returns the raw model output (the caller strips
    /// preambles, tidies, and applies the guardrail).
    func cleanup(_ request: FormattingRequest) async throws -> String
    /// Loads the model and caches `request`'s instructions so the next
    /// `cleanup` with the same instructions starts warm. Best effort.
    func prewarm(_ request: FormattingRequest) async
}

extension CleanupEngine {
    func prewarm(_ request: FormattingRequest) async {}
}

nonisolated enum CleanupEngineError: Error, Equatable {
    /// The model's own content filter rejected the request. Stepping down
    /// will not help: the input is what was rejected.
    case contentFilter
    /// No reply within the take's deadline. A safety net: if the model
    /// service hangs, the take ships the instant pass instead of waiting.
    case timedOut
}

/// Races an async call against a timer without needing the call to honour
/// cancellation: a stalled `respond` is abandoned, not awaited. The pooled
/// session it holds stays leased until it finishes, so later takes get a
/// fresh one.
nonisolated enum CleanupDeadline {
    static func run<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            // Detached: a timer that inherits the main actor cannot fire while
            // the main thread is busy.
            let work = Task.detached {
                do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
            }
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled, gate.resume(.failure(CleanupEngineError.timedOut)) {
                    work.cancel()
                }
            }
            gate.onResume = { timer.cancel() }
        }
    }

    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        var onResume: (() -> Void)?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            let after = onResume
            lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result)
            after?()
            return true
        }
    }
}
