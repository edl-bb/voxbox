import Foundation

/// Owns one live take: engine updates, destination field writes, HUD snapshot.
///
/// Lifecycle: `idle → binding → streaming → finalizing → idle`. Snapshots
/// are only applied while streaming and only for the current take, so a
/// hop that lands after `finish()` started (or after a cancel) is dropped.
/// Writes go through `LiveWritePipeline`, which serialises them and lets
/// the newest snapshot win, so the field is never written re-entrantly.
@MainActor
@Observable
final class LiveDictationSession {
    static let shared = LiveDictationSession()

    enum Phase: Equatable {
        case idle
        case binding
        case streaming
        case finalizing
    }

    private(set) var snapshot = LiveTranscriptSnapshot.empty
    private(set) var phase: Phase = .idle
    /// How words are reaching the destination during this take.
    private(set) var deliveryMode: LiveDeliveryMode = .none

    @ObservationIgnored private let inserter = TargetFieldInserter()
    @ObservationIgnored private var pipeline: LiveWritePipeline?
    @ObservationIgnored private var takeID = 0
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var language = "auto"

    private init() {
        pipeline = LiveWritePipeline { [weak self] sequenced in
            self?.write(sequenced)
        }
    }

    var isLive: Bool { phase != .idle }

    /// True when every word (stable and revisable) is going into the field.
    var writingToField: Bool { deliveryMode == .fullText }

    /// Words the pill should show: everything when nothing reaches the
    /// field, only the not-yet-typed tail when we type stable words.
    var hudText: String {
        switch deliveryMode {
        case .fullText: return ""
        case .stableOnly: return snapshot.revisable
        case .none: return snapshot.fullText
        }
    }

    /// The pill draws the two halves differently: locked words plainly,
    /// words the engine may still revise dimmed. When stable words are being
    /// typed into the field they are not repeated in the pill.
    var hudStableText: String {
        switch deliveryMode {
        case .fullText, .stableOnly: return ""
        case .none: return snapshot.stable
        }
    }

    var hudRevisableText: String {
        switch deliveryMode {
        case .fullText: return ""
        case .none: return snapshot.revisable
        case .stableOnly: return Self.dropping(promotedPrefix, from: snapshot.revisable)
        }
    }

    // MARK: - Early promotion (keystroke targets)

    /// Revisable text seen during this commit block, oldest first.
    @ObservationIgnored private var revisableSamples: [StablePromotion.Sample] = []
    /// Words from the revisable tail already handed to the field.
    private(set) var promotedPrefix = ""

    /// What the field should hold: the engine's committed text plus the
    /// words that have sat unchanged long enough to type early.
    var effectiveStable: String {
        LiveTranscriptSnapshot.join(snapshot.stable, promotedPrefix)
    }

    private func trackPromotion(_ next: LiveTranscriptSnapshot, now: Date = Date()) {
        if next.stable != snapshot.stable {
            // The engine committed a block; the revisable tail restarts.
            revisableSamples.removeAll()
            promotedPrefix = ""
        }
        revisableSamples.append(StablePromotion.Sample(time: now, revisable: next.revisable))
        if revisableSamples.count > 64 { revisableSamples.removeFirst(revisableSamples.count - 64) }
        guard deliveryMode == .stableOnly else {
            promotedPrefix = ""
            return
        }
        let candidate = StablePromotion.promotedPrefix(samples: revisableSamples, current: next.revisable, now: now)
        // Never hand back words already typed; if the engine revised one of
        // them the inserter's divergence path keeps the take flowing.
        if candidate.count > promotedPrefix.count || !candidate.hasPrefix(promotedPrefix) {
            promotedPrefix = candidate
        }
    }

    private func resetPromotion() {
        revisableSamples.removeAll()
        promotedPrefix = ""
    }

