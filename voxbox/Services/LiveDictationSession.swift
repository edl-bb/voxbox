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

    // MARK: - Lifecycle

    func start(language: String) async throws {
        cancel()
        takeID += 1
        let take = takeID
        seq = 0
        self.language = language
        snapshot = .empty
        phase = .binding
        pipeline?.resume()

        _ = await inserter.begin()
        guard takeID == take, phase == .binding else {
            inserter.reset()
            return
        }
        deliveryMode = inserter.deliveryMode
        phase = .streaming
        log("take=\(take) start mode=\(deliveryMode)")

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
        snapshot = next
        seq += 1
        guard inserter.isActive else { return }
        pipeline?.enqueue(SequencedSnapshot(take: take, seq: seq, snapshot: next))
    }

    private func write(_ sequenced: SequencedSnapshot) {
        guard sequenced.take == takeID, phase == .streaming else { return }
        let input = LiveWriteInput(sequenced.snapshot)
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
        log(
            "take=\(take) finalize raw=\((raw as NSString).length) cleaned=\((cleaned as NSString).length) "
                + "result=\(delivery) \(pipelineStats)")
        deliveryMode = .none
        phase = .idle
        snapshot = LiveTranscriptSnapshot(stable: cleaned, revisable: "")
        return (cleaned, delivery)
    }

    func cancel() {
        guard phase != .idle || inserter.isActive else {
            snapshot = .empty
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
        log("take=\(take) cancel")
    }

    // MARK: - Cleanup chain

    private static func clean(_ text: String, language: String) async -> String {
        var next = text
        if AustralianEnglishSpelling.isAustralianEnglish(language) {
            next = AustralianEnglishSpelling.apply(to: next)
        }
        next = DictionaryService.apply(to: next)
        next = AutoEdit.apply(to: next)
        if TranscriptFormatterService.shouldFormat(next) {
            NotificationCenter.default.post(name: .transcriptCleanupStarted, object: nil)
            next = await TranscriptFormatterService.shared.format(next)
        }
        return SmartTrailingPunctuation.apply(to: next)
    }

    private func log(_ message: String) {
        AppLogger.debug("live \(message)", category: AppLogger.transcription)
    }
}
