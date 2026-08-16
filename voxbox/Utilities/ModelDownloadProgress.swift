import Foundation

/// Live phase of a model fetch. FluidAudio reports listing → download
/// (capped at 50%) → compile; we remap that into one monotonic bar.
enum ModelDownloadPhase: Equatable, Sendable {
    case listing
    case downloading(completedFiles: Int, totalFiles: Int)
    case preparing(fileName: String)
}

struct ModelDownloadStatus: Equatable, Sendable {
    var fraction: Double = 0
    var phase: ModelDownloadPhase = .listing
    var bytesPerSecond: Double = 0
    var eta: TimeInterval?
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// True when a chunk is still in flight but FluidAudio has gone quiet.
    var isAwaitingChunk = false

    var title: String {
        switch phase {
        case .listing:
            return "Finding files…"
        case .downloading where totalBytes > 0:
            return ModelDownloadFormatting.bytesTitle(received: receivedBytes, total: totalBytes)
        case .downloading:
            return "Downloading…"
        case .preparing(let name) where name.isEmpty:
            return "Preparing files…"
        case .preparing(let name):
            return "Preparing \(ModelDownloadFormatting.shortFileName(name))…"
        }
    }

    var subtitle: String {
        switch phase {
        case .listing:
            if totalBytes > 0 {
                return "About \(ModelDownloadFormatting.formatBytes(totalBytes)) to fetch"
            }
            return "Checking what needs to be fetched"
        case .downloading(let done, let total):
            var parts: [String] = []
            if total > 0 {
                let current = min(max(done + (done < total ? 1 : 0), 1), total)
                parts.append("\(current) of \(total) files")
            }
            let rate = isAwaitingChunk
                ? ModelDownloadFormatting.staleRateLine(bytesPerSecond: bytesPerSecond, eta: eta)
                : ModelDownloadFormatting.rateLine(bytesPerSecond: bytesPerSecond, eta: eta)
            if !rate.isEmpty { parts.append(rate) }
            return parts.joined(separator: " · ")
        case .preparing:
            return "Compiling the model for this Mac"
        }
    }
}

enum ModelDownloadFormatting {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func rateLine(bytesPerSecond: Double, eta: TimeInterval?) -> String {
        guard bytesPerSecond > 500 else { return "" }
        let speed = formatSpeed(bytesPerSecond)
        if let eta, eta.isFinite, eta > 1 {
            return "\(speed) · \(formatETA(eta))"
        }
        return speed
    }

    static func staleRateLine(bytesPerSecond: Double, eta: TimeInterval?) -> String {
        let rate = rateLine(bytesPerSecond: bytesPerSecond, eta: eta)
        guard !rate.isEmpty else { return "" }
        return "\(rate) · still receiving"
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1_048_576 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
    }

    static func formatETA(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 10 { return "a few seconds left" }
        if s < 60 { return "about \(s)s left" }
        let minutes = s / 60
        if minutes == 1 { return "about 1 min left" }
        if minutes < 60 { return "about \(minutes) min left" }
        return "over an hour left"
    }

    static func shortFileName(_ fileName: String) -> String {
        let base = fileName.replacingOccurrences(of: ".mlmodelc", with: "")
        if base.lowercased().hasPrefix("joint") { return "Joint" }
        return base
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func bytesTitle(received: Int64, total: Int64) -> String {
        "\(formatBytes(received)) of \(formatBytes(total))"
    }
}

/// Whether a just-finished download should keep the green “ready to use” state.
enum ModelDownloadCompletion {
    static func isHighlighted(
        downloaded: Bool,
        active: Bool,
        recentlyCompleted: Bool
    ) -> Bool {
        downloaded && recentlyCompleted && !active
    }
}

/// Ease-in-out used to walk the bar and counts between download samples.
enum DownloadProgressEasing {
    static let duration: TimeInterval = 0.5

    static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func interpolate(
        from: Double,
        to: Double,
        elapsed: TimeInterval,
        duration: TimeInterval = DownloadProgressEasing.duration
    ) -> Double {
        guard duration > 0 else { return to }
        return from + (to - from) * smoothstep(elapsed / duration)
    }
}

struct DownloadRateEstimator {
    var samples: [(t: TimeInterval, fraction: Double)] = []
    var lastGood: (bps: Double, eta: TimeInterval?) = (0, nil)
    var window: TimeInterval = 8

    mutating func add(
        fraction: Double,
        at time: TimeInterval,
        expectedBytes: Int64
    ) -> (bps: Double, eta: TimeInterval?) {
        samples.append((time, fraction))
        samples.removeAll { time - $0.t > window }
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return lastGood
        }
        if samples.count >= 2 {
            let previous = samples[samples.count - 2]
            let step = last.fraction - previous.fraction
            if step < 0.0002, last.t - previous.t < 1 {
                return lastGood
            }
        }
        let dt = last.t - first.t
        let delta = last.fraction - first.fraction
        guard dt >= 0.4, delta > 0.0002, expectedBytes > 0 else { return lastGood }
        let bps = Double(expectedBytes) * delta / dt
        let remaining = max(0, 1 - last.fraction) * Double(expectedBytes)
        lastGood = (bps, remaining / bps)
        return lastGood
    }
}

