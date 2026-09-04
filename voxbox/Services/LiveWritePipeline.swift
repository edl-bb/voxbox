import Foundation

/// Serialises live snapshot writes. Latest snapshot wins: while one write is
/// in flight (or the gap after it is still running) newer snapshots replace
/// the pending one rather than queueing, so the field is never written from
/// inside another write and never gets more than one write per gap.
@MainActor
final class LiveWritePipeline {
    typealias Write = @MainActor (SequencedSnapshot) -> Void

    static let defaultGap: Duration = .milliseconds(80)

    private let write: Write
    private let gap: Duration
    private var pending: SequencedSnapshot?
    private var drainTask: Task<Void, Never>?
    private var accepting = true
    private var isWriting = false

    /// Diagnostics.
    private(set) var writeCount = 0
    private(set) var coalescedCount = 0
    private(set) var droppedCount = 0
    private(set) var reentrantEnqueues = 0
    private(set) var lastWrittenSeq: Int?

    init(gap: Duration = LiveWritePipeline.defaultGap, write: @escaping Write) {
        self.gap = gap
        self.write = write
    }

    /// Accept snapshots again after a `quiesce()`.
    func resume() {
        accepting = true
        writeCount = 0
        coalescedCount = 0
        droppedCount = 0
        reentrantEnqueues = 0
        lastWrittenSeq = nil
    }

    func enqueue(_ snapshot: SequencedSnapshot) {
        guard accepting else {
            droppedCount += 1
            return
        }
        if let lastWrittenSeq, snapshot.seq <= lastWrittenSeq {
            // Older than what is already in the field.
            droppedCount += 1
            return
        }
        if isWriting { reentrantEnqueues += 1 }
        if let pending, pending.seq >= snapshot.seq {
            droppedCount += 1
            return
        }
        if pending != nil { coalescedCount += 1 }
        pending = snapshot
        startDrainIfNeeded()
    }

    /// Stop accepting and drop anything pending. Writes are synchronous on
    /// the main actor, so after this returns from a main-actor caller no
    /// write is in flight; the drain task only has its sleep left.
    func stop() {
        accepting = false
        pending = nil
        drainTask?.cancel()
    }

    /// `stop()` and wait for the drain task to exit. After this returns
    /// nothing else touches the field until `resume()`.
    func quiesce() async {
        stop()
        guard let task = drainTask else { return }
        await task.value
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.takePending() {
                self.isWriting = true
                self.write(next)
                self.isWriting = false
                self.writeCount += 1
                self.lastWrittenSeq = next.seq
                if Task.isCancelled { break }
                try? await Task.sleep(for: self.gap)
                if Task.isCancelled { break }
            }
            self.drainTask = nil
        }
    }

    private func takePending() -> SequencedSnapshot? {
        defer { pending = nil }
        return pending
    }
}
