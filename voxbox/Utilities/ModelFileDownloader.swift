import Foundation

enum ModelFileDownloadError: Error, Equatable {
    case destinationOutsideCache
    case httpStatus(Int)
}

/// Hugging Face advertises the current window on `RateLimit`, e.g.
/// `"api";r=0;t=55` — `t=` is seconds until the window resets.
enum HuggingFaceRateLimit {
    nonisolated static func delaySeconds(from header: String) -> TimeInterval? {
        guard let match = header.range(of: #"t=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let token = String(header[match])
        let digits = token.drop { !$0.isNumber }
        return TimeInterval(digits)
    }

    nonisolated static func delaySeconds(fromHeaderFields fields: [AnyHashable: Any]) -> TimeInterval? {
        for (key, value) in fields {
            guard let name = key as? String,
                name.caseInsensitiveCompare("RateLimit") == .orderedSame,
                let header = value as? String
            else { continue }
            return delaySeconds(from: header)
        }
        return nil
    }

    /// One retry after HTTP 429. `attempt` is 0 on the first response.
    nonisolated static func retryDelaySeconds(
        statusCode: Int,
        rateLimitHeader: String?,
        attempt: Int
    ) -> TimeInterval? {
        guard statusCode == 429, attempt == 0 else { return nil }
        return rateLimitHeader.flatMap(delaySeconds(from:)) ?? 1
    }
}

/// Lock-held byte totals for concurrent Parakeet file downloads.
/// Sequential `completedBytes + written` undercounts when several files
/// are in flight at once.
final class ConcurrentDownloadProgress: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var finishedBytes: Int64 = 0
    nonisolated(unsafe) private var inFlight: [String: Int64] = [:]
    nonisolated(unsafe) private var finishedFiles = 0

    nonisolated init() {}

    nonisolated func addFinishedFile(size: Int64) {
        lock.withLock {
            finishedBytes += max(0, size)
            finishedFiles += 1
        }
    }

    nonisolated func setInFlight(path: String, written: Int64) {
        lock.withLock {
            inFlight[path] = max(0, written)
        }
    }

    nonisolated func completeInFlight(path: String, size: Int64) {
        lock.withLock {
            inFlight.removeValue(forKey: path)
            finishedBytes += max(0, size)
            finishedFiles += 1
        }
    }

    nonisolated func snapshot() -> (receivedBytes: Int64, finishedFiles: Int) {
        lock.withLock {
            let flying = inFlight.values.reduce(0, +)
            return (finishedBytes + flying, finishedFiles)
        }
    }
}

/// Downloads one model file and reports raw bytes as they arrive.
/// FluidAudio's handler typically only updates when a file finishes, so
/// VoxBox fetches the large chunks itself with a download-task delegate.
enum ModelFileDownloader {
    nonisolated static let parakeetConcurrencyLimit = 4

    nonisolated static func resolvedDestination(path: String, cacheRoot: URL) throws -> URL {
        let dest = cacheRoot.appendingPathComponent(path).standardizedFileURL
        let root = cacheRoot.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard dest.path == root || dest.path.hasPrefix(prefix) else {
            throw ModelFileDownloadError.destinationOutsideCache
        }
        return dest
    }

    nonisolated static func download(
        from remote: URL,
        relativePath: String,
        cacheRoot: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let dest = try resolvedDestination(path: relativePath, cacheRoot: cacheRoot)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let local = try await downloadWithRateLimitRetry(from: remote, onProgress: onProgress)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: local, to: dest)
    }

    /// Fetch `files` with at most `parakeetConcurrencyLimit` in flight.
    /// Existing files are counted first; progress is the lock-held sum of
    /// finished sizes plus per-file `bytesWritten`.
    nonisolated static func downloadParakeetFiles(
        files: [ModelDownloadManifest.File],
        variant: String,
        cacheRoot: URL,
        onProgress: @escaping @Sendable (_ received: Int64, _ finishedFiles: Int, _ totalFiles: Int) -> Void
    ) async throws {
        let progress = ConcurrentDownloadProgress()
        var pending: [ModelDownloadManifest.File] = []

        for file in files {
            if Task.isCancelled { throw CancellationError() }
            let dest = try resolvedDestination(path: file.path, cacheRoot: cacheRoot)
            if file.size == 0 {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: dest.path, contents: Data())
                progress.addFinishedFile(size: 0)
                continue
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                progress.addFinishedFile(size: max(0, file.size))
                continue
            }
            pending.append(file)
        }

        let totalFiles = files.count
        let initial = progress.snapshot()
        onProgress(initial.receivedBytes, initial.finishedFiles, totalFiles)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func enqueueMore() {
                while inFlight < parakeetConcurrencyLimit, let file = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        try await downloadOneParakeetFile(
                            file,
                            variant: variant,
                            cacheRoot: cacheRoot,
                            progress: progress,
                            totalFiles: totalFiles,
                            onProgress: onProgress
                        )
                    }
                }
            }

            enqueueMore()

            while true {
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                do {
                    guard try await group.next() != nil else { break }
                } catch {
                    group.cancelAll()
                    throw error
                }
                inFlight -= 1
                enqueueMore()
            }
        }
    }

    nonisolated private static func downloadOneParakeetFile(
        _ file: ModelDownloadManifest.File,
        variant: String,
        cacheRoot: URL,
        progress: ConcurrentDownloadProgress,
        totalFiles: Int,
        onProgress: @escaping @Sendable (Int64, Int, Int) -> Void
    ) async throws {
        let remote = try HuggingFaceModelManifest.remoteURL(for: file.path, variant: variant)
        try await download(
            from: remote,
            relativePath: file.path,
            cacheRoot: cacheRoot
        ) { written, _ in
            progress.setInFlight(path: file.path, written: written)
            let snap = progress.snapshot()
            onProgress(snap.receivedBytes, snap.finishedFiles, totalFiles)
        }
        let finishedSize: Int64
        if file.size > 0 {
            finishedSize = file.size
        } else if let dest = try? resolvedDestination(path: file.path, cacheRoot: cacheRoot),
            let size = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            finishedSize = Int64(size)
        } else {
            finishedSize = 0
        }
        progress.completeInFlight(path: file.path, size: finishedSize)
        let snap = progress.snapshot()
        onProgress(snap.receivedBytes, snap.finishedFiles, totalFiles)
    }

    nonisolated private static func downloadWithRateLimitRetry(
        from remote: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let first = try await SharedModelDownloadSession.shared.download(
            from: remote,
            onProgress: onProgress
        )
        if (200...299).contains(first.statusCode) {
            return first.fileURL
        }
        try? FileManager.default.removeItem(at: first.fileURL)
        if let delay = HuggingFaceRateLimit.retryDelaySeconds(
            statusCode: first.statusCode,
            rateLimitHeader: first.rateLimitHeader,
            attempt: 0
        ) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { throw CancellationError() }
            let retry = try await SharedModelDownloadSession.shared.download(
                from: remote,
                onProgress: onProgress
            )
            if (200...299).contains(retry.statusCode) {
                return retry.fileURL
            }
            try? FileManager.default.removeItem(at: retry.fileURL)
            throw ModelFileDownloadError.httpStatus(retry.statusCode)
        }
        throw ModelFileDownloadError.httpStatus(first.statusCode)
    }
}