/// Speed from a 2–3s window of byte samples. The UI can tick faster
/// than that; the rate itself stays stable.
struct ByteRateEstimator {
    var samples: [(t: TimeInterval, bytes: Int64)] = []
    var lastGood: (bps: Double, eta: TimeInterval?) = (0, nil)
    var window: TimeInterval = 2.5

    mutating func add(
        received: Int64,
        total: Int64,
        at time: TimeInterval
    ) -> (bps: Double, eta: TimeInterval?) {
        samples.append((time, received))
        samples.removeAll { time - $0.t > window }
        guard let first = samples.first, let last = samples.last else { return lastGood }
        let dt = last.t - first.t
        let delta = last.bytes - first.bytes
        guard dt >= 1.8, delta > 0, total > 0 else { return lastGood }
        let bps = Double(delta) / dt
        let remaining = max(0, Double(total - received))
        lastGood = (bps, bps > 0 ? remaining / bps : nil)
        return lastGood
    }
}

/// Turns FluidAudio/WhisperKit callbacks into a bar that only moves forward
/// and a label that matches the real work (download vs compile).
struct ModelDownloadProgressReducer {
    var status = ModelDownloadStatus()
    private var downloadCompleted = false
    private var lastDownloadMapped = 0.0
    private var preparedNames: Set<String> = []
    private var estimator = DownloadRateEstimator()
    private var byteEstimator = ByteRateEstimator()
    private var lastEventAt: TimeInterval = -1
    private var manifestFileCount = 0

    mutating func applyManifest(_ manifest: ModelDownloadManifest) {
        status.totalBytes = max(status.totalBytes, manifest.totalBytes)
        manifestFileCount = max(manifestFileCount, manifest.fileCount)
    }

    /// Byte-weighted tick used for the 2–3s UI refresh.
    mutating func applyTick(
        phase: ModelDownloadPhase,
        receivedBytes: Int64,
        totalBytes: Int64,
        now: TimeInterval
    ) {
        let grew = receivedBytes > status.receivedBytes
        status.receivedBytes = max(status.receivedBytes, receivedBytes)
        if totalBytes > 0 {
            status.totalBytes = max(status.totalBytes, totalBytes)
        }

        switch phase {
        case .listing:
            guard !downloadCompleted else { return }
            lastEventAt = now
            status.phase = .listing
            status.fraction = max(status.fraction, 0.01)
            status.isAwaitingChunk = false

        case .downloading(let done, let total):
            if downloadCompleted && total == 0 { return }
            let files = total > 0 ? total : manifestFileCount
            status.phase = .downloading(completedFiles: done, totalFiles: files)
            if status.totalBytes > 0 {
                let byteFrac = min(Double(status.receivedBytes) / Double(status.totalBytes), 1)
                lastDownloadMapped = max(lastDownloadMapped, byteFrac)
            } else if files > 0 {
                lastDownloadMapped = max(lastDownloadMapped, Double(min(done, files)) / Double(files))
            }
            if files > 0, done >= files {
                downloadCompleted = true
            }
            status.fraction = max(status.fraction, 0.82 * lastDownloadMapped)
            let rate = byteEstimator.add(
                received: status.receivedBytes, total: status.totalBytes, at: now)
            status.bytesPerSecond = rate.bps
            status.eta = rate.eta
            if grew {
                lastEventAt = now
                status.isAwaitingChunk = false
            }

        case .preparing(let name):
            lastEventAt = now
            downloadCompleted = true
            if !name.isEmpty { preparedNames.insert(name) }
            status.phase = .preparing(fileName: name)
            let steps = max(Double(preparedNames.count), 1)
            let target = 0.82 + 0.18 * min(steps / 4.0, 1)
            status.fraction = max(status.fraction, target)
            status.bytesPerSecond = 0
            status.eta = nil
            status.isAwaitingChunk = false
        }
    }