    nonisolated static func dropping(_ prefix: String, from text: String) -> String {
        guard !prefix.isEmpty, text.hasPrefix(prefix) else { return text }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Lifecycle

    func start(language: String) async throws {
        cancel()
        takeID += 1
        let take = takeID
        seq = 0
        self.language = language
        snapshot = .empty
        resetPromotion()
        phase = .binding
        pipeline?.resume()

        _ = await inserter.begin()
        guard takeID == take, phase == .binding else {
            inserter.reset()
            return
        }
        deliveryMode = inserter.deliveryMode
        phase = .streaming
        AppLogger.info("live take=\(take) start mode=\(deliveryMode)", category: AppLogger.transcription)

        do {
            try await TranscriptionManager.shared.startLive(
                language: language,
                onUpdate: { [take] next in
                    LiveDictationSession.shared.apply(next, take: take)
                }
            )
        } catch {
            if takeID == take {
                pipeline?.stop()
                inserter.reset()
                deliveryMode = .none
                phase = .idle
            }
            throw error
        }
    }

    /// Engine hop. Runs on the main actor in arrival order; the pipeline
    /// decides when it reaches the field.
    func apply(_ next: LiveTranscriptSnapshot, take: Int) {
        guard take == takeID, phase == .streaming else {
            log("take=\(take) drop reason=\(take == takeID ? "phase:\(phase)" : "staleTake")")
            return
        }
        trackPromotion(next)
        snapshot = next
        seq += 1
        guard inserter.isActive else { return }
        pipeline?.enqueue(SequencedSnapshot(take: take, seq: seq, snapshot: next))
    }

    private func write(_ sequenced: SequencedSnapshot) {
        guard sequenced.take == takeID, phase == .streaming else { return }
        // Latest-wins: the promoted prefix belongs to the current snapshot.
        let stable = sequenced.snapshot == snapshot ? effectiveStable : sequenced.snapshot.stable
        let input = LiveWriteInput(fullText: sequenced.snapshot.fullText, stable: stable)
        let outcome = inserter.update(input)
        deliveryMode = inserter.deliveryMode
        log(
            "take=\(sequenced.take) seq=\(sequenced.seq) stable=\((input.stable as NSString).length) "
                + "full=\((input.fullText as NSString).length) outcome=\(outcome)")
    }

    func finish() async throws -> (text: String, delivery: LiveDelivery) {
        guard phase == .streaming else { return ("", .notWritten) }
        let take = takeID
        phase = .finalizing
        await pipeline?.quiesce()

        let raw: String
        do {
            raw = try await TranscriptionManager.shared.finishLive()
        } catch {
            raw = snapshot.fullText
            if raw.isEmpty {
                if takeID == take {
                    inserter.revert()
                    deliveryMode = .none
                    phase = .idle
                }
                throw error
            }
        }
        let cleaned = await Self.clean(raw, language: language)
        lastRawTranscript = raw

        // Cancelled while we were waiting on the engine or the cleanup: the
        // field has already been reverted, nothing more to do to it.
        guard takeID == take, phase == .finalizing else {
            return (cleaned, .notWritten)
        }

        let delivery = inserter.isActive
            ? inserter.finalize(raw: raw, cleaned: cleaned)
            : .notWritten
        let pipelineStats = pipeline.map {
            "writes=\($0.writeCount) coalesced=\($0.coalescedCount) dropped=\($0.droppedCount) reentrant=\($0.reentrantEnqueues)"
        } ?? ""
        AppLogger.info(
            "live take=\(take) finalize raw=\((raw as NSString).length) cleaned=\((cleaned as NSString).length) "
                + "result=\(delivery) \(pipelineStats)",
            category: AppLogger.transcription)
        deliveryMode = .none
        phase = .idle
        snapshot = LiveTranscriptSnapshot(stable: cleaned, revisable: "")
        resetPromotion()
        return (cleaned, delivery)
    }

    func cancel() {
        guard phase != .idle || inserter.isActive else {
            snapshot = .empty
        resetPromotion()
            return
        }
        let take = takeID
        takeID += 1
        pipeline?.stop()
        TranscriptionManager.shared.cancelLive()
        inserter.revert()
        deliveryMode = .none
        phase = .idle
        snapshot = .empty
        resetPromotion()
        log("take=\(take) cancel")
    }

    // MARK: - Cleanup chain

    /// Raw engine text of the last finished take, for History.
    private(set) var lastRawTranscript = ""

    private static func clean(_ text: String, language: String) async -> String {
        let outcome = await TranscriptCleanupPipeline.shared.clean(
            raw: text, plan: .fromSettings(language: language))
        return outcome.output
    }

    private func log(_ message: String) {
        AppLogger.debug("live \(message)", category: AppLogger.transcription)
    }
}