struct SharedDownloadResult: Sendable {
    var fileURL: URL
    var statusCode: Int
    var rateLimitHeader: String?
}

/// Resumes a throwing continuation at most once so cancel, success, and
/// error races cannot leak or double-resume.
final class OnceThrowingContinuation<Value: Sendable>: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<Value, Error>?

    nonisolated init() {}

    nonisolated func arm(_ continuation: CheckedContinuation<Value, Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    nonisolated func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    nonisolated func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    nonisolated private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
    }
}

/// One ephemeral session, many `downloadTask`s. Do not invalidate the session
/// after each file — that used to leak continuations and hang later downloads.
final class SharedModelDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SharedModelDownloadSession()

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var states: [Int: DownloadState] = [:]

    private struct DownloadState {
        var onProgress: @Sendable (Int64, Int64) -> Void
        var gate: OnceThrowingContinuation<SharedDownloadResult>
        var copied: URL?
        var statusCode = 200
        var rateLimitHeader: String?
    }

    private override init() {
        super.init()
    }

    private lazy var liveSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 30
        config.httpMaximumConnectionsPerHost = ModelFileDownloader.parakeetConcurrencyLimit
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    nonisolated func download(
        from remote: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> SharedDownloadResult {
        let task = liveSession.downloadTask(with: remote)
        let gate = OnceThrowingContinuation<SharedDownloadResult>()
        lock.withLock {
            states[task.taskIdentifier] = DownloadState(onProgress: onProgress, gate: gate)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SharedDownloadResult, Error>) in
                gate.arm(cont)
                if Task.isCancelled {
                    finishCancelled(task, gate: gate)
                    return
                }
                task.resume()
            }
        } onCancel: {
            finishCancelled(task, gate: gate)
        }
    }

    nonisolated private func finishCancelled(
        _ task: URLSessionDownloadTask,
        gate: OnceThrowingContinuation<SharedDownloadResult>
    ) {
        task.cancel()
        _ = lock.withLock {
            states.removeValue(forKey: task.taskIdentifier)
        }
        gate.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let onProgress = lock.withLock {
            states[downloadTask.taskIdentifier]?.onProgress
        }
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 200
        let rateLimit = response?.value(forHTTPHeaderField: "RateLimit")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: copy)
            lock.withLock {
                states[downloadTask.taskIdentifier]?.copied = copy
                states[downloadTask.taskIdentifier]?.statusCode = status
                states[downloadTask.taskIdentifier]?.rateLimitHeader = rateLimit
            }
        } catch {
            resume(taskIdentifier: downloadTask.taskIdentifier, throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let state = lock.withLock {
            states.removeValue(forKey: task.taskIdentifier)
        }
        guard let state else { return }

        if let error {
            state.gate.resume(throwing: error)
            return
        }
        if let copied = state.copied {
            state.gate.resume(
                returning: SharedDownloadResult(
                    fileURL: copied,
                    statusCode: state.statusCode,
                    rateLimitHeader: state.rateLimitHeader
                )
            )
            return
        }
        state.gate.resume(throwing: URLError(.cannotCreateFile))
    }

    private func resume(taskIdentifier: Int, throwing error: Error) {
        let gate = lock.withLock {
            states[taskIdentifier]?.gate
        }
        gate?.resume(throwing: error)
    }
}