    mutating func applyFluid(
        fraction: Double,
        phase: ModelDownloadPhase,
        expectedBytes: Int64,
        now: TimeInterval
    ) {
        lastEventAt = now
        status.isAwaitingChunk = false

        switch phase {
        case .listing:
            guard !downloadCompleted else { return }
            status.phase = .listing
            status.fraction = max(status.fraction, 0.01)

        case .downloading(let done, let total):
            // "Already present" stubs after the first fetch: 0.5 with no files.
            if downloadCompleted && total == 0 { return }

            let byteMapped = min(max(fraction / 0.5, 0), 1)
            let fileMapped = total > 0 ? Double(min(done, total)) / Double(total) : 0
            // FluidAudio caps download at 0.5 and can hit that cap early when
            // remote sizes are missing. Keep using file count so the bar
            // still moves through the remaining chunks.
            let mapped: Double
            if total > 0, done < total, byteMapped >= 0.99 {
                mapped = 0.85 + 0.15 * fileMapped
            } else {
                mapped = max(byteMapped, fileMapped)
            }
            lastDownloadMapped = max(lastDownloadMapped, mapped)
            if total > 0, done >= total {
                downloadCompleted = true
            }

            status.phase = .downloading(completedFiles: done, totalFiles: total)
            status.fraction = max(status.fraction, 0.82 * lastDownloadMapped)
            if expectedBytes > 0 {
                status.totalBytes = max(status.totalBytes, expectedBytes)
                let inferred = Int64(lastDownloadMapped * Double(expectedBytes))
                status.receivedBytes = max(status.receivedBytes, inferred)
            }
            let rate = estimator.add(
                fraction: lastDownloadMapped, at: now, expectedBytes: expectedBytes)
            status.bytesPerSecond = rate.bps
            status.eta = rate.eta

        case .preparing(let name):
            downloadCompleted = true
            if !name.isEmpty { preparedNames.insert(name) }
            status.phase = .preparing(fileName: name)
            let steps = max(Double(preparedNames.count), 1)
            let target = 0.82 + 0.18 * min(steps / 4.0, 1)
            status.fraction = max(status.fraction, target)
            status.bytesPerSecond = 0
            status.eta = nil
        }
    }

    mutating func applyWhisper(
        fraction: Double,
        expectedBytes: Int64,
        now: TimeInterval,
        completedUnitCount: Int64 = 0,
        totalUnitCount: Int64 = 0
    ) {
        let raw = fraction.isFinite ? fraction : 0
        let clamped = min(max(raw, 0), 1)
        var mapped = clamped
        let looksLikeFileCount = totalUnitCount > 0 && totalUnitCount <= 10_000
        if looksLikeFileCount, clamped < 0.001, completedUnitCount > 0 {
            mapped = min(Double(completedUnitCount) / Double(totalUnitCount), 1)
        }
        let inferredBytes = expectedBytes > 0 ? Int64(mapped * Double(expectedBytes)) : 0
        let grew = mapped > status.fraction + 0.0001 || inferredBytes > status.receivedBytes
        if grew {
            lastEventAt = now
            status.isAwaitingChunk = false
        }
        status.fraction = max(status.fraction, mapped)
        if expectedBytes > 0 {
            status.totalBytes = max(status.totalBytes, expectedBytes)
            status.receivedBytes = max(status.receivedBytes, inferredBytes)
        }

        if mapped >= 0.98 {
            lastEventAt = now
            status.phase = .preparing(fileName: "")
            status.bytesPerSecond = 0
            status.eta = nil
            status.isAwaitingChunk = false
        } else {
            let files = looksLikeFileCount ? Int(totalUnitCount) : 0
            let done = looksLikeFileCount ? Int(min(max(completedUnitCount, 0), totalUnitCount)) : 0
            status.phase = .downloading(completedFiles: done, totalFiles: files)
            let rate = estimator.add(fraction: mapped, at: now, expectedBytes: expectedBytes)
            status.bytesPerSecond = rate.bps
            status.eta = rate.eta
        }
    }

    /// Shared entry used by the 0.4s UI poll so Whisper tracks the real
    /// 0–1 fraction instead of the Parakeet byte-mapped 0.82 cap.
    mutating func applyDownloadSample(
        whisper: Bool,
        fraction: Double,
        phase: ModelDownloadPhase,
        receivedBytes: Int64,
        totalBytes: Int64,
        expectedBytes: Int64,
        now: TimeInterval
    ) {
        if whisper {
            applyWhisper(
                fraction: fraction,
                expectedBytes: expectedBytes,
                now: now,
                completedUnitCount: receivedBytes,
                totalUnitCount: totalBytes
            )
            return
        }
        applyTick(
            phase: phase,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes > 0 ? totalBytes : expectedBytes,
            now: now
        )
    }

    /// Called on a 1s heartbeat so a silent large-file transfer still refreshes.
    @discardableResult
    mutating func tick(now: TimeInterval) -> Bool {
        guard case .downloading = status.phase else { return false }
        let stale = lastEventAt >= 0 && (now - lastEventAt) >= 1.5
        guard stale != status.isAwaitingChunk else { return false }
        status.isAwaitingChunk = stale
        return true
    }

    mutating func finish() {
        status.fraction = 1
        status.phase = .preparing(fileName: "")
        status.bytesPerSecond = 0
        status.eta = nil
        status.isAwaitingChunk = false
    }
}

/// Per-variant values passed into model cards so unchanged rows can skip `body`.
struct ModelDownloadSnapshot: Equatable {
    var progress: Double
    var isDownloading: Bool
    var status: ModelDownloadStatus?
    var recentlyCompleted: Bool
    var error: String?

    static func make(progress: Double, isDownloading: Bool, status: ModelDownloadStatus?, recentlyCompleted: Bool, error: String?) -> ModelDownloadSnapshot {
        ModelDownloadSnapshot(
            progress: progress,
            isDownloading: isDownloading,
            status: status,
            recentlyCompleted: recentlyCompleted,
            error: error
        )
    }
}
