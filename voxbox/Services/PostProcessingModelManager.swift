import Combine
import Foundation
import MLXFoundationModels

/// Owns the post-processing (cleanup) model choice and the download/removal
/// lifecycle of Hugging Face models. Mirrors the shape of
/// `ModelDownloadService` but stays deliberately small: files are fetched
/// straight from the repo head into Application Support.
///
/// Published state lives on the main actor (the type inherits the module's
/// MainActor default); the byte streaming itself runs detached so a
/// multi-gigabyte download never occupies the main thread.
final class PostProcessingModelManager: ObservableObject {
    static let shared = PostProcessingModelManager()

    static let selectionKey = "postProcessingModelVariant"

    /// 0..<1 while downloading, >= 1.0 once complete (same convention as
    /// ModelDownloadService so the download UI components can be shared).
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadStatus: [String: ModelDownloadStatus] = [:]
    @Published private(set) var downloadError: [String: String] = [:]
    /// Variant whose weights/JIT warmup is in flight. Nil when idle.
    /// Apple Intelligence is never set here.
    @Published private(set) var preparingVariant: String?

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    private var preparationToken = UUID()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshDownloadedModels()
        startPreparationIfNeeded(for: selectedVariant)
    }

    // MARK: - Selection

    var selectedVariant: String {
        get {
            defaults.string(forKey: Self.selectionKey)
                ?? PostProcessingModel.appleSystemVariant
        }
        set {
            let previous = selectedVariant
            guard previous != newValue else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.selectionKey)
            invalidatePool(variant: previous)
            startPreparationIfNeeded(for: newValue)
        }
    }

    /// The model cleanup actually runs on. A stored `.mlx` choice from 1.2
    /// resolves to Apple Intelligence while downloadable models are parked.
    var selectedModel: PostProcessingModel {
        guard let model = PostProcessingModel.model(for: selectedVariant),
            model.kind == .appleSystem || OSCapabilities.customCleanupModels
        else { return PostProcessingModel.catalog[0] }
        return model
    }

    /// Marks a variant as on-disk without writing weights. Factory tests
    /// use this to drive the downloaded MLX branch.
    func markDownloadedForTesting(_ variant: String) {
        downloadProgress[variant] = 1.0
    }

    /// Test hook: flip the preparing flag without loading live weights.
    func beginPreparingForTesting(_ variant: String) {
        cancelInFlightPreparation()
        preparingVariant = variant
    }

    /// Test hook: return to idle without waiting for preload/prewarm.
    func endPreparingForTesting() {
        cancelInFlightPreparation()
        preparingVariant = nil
    }

    /// True only for the selected downloadable variant while warmup is in flight.
    /// Apple Intelligence never reports preparing.
    func isPreparing(_ model: PostProcessingModel) -> Bool {
        guard model.kind != .appleSystem else { return false }
        return preparingVariant == model.variant && selectedVariant == model.variant
    }

    // MARK: - State

    func isDownloaded(_ variant: String) -> Bool {
        (downloadProgress[variant] ?? 0) >= 1.0
    }

    func isDownloading(_ variant: String) -> Bool {
        downloadTasks[variant] != nil
    }

    /// Rebuild the downloaded set from disk. A model counts as present when
    /// its directory holds at least 60% of the expected bytes — enough to
    /// reject a directory that only got config files before a failure.
    func refreshDownloadedModels() {
        for model in PostProcessingModel.catalog where model.kind == .mlx {
            guard downloadTasks[model.variant] == nil else { continue }
            let size = Self.directorySize(Self.storageDir(for: model.variant))
            let expected = Double(model.approxSizeBytes)
            let present = expected > 0 && Double(size) >= expected * 0.6
            downloadProgress[model.variant] = present ? 1.0 : 0.0
        }
    }

    // MARK: - Download / delete

    func download(variant: String) {
        guard downloadTasks[variant] == nil,
            let model = PostProcessingModel.model(for: variant),
            let repo = model.huggingFaceRepo
        else { return }

        downloadError[variant] = nil
        downloadProgress[variant] = 0
        downloadStatus[variant] = ModelDownloadStatus()

        let directory = Self.storageDir(for: variant)
        downloadTasks[variant] = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Self.performDownload(model: model, repo: repo, directory: directory) {
                    received, total, completedFiles, totalFiles in
                    await MainActor.run {
                        self.applyProgress(
                            variant: variant, received: received, total: total,
                            completedFiles: completedFiles, totalFiles: totalFiles)
                    }
                }
                await MainActor.run { self.finishDownload(variant: variant, completed: true) }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: directory)
                await MainActor.run { self.finishDownload(variant: variant, completed: false) }
            } catch {
                await MainActor.run {
                    AppLogger.warning(
                        "Post-processing model download failed: \(error.localizedDescription)",
                        category: AppLogger.transcription)
                    self.finishDownload(
                        variant: variant, completed: false,
                        errorMessage: "Download failed — check your connection and try again.")
                }
            }
        }
    }

    func cancelDownload(variant: String) {
        downloadTasks[variant]?.cancel()
    }

    @discardableResult
    func deleteModel(variant: String) -> Bool {
        guard PostProcessingModel.model(for: variant)?.kind == .mlx else { return false }
        cancelDownload(variant: variant)
        do {
            try FileManager.default.removeItem(at: Self.storageDir(for: variant))
        } catch {
            // Missing directory is fine; anything else leaves state unchanged.
        }
        downloadProgress[variant] = 0
        invalidatePool(variant: variant)
        if preparingVariant == variant {
            cancelInFlightPreparation()
            preparingVariant = nil
        }
        if selectedVariant == variant {
            selectedVariant = PostProcessingModel.appleSystemVariant
        }
        return true
    }

    // MARK: - Preparing (preload + prewarm)

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func shouldPrepare(_ variant: String) -> Bool {
        guard OSCapabilities.customCleanupModels,
            let model = PostProcessingModel.model(for: variant),
            model.kind == .mlx
        else { return false }
        return isDownloaded(variant)
    }

    private func startPreparationIfNeeded(for variant: String) {
        cancelInFlightPreparation()
        guard shouldPrepare(variant) else {
            preparingVariant = nil
            return
        }
        // Unit tests drive the flag via begin/endPreparingForTesting so a
        // leftover on-disk catalog model cannot hang XCTest on live weights.
        if Self.isRunningTests {
            preparingVariant = nil
            return
        }

        downloadError[variant] = nil
        let token = UUID()
        preparationToken = token
        preparingVariant = variant
        preparationTask = Task { [weak self] in
            await self?.runPreparation(variant: variant, token: token)
        }
    }

    private func cancelInFlightPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        preparationToken = UUID()
    }

    private func invalidatePool(variant: String) {
        Task {
            await CleanupSessionPool.shared.invalidate(variant: variant)
        }
    }

    private func runPreparation(variant: String, token: UUID) async {
        defer {
            if preparationToken == token {
                preparingVariant = nil
                preparationTask = nil
            }
        }
        guard !Task.isCancelled else { return }
        guard shouldPrepare(variant) else { return }

        if #available(macOS 27, *) {
            guard let model = PostProcessingModel.model(for: variant) else { return }
            let engine = CleanupEngineFactory.engine(for: model, manager: self)
            guard let mlx = engine as? FoundationModelsMLXCleanupEngine, mlx.isAvailable
            else { return }

            do {
                try await mlx.makeLanguageModel().preload()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, preparationToken == token else { return }
                AppLogger.warning(
                    "Cleanup model prepare failed: \(error.localizedDescription)",
                    category: AppLogger.transcription)
                downloadError[variant] =
                    "Couldn't prepare this model — try selecting it again."
                return
            }

            guard !Task.isCancelled, preparationToken == token else { return }
            let request = TranscriptFormatterService.request(
                for: "warmup",
                intensity: .lightCleanup,
                includeMarkdownFormatting: false)
            await mlx.prewarm(request)
        }
    }

    // MARK: - Published-state updates (main actor)

    private func applyProgress(
        variant: String,
        received: Int64,
        total: Int64,
        completedFiles: Int,
        totalFiles: Int
    ) {
        var status = downloadStatus[variant] ?? ModelDownloadStatus()
        status.phase = .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        if total > 0 {
            // Cap below 1.0 — only a fully completed download flips to 1.0.
            let fraction = min(0.99, Double(received) / Double(total))
            downloadProgress[variant] = fraction
            status.fraction = fraction
            status.receivedBytes = received
            status.totalBytes = total
        }
        downloadStatus[variant] = status
    }

    private func finishDownload(
        variant: String,
        completed: Bool,
        errorMessage: String? = nil
    ) {
        downloadProgress[variant] = completed ? 1.0 : 0
        downloadStatus[variant] = nil
        downloadError[variant] = errorMessage
        downloadTasks[variant] = nil
        if completed, selectedVariant == variant {
            startPreparationIfNeeded(for: variant)
        }
    }

    // MARK: - Transfer (off the main actor)

    private typealias ProgressReport = @Sendable (
        _ received: Int64, _ total: Int64, _ completedFiles: Int, _ totalFiles: Int
    ) async -> Void

    private nonisolated static func performDownload(
        model: PostProcessingModel,
        repo: String,
        directory dir: URL,
        onProgress: @escaping ProgressReport
    ) async throws {
        let (metadata, _) = try await URLSession.shared.data(
            from: HuggingFaceRepoAPI.metadataURL(repo: repo))
        let files = try HuggingFaceRepoAPI.modelFiles(fromMetadata: metadata)
        guard !files.isEmpty else {
            throw URLError(.resourceUnavailable)
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let knownTotal = files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let totalBytes = knownTotal > 0 ? knownTotal : model.approxSizeBytes
        var receivedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            await onProgress(receivedBytes, totalBytes, index, files.count)

            let destination = dir.appendingPathComponent(file.path)
            if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]),
                let size = existing.fileSize, file.sizeBytes > 0,
                Int64(size) == file.sizeBytes
            {
                receivedBytes += file.sizeBytes
                continue
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let url = HuggingFaceRepoAPI.fileURL(repo: repo, path: file.path)
            receivedBytes = try await streamFile(
                from: url, to: destination,
                receivedSoFar: receivedBytes, totalBytes: totalBytes,
                completedFiles: index, totalFiles: files.count,
                onProgress: onProgress)
        }
        await onProgress(receivedBytes, totalBytes, files.count, files.count)
    }

    /// Streams one file to disk, reporting progress every few megabytes.
    private nonisolated static func streamFile(
        from url: URL,
        to destination: URL,
        receivedSoFar: Int64,
        totalBytes: Int64,
        completedFiles: Int,
        totalFiles: Int,
        onProgress: @escaping ProgressReport
    ) async throws -> Int64 {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw URLError(.badServerResponse) }

        let temp = destination.appendingPathExtension("download")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }

        var received = receivedSoFar
        var buffer = Data()
        buffer.reserveCapacity(4_194_304)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4_194_304 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(received, totalBytes, completedFiles, totalFiles)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        await onProgress(received, totalBytes, completedFiles, totalFiles)
        return received
    }

    // MARK: - Storage

    nonisolated static var storageRoot: URL {
        ModelStorage.whisperKitBase.appendingPathComponent(
            "postprocessing-models", isDirectory: true)
    }

    nonisolated static func storageDir(for variant: String) -> URL {
        storageRoot.appendingPathComponent(variant, isDirectory: true)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
