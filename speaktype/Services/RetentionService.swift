import Foundation

/// Automatic local data retention.
///
/// Recorded WAV files are the most sensitive artifact the app produces, so
/// they auto-delete after a configurable period (default: 1 day) while the
/// text transcript is retained. Transcripts themselves can also expire
/// (default: 30 days). Statistics are always kept — they contain word counts
/// and durations, never content.
///
/// The purge runs at launch, then hourly, and everything happens locally.
final class RetentionService {
    static let shared = RetentionService()

    // MARK: - Settings

    static let audioRetentionKey = "audioRetentionSeconds"
    static let transcriptRetentionKey = "transcriptRetentionSeconds"

    /// Sentinel meaning "keep forever".
    static let keepForever: TimeInterval = 0

    static let defaultAudioRetention: TimeInterval = 24 * 60 * 60  // 1 day
    static let defaultTranscriptRetention: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    /// Choices offered in Settings for how long recordings (WAV files) live.
    static let audioOptions: [(label: String, seconds: TimeInterval)] = [
        ("1 hour", 60 * 60),
        ("6 hours", 6 * 60 * 60),
        ("1 day", defaultAudioRetention),
        ("3 days", 3 * 24 * 60 * 60),
        ("7 days", 7 * 24 * 60 * 60),
        ("Forever", keepForever),
    ]

    /// Choices offered in Settings for how long transcripts live.
    static let transcriptOptions: [(label: String, seconds: TimeInterval)] = [
        ("7 days", 7 * 24 * 60 * 60),
        ("30 days", defaultTranscriptRetention),
        ("90 days", 90 * 24 * 60 * 60),
        ("Forever", keepForever),
    ]

    static var audioRetention: TimeInterval {
        get {
            UserDefaults.standard.object(forKey: audioRetentionKey) as? TimeInterval
                ?? defaultAudioRetention
        }
        set { UserDefaults.standard.set(newValue, forKey: audioRetentionKey) }
    }

    static var transcriptRetention: TimeInterval {
        get {
            UserDefaults.standard.object(forKey: transcriptRetentionKey) as? TimeInterval
                ?? defaultTranscriptRetention
        }
        set { UserDefaults.standard.set(newValue, forKey: transcriptRetentionKey) }
    }

    static func label(for seconds: TimeInterval, in options: [(label: String, seconds: TimeInterval)])
        -> String
    {
        options.first(where: { $0.seconds == seconds })?.label ?? "Custom"
    }

    // MARK: - Lifecycle

    private var timer: Timer?
    private static let sweepInterval: TimeInterval = 60 * 60  // hourly

    private init() {}

    /// Purge immediately and keep purging on an hourly timer. Call once at launch.
    func start() {
        purgeNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) {
            [weak self] _ in
            self?.purgeNow()
        }
        // Keep firing while menus are open / the app is otherwise busy.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func purgeNow(now: Date = Date()) {
        let audioCutoff = Self.cutoff(for: Self.audioRetention, now: now)
        let transcriptCutoff = Self.cutoff(for: Self.transcriptRetention, now: now)

        DispatchQueue.main.async {
            HistoryService.shared.applyRetention(
                audioCutoff: audioCutoff, transcriptCutoff: transcriptCutoff)
            self.sweepOrphanedFiles(audioCutoff: audioCutoff)
        }
    }

    static func cutoff(for retention: TimeInterval, now: Date = Date()) -> Date? {
        guard retention > 0 else { return nil }
        return now.addingTimeInterval(-retention)
    }

    // MARK: - Orphan sweep

    /// Delete recording files on disk that history no longer references (or that
    /// outlived the audio retention window), and stale temp chunks. Chunk files
    /// are transcription scratch space and should never survive long; anything
    /// older than an hour is left over from a crash or interrupted recording.
    private func sweepOrphanedFiles(audioCutoff: Date?, now: Date = Date()) {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = appSupport.first?.appendingPathComponent("SpeakType") else { return }

        let referencedPaths = Set(
            HistoryService.shared.items.compactMap { $0.audioFileURL?.standardizedFileURL.path })

        // Recordings: delete anything unreferenced past the cutoff. Unreferenced
        // recent files are kept — they may belong to an in-flight transcription.
        if let audioCutoff {
            deleteFiles(
                in: base.appendingPathComponent("Recordings"),
                olderThan: audioCutoff,
                skippingPaths: referencedPaths)
        }

        // Chunks: temp files, always swept after an hour regardless of settings.
        deleteFiles(
            in: base.appendingPathComponent("Chunks"),
            olderThan: now.addingTimeInterval(-60 * 60),
            skippingPaths: [])
    }

    private func deleteFiles(in directory: URL, olderThan cutoff: Date, skippingPaths: Set<String>) {
        let fileManager = FileManager.default
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return }

        for file in files {
            let path = file.standardizedFileURL.path
            guard !skippingPaths.contains(path) else { continue }
            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
