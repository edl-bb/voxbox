import Foundation
import Observation
import FluidAudio
import Speech
import WhisperKit

struct ModelCacheCleanupReport {
    let deletedPaths: [URL]
    let checkedPaths: [URL]
}

/// Resolves and removes cache directories for a WhisperKit model variant.
///
/// Safety (from #65): cleanup is limited to the exact per-variant subdirectories
/// VoxBox itself owns — never a broad substring match over generic locations
/// (Caches root, home dir, temp, `.cache/huggingface`) that could delete unrelated
/// files. Storage layout (from #90 / `ModelStorage`): the only roots VoxBox
/// writes CoreML variants into are the current Application Support location and the
/// legacy `~/Documents/huggingface` location.
enum ModelCachePathResolver {
    /// The WhisperKit model roots VoxBox owns and is allowed to clean up:
    /// `<AppSupport>/VoxBox/models/argmaxinc/whisperkit-coreml` plus the legacy
    /// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.
    static func repoOwnedModelRoots() -> [URL] {
        var roots = [ModelStorage.whisperKitModelsDir]
        if let legacy = ModelStorage.legacyModelsDir { roots.append(legacy) }
        return roots
    }

    /// Exact per-variant candidate directories under the given repo-owned roots.
    ///
    /// For each root we consider both the slash ("openai/whisper-medium") and the
    /// underscore ("openai_whisper-medium") spelling of the variant, plus any exact
    /// `variant`-named directory found nested under the root (e.g. a hub-style
    /// `.../snapshots/<hash>/<variant>` layout). Directories whose names merely
    /// *contain* the variant (e.g. "<variant>-backup") are never matched.
    static func candidatePaths(
        for variant: String,
        roots: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates = Set<URL>()

        for root in roots {
            for name in variantDirectoryNames(for: variant) {
                candidates.insert(root.appendingPathComponent(name, isDirectory: true))
            }
            for match in exactVariantDirectories(named: variant, under: root, fileManager: fileManager) {
                candidates.insert(match)
            }
        }

        return candidates.sorted { $0.path < $1.path }
    }

    static func removeVariantDirectories(
        for variant: String,
        roots: [URL],
        fileManager: FileManager = .default,
        log: ((String) -> Void)? = nil
    ) -> ModelCacheCleanupReport {
        let candidates = candidatePaths(for: variant, roots: roots, fileManager: fileManager)
        var deletedPaths: [URL] = []

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                try fileManager.removeItem(at: candidate)
                deletedPaths.append(candidate)
                log?("✅ Deleted cache: \(candidate.path)")
            } catch {
                log?("❌ Failed to delete \(candidate.path): \(error)")
            }
        }

        return ModelCacheCleanupReport(deletedPaths: deletedPaths, checkedPaths: candidates)
    }

    private static func variantDirectoryNames(for variant: String) -> [String] {
        Array(Set([variant, variant.replacingOccurrences(of: "/", with: "_")]))
    }

    private static func exactVariantDirectories(
        named variant: String,
        under root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var matches: [URL] = []

        for case let url as URL in enumerator {
            guard url.lastPathComponent == variant else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            matches.append(url)
            enumerator.skipDescendants()
        }

        return matches
    }
}

@Observable
class ModelDownloadService {
    static let shared = ModelDownloadService()
    
    var downloadProgress: [String: Double] = [:] // Map Model Variant (String) to progress
    var downloadStatus: [String: ModelDownloadStatus] = [:]

    static func hasDownloadedModel(in progress: [String: Double]) -> Bool {
        progress.values.contains { $0 >= 1.0 }
    }
    var downloadError: [String: String] = [:] // Debugging: track errors
    var isDownloading: [String: Bool] = [:]
    /// Variants that finished downloading this session and have not been used yet.
    private(set) var recentlyCompleted: Set<String> = []
    /// Flips only when the completed-model set changes — pill/onboarding observe this.
    private(set) var hasAnyDownloadedModel = false
    
    @ObservationIgnored
    private var activeTasks: [String: Task<Void, Never>] = [:] // Track running download tasks
    @ObservationIgnored
    private var progressReducers: [String: ModelDownloadProgressReducer] = [:]
    @ObservationIgnored
    private var manifests: [String: ModelDownloadManifest] = [:]
    @ObservationIgnored
    nonisolated private let pendingLock = NSLock()
    @ObservationIgnored
    nonisolated(unsafe) private var pendingProgress: [String: PendingDownloadSample] = [:]
    @ObservationIgnored
    private var didAttemptAppleStarterInstall = false
    private var heartbeat: Timer?
    /// Paint in-flight bytes often; speed/ETA still use a 2.5s window.
    private let uiRefreshInterval: TimeInterval = 0.4

    private struct PendingDownloadSample: Sendable {
        var receivedBytes: Int64
        var totalBytes: Int64
        var fraction: Double
        var phase: ModelDownloadPhase
        var whisper: Bool
    }

    func snapshot(for variant: String) -> ModelDownloadSnapshot {
        ModelDownloadSnapshot.make(
            progress: downloadProgress[variant] ?? 0,
            isDownloading: isDownloading[variant] ?? false,
            status: downloadStatus[variant],
            recentlyCompleted: recentlyCompleted.contains(variant),
            error: downloadError[variant]
        )
    }

    private func syncHasAnyDownloadedModel() {
        let next = Self.hasDownloadedModel(in: downloadProgress)
        if hasAnyDownloadedModel != next {
            hasAnyDownloadedModel = next
        }
    }
    
    private init() {
        // Move any models left in the legacy ~/Documents/huggingface location into
        // Application Support. No directory is created eagerly — a fresh install
        // leaves no trace until the user actually downloads a model.
        ModelStorage.migrateLegacyModelsIfNeeded()

        // Check for already-downloaded models on launch
        Task { @MainActor in
            await refreshDownloadedModels()
            // Don't auto-select - let user explicitly pick a model which will load it
        }
    }
    
    // Check which models are already downloaded and update progress dictionary
    func refreshDownloadedModels() async {
        print("🔍 Checking for already-downloaded models...")
        
        var foundModels = Set<String>()
        
        // NOTE: WhisperKit.fetchAvailableModels() returns ALL remote models, not local ones
        // We ONLY rely on disk-based verification to check what's actually downloaded

        // Verify models actually exist on disk with proper size validation.
        // Scan the current Application Support location plus the legacy Documents
        // location (in case a migration move failed or hasn't run yet).
        var scanDirs = [ModelStorage.whisperKitModelsDir]
        if let legacy = ModelStorage.legacyModelsDir { scanDirs.append(legacy) }
        for dir in scanDirs {
            scanWhisperKitModels(in: dir, into: &foundModels)
        }
        
        // Parakeet: require FluidAudio's full file set, not a leftover folder.
        for variant in ParakeetCatalog.variants {
            if ParakeetCatalog.isDownloaded(variant) {
                foundModels.insert(variant)
                print("✅ Parakeet model \(variant) found in cache")
            } else {
                print("ℹ️ Parakeet model \(variant) is not fully downloaded")
            }
        }

        let appleInstalled = await AppleSpeechCatalog.isInstalled()
        if appleInstalled {
            foundModels.insert(AppleSpeechCatalog.variant)
            print("✅ Apple speech assets are installed")
        } else {
            print("ℹ️ Apple speech assets are not installed")
        }

        await MainActor.run {
            let inFlight = Set(self.isDownloading.compactMap { $0.value ? $0.key : nil })
            let inFlightProgress = Dictionary(
                uniqueKeysWithValues: inFlight.compactMap { key in
                    self.downloadProgress[key].map { (key, $0) }
                }
            )

            // Clear all previous progress
            self.downloadProgress.removeAll()

            // Only mark models that actually exist
            for variant in foundModels {
                self.downloadProgress[variant] = 1.0
                print("✅ Marked as downloaded: \(variant)")
            }

            for (variant, progress) in inFlightProgress where self.downloadProgress[variant] == nil {
                self.downloadProgress[variant] = progress
            }
            
            if foundModels.isEmpty {
                print("❌ No models found - all will show as 'Download' buttons")
            } else {
                print("✅ Found \(foundModels.count) usable model(s)")
            }
            self.syncHasAnyDownloadedModel()
            self.adoptAppleStarterIfNeeded(appleInstalled: appleInstalled)
        }
    }

    /// New / unchosen installs get Apple. Existing Parakeet/Whisper picks stay.
    private func adoptAppleStarterIfNeeded(appleInstalled: Bool) {
        if ModelSelection.hasExplicitSelection() { return }
        if appleInstalled {
            ModelSelection.applyStarterIfNeeded(appleReady: true)
            return
        }
        guard !didAttemptAppleStarterInstall else { return }
        didAttemptAppleStarterInstall = true
        downloadModel(variant: AppleSpeechCatalog.variant)
    }
    
    // Scan a WhisperKit CoreML models directory and insert any complete variants
    // (verified by required files + ~80% of expected size) into `foundModels`.
    private func scanWhisperKitModels(in whisperKitPath: URL, into foundModels: inout Set<String>) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: whisperKitPath.path) else {
            print("ℹ️ WhisperKit cache directory doesn't exist yet: \(whisperKitPath.path)")
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(at: whisperKitPath, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }

        print("📁 Found \(contents.count) items in WhisperKit cache at \(whisperKitPath.path)")

        for item in contents {
            let modelName = item.lastPathComponent

            // Skip non-model directories
            if modelName == "config.json" || modelName == ".DS_Store" {
                continue
            }

            // Verify this directory has actual model files (not just empty directory)
            guard let subContents = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: [.fileSizeKey]),
                  !subContents.isEmpty else {
                continue
            }

            // Check if it has the essential files for a model (must have config.json)
            let hasConfigJson = subContents.contains(where: { $0.lastPathComponent == "config.json" })
            let hasModelFiles = subContents.contains(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") })

            guard hasConfigJson && hasModelFiles else {
                print("⚠️ Model \(modelName) is incomplete (missing config.json or .mlmodelc files)")
                continue
            }

            // Calculate total directory size
            let directorySize = Self.calculateDirectorySize(at: item)
            let expectedSize = AIModel.expectedSize(for: modelName)

            // Model is complete if it's at least 80% of expected size
            let minAcceptableSize = Int64(Double(expectedSize) * 0.8)

            if directorySize >= minAcceptableSize {
                print("✅ Model \(modelName) verified: \(Self.formatBytes(directorySize)) (expected ~\(Self.formatBytes(expectedSize)))")
                foundModels.insert(modelName)
            } else {
                print("⚠️ Model \(modelName) is INCOMPLETE: \(Self.formatBytes(directorySize)) < \(Self.formatBytes(minAcceptableSize)) minimum")
            }
        }
    }

    // Asynchronous download using WhisperKit
    func downloadModel(variant: String) {
        guard isDownloading[variant] != true else { return }

        let kind = AIModel.engineKind(for: variant)
        if kind == .apple {
            downloadAppleModel(variant: variant)
            return
        }
        // Route Parakeet variants to FluidAudio.
        if kind == .parakeet {
            downloadParakeetModel(variant: variant)
            return
        }

        beginDownload(variant)
        // Create the storage directory now, on first download — never eagerly on launch.
        ModelStorage.ensureWhisperKitModelsDir()
        print("Starting WhisperKit download for: \(variant)")
        
        let task = Task {
            // Debug: List what WhisperKit sees
            // Note: WhisperKit API might differ, but let's try to see if we can get info.
            // If fetchAvailableModels exists.
            
            do {
                // Determine model variant enum/string
                // Note: WhisperKit.download(variant:from:) is the likely API.
                // We use the "variant" string to fetch.
                // Assuming `WhisperKit.download(variant: variant)` acts as the fetcher.
                // Progress callback mock (since we might not have exact API signature yet):
                
                // Actual API (hypothetical based on search):
                // let model = try await WhisperKit(model: variant) 
                // OR
                // try await WhisperKit.download(variant: variant) { progress in ... }
                
                // likely: download(variant:progressCallback:) - 'from' usually has a default
                let _ = try await WhisperKit.download(variant: variant, downloadBase: ModelStorage.whisperKitBase, progressCallback: { progress in
                    self.enqueueWhisperProgress(variant: variant, progress: progress)
                })
                
                // Check if task was cancelled before declaring success
                if Task.isCancelled { return }
                
                print("Model downloaded successfully")
                
                DispatchQueue.main.async {
                    self.finishDownload(variant, succeeded: true)
                }
            } catch {
                if Task.isCancelled {
                   print("Download cancelled for \(variant)")
                   return
                }
                
                print("WhisperKit download error: \(error)")
                
                // Auto-Repair: If duplicate models found, delete and retry ONCE
                if error.localizedDescription.contains("Multiple models found") {
                     print("⚠️ Multiple models detected. Cleaning cache and retrying...")
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Cleaning duplicates..."
                     }
                     
                     let log = await self.deleteModel(variant: variant)
                     print("🧹 Cleanup result: \(log)")
                     
                     // Give filesystem time to settle
                     try? await Task.sleep(nanoseconds: 2_000_000_000)
                     if Task.isCancelled { return }
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Retrying download..."
                     }
                     
                     // Retry download once
                     do {
                         let _ = try await WhisperKit.download(variant: variant, downloadBase: ModelStorage.whisperKitBase, progressCallback: { progress in
                             self.enqueueWhisperProgress(variant: variant, progress: progress)
                         })
                         
                         if Task.isCancelled { return }
                         
                         print("✅ Model downloaded successfully after cleanup")
                         
                         DispatchQueue.main.async {
                             self.downloadError[variant] = nil
                             self.finishDownload(variant, succeeded: true)
                         }
                     } catch {
                         if Task.isCancelled { return }
                         print("❌ Retry failed: \(error)")
                         DispatchQueue.main.async {
                             self.downloadError[variant] = "Error: \(error.localizedDescription)\n\nTry clicking the trash icon to manually clean cache."
                             self.finishDownload(variant, succeeded: false)
                         }
                     }
                     return
                }

                DispatchQueue.main.async {
                    self.downloadError[variant] = error.localizedDescription + "\n\n(Try Trash icon to clean cache)"
                    self.finishDownload(variant, succeeded: false)
                }
            }
        }
        
        activeTasks[variant] = task
    }
    
    /// Install Apple SpeechAnalyzer locale assets through AssetInventory.
    private func downloadAppleModel(variant: String) {
        beginDownload(variant)
        print("Starting Apple speech asset install for: \(variant)")

        let task = Task {
            do {
                let module = try await AppleSpeechCatalog.makeModule(language: "auto")
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [module.speechModule]
                ) {
                    let progress = request.progress
                    let poll = Task {
                        while !Task.isCancelled {
                            self.enqueueWhisperProgress(variant: variant, progress: progress)
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                    defer { poll.cancel() }
                    try await request.downloadAndInstall()
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.finishDownload(variant, succeeded: true)
                    ModelSelection.applyStarterIfNeeded(appleReady: true)
                }
            } catch {
                if Task.isCancelled { return }
                print("Apple speech asset install error: \(error)")
                await MainActor.run {
                    self.downloadError[variant] = error.localizedDescription
                    self.finishDownload(variant, succeeded: false)
                }
            }
        }
        activeTasks[variant] = task
    }

    // Download a Parakeet model: VoxBox pulls the Hugging Face files so the
    // bar can move while a large chunk is in flight. FluidAudio then verifies
    // the cache (and compiles if needed).
    private func downloadParakeetModel(variant: String) {
        beginDownload(variant)
        print("Starting Parakeet download for: \(variant)")

        let version = ParakeetCatalog.version(for: variant)
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)

        let task = Task {
            do {
                let manifest: ModelDownloadManifest
                do {
                    manifest = try await HuggingFaceModelManifest.fetch(for: variant)
                } catch {
                    print("Manifest fetch failed, falling back to FluidAudio: \(error)")
                    try await self.downloadParakeetViaFluidAudio(variant: variant, version: version)
                    return
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.isDownloading[variant] == true else { return }
                    self.manifests[variant] = manifest
                    var reducer = self.progressReducers[variant] ?? ModelDownloadProgressReducer()
                    reducer.applyManifest(manifest)
                    self.progressReducers[variant] = reducer
                    self.tickDownloads()
                }

                try await ModelFileDownloader.downloadParakeetFiles(
                    files: manifest.files,
                    variant: variant,
                    cacheRoot: cacheDir
                ) { received, finishedFiles, totalFiles in
                    self.enqueueProgress(
                        variant: variant,
                        fraction: 0,
                        receivedBytes: received,
                        totalBytes: manifest.totalBytes,
                        phase: .downloading(completedFiles: finishedFiles, totalFiles: totalFiles),
                        whisper: false
                    )
                }

                if Task.isCancelled { return }

                self.enqueueProgress(
                    variant: variant,
                    fraction: 1,
                    receivedBytes: manifest.totalBytes,
                    totalBytes: manifest.totalBytes,
                    phase: .preparing(fileName: ""),
                    whisper: false
                )
                _ = try await AsrModels.download(
                    version: version,
                    progressHandler: { progress in
                        if case .compiling(let name) = progress.phase {
                            self.enqueueProgress(
                                variant: variant,
                                fraction: progress.fractionCompleted,
                                receivedBytes: manifest.totalBytes,
                                totalBytes: manifest.totalBytes,
                                phase: .preparing(fileName: name),
                                whisper: false
                            )
                        }
                    })

                if Task.isCancelled { return }
                print("Parakeet model downloaded successfully")
                DispatchQueue.main.async {
                    self.finishDownload(variant, succeeded: true)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    print("Parakeet download cancelled for \(variant)")
                    return
                }
                print("Parakeet download error: \(error)")
                DispatchQueue.main.async {
                    self.downloadError[variant] = error.localizedDescription
                    self.finishDownload(variant, succeeded: false)
                }
            }
        }

        activeTasks[variant] = task
    }

    private func downloadParakeetViaFluidAudio(variant: String, version: AsrModelVersion) async throws {
        _ = try await AsrModels.download(
            version: version,
            progressHandler: { progress in
                let phase: ModelDownloadPhase
                switch progress.phase {
                case .listing:
                    phase = .listing
                case .downloading(let completed, let total):
                    phase = .downloading(completedFiles: completed, totalFiles: total)
                case .compiling(let name):
                    phase = .preparing(fileName: name)
                }
                let total = AIModel.expectedSize(for: variant)
                let received: Int64
                if progress.fractionCompleted < 0.49, total > 0 {
                    received = Int64((progress.fractionCompleted / 0.5) * Double(total))
                } else {
                    received = 0
                }
                self.enqueueProgress(
                    variant: variant,
                    fraction: progress.fractionCompleted,
                    receivedBytes: received,
                    totalBytes: total,
                    phase: phase,
                    whisper: false
                )
            })
        if Task.isCancelled { return }
        await MainActor.run {
            self.finishDownload(variant, succeeded: true)
        }
    }

    private func beginDownload(_ variant: String) {
        isDownloading[variant] = true
        downloadProgress[variant] = 0
        downloadError[variant] = nil
        progressReducers[variant] = ModelDownloadProgressReducer()
        downloadStatus[variant] = ModelDownloadStatus()
        manifests[variant] = nil
        ensureHeartbeat()
        tickDownloads()
    }

    nonisolated private func enqueueWhisperProgress(variant: String, progress: Progress) {
        let fraction = progress.fractionCompleted
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        enqueueProgress(
            variant: variant,
            fraction: fraction.isFinite ? fraction : 0,
            receivedBytes: completed,
            totalBytes: total,
            phase: .downloading(
                completedFiles: Int(max(completed, 0)),
                totalFiles: Int(max(total, 0))
            ),
            whisper: true
        )
    }

    /// Keep the latest byte sample. The UI ticks every 0.4s so a large
    /// in-flight file still moves the bar; URLSession callbacks are coalesced.
    nonisolated private func enqueueProgress(
        variant: String,
        fraction: Double,
        receivedBytes: Int64,
        totalBytes: Int64,
        phase: ModelDownloadPhase,
        whisper: Bool
    ) {
        pendingLock.lock()
        pendingProgress[variant] = PendingDownloadSample(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            fraction: fraction,
            phase: phase,
            whisper: whisper
        )
        pendingLock.unlock()
    }

    private func ensureHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: uiRefreshInterval, repeats: true) { [weak self] _ in
            self?.tickDownloads()
        }
    }

    private func tickDownloads() {
        pendingLock.lock()
        let snapshot = pendingProgress
        pendingLock.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        var anyActive = false
        for (variant, downloading) in isDownloading where downloading {
            anyActive = true
            var reducer = progressReducers[variant] ?? ModelDownloadProgressReducer()
            if let manifest = manifests[variant] {
                reducer.applyManifest(manifest)
            }

            let pending = snapshot[variant]
            let whisper = pending?.whisper == true
            let expectedBytes = resolvedTotalBytes(for: variant, whisper: whisper)
            if let pending {
                let received = receivedBytes(
                    variant: variant,
                    pending: pending,
                    totalBytes: expectedBytes,
                    alreadyReceived: reducer.status.receivedBytes
                )
                reducer.applyDownloadSample(
                    whisper: pending.whisper,
                    fraction: pending.fraction,
                    phase: pending.phase,
                    receivedBytes: pending.whisper ? pending.receivedBytes : received,
                    totalBytes: pending.whisper ? pending.totalBytes : expectedBytes,
                    expectedBytes: expectedBytes,
                    now: now
                )
            } else {
                reducer.applyTick(
                    phase: reducer.status.phase,
                    receivedBytes: reducer.status.receivedBytes,
                    totalBytes: expectedBytes,
                    now: now
                )
            }
            _ = reducer.tick(now: now)
            progressReducers[variant] = reducer
            if downloadStatus[variant] != reducer.status {
                downloadStatus[variant] = reducer.status
            }
            if downloadProgress[variant] != reducer.status.fraction {
                downloadProgress[variant] = reducer.status.fraction
            }
        }
        syncHasAnyDownloadedModel()
        if !anyActive {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    private func resolvedTotalBytes(for variant: String, whisper: Bool) -> Int64 {
        if let total = manifests[variant]?.totalBytes, total > 0 {
            return total
        }
        if whisper {
            return AIModel.expectedSize(for: variant)
        }
        return progressReducers[variant]?.status.totalBytes ?? 0
    }

    /// Prefer the live byte count from the current file. Do not walk the
    /// cache here — that used to run on the main thread every poll.
    private func receivedBytes(
        variant: String,
        pending: PendingDownloadSample?,
        totalBytes: Int64,
        alreadyReceived: Int64
    ) -> Int64 {
        // Do not walk the cache on the main thread during a transfer — that
        // hitch is felt as the whole window dropping to the poll rate.
        guard let pending else { return alreadyReceived }

        if pending.whisper {
            let expected = max(totalBytes, AIModel.expectedSize(for: variant))
            let inferred = Int64(min(max(pending.fraction, 0), 1) * Double(expected))
            return max(inferred, alreadyReceived)
        }

        return max(pending.receivedBytes, alreadyReceived)
    }

    func recordDownloadOutcome(variant: String, succeeded: Bool) {
        if succeeded {
            recentlyCompleted.insert(variant)
        } else {
            recentlyCompleted.remove(variant)
        }
    }

    func acknowledgeCompletedDownload(for variant: String) {
        recentlyCompleted.remove(variant)
    }

    private func finishDownload(_ variant: String, succeeded: Bool) {
        pendingLock.lock()
        pendingProgress[variant] = nil
        pendingLock.unlock()
        if succeeded {
            var reducer = progressReducers[variant] ?? ModelDownloadProgressReducer()
            reducer.finish()
            downloadProgress[variant] = 1
            recordDownloadOutcome(variant: variant, succeeded: true)
        } else if downloadProgress[variant] != 1 {
            downloadProgress[variant] = 0
            recordDownloadOutcome(variant: variant, succeeded: false)
        }
        isDownloading[variant] = false
        downloadStatus[variant] = nil
        progressReducers[variant] = nil
        manifests[variant] = nil
        activeTasks[variant] = nil
        if !(isDownloading.values.contains(true)) {
            heartbeat?.invalidate()
            heartbeat = nil
        }
        syncHasAnyDownloadedModel()
        if succeeded, AIModel.engineKind(for: variant) == .apple {
            ModelSelection.applyStarterIfNeeded(appleReady: true)
        }
    }

    // Aggressively deletes any potential cache for this variant
    func deleteModel(variant: String) async -> String {
        if AIModel.engineKind(for: variant) == .apple {
            return "Apple speech assets are managed by macOS and are not deleted from VoxBox."
        }

        // Parakeet models are managed by FluidAudio in its own cache directory.
        if AIModel.engineKind(for: variant) == .parakeet {
            let version = ParakeetCatalog.version(for: variant)
            let cacheDir = AsrModels.defaultCacheDirectory(for: version)
            try? FileManager.default.removeItem(at: cacheDir)
            await MainActor.run {
                self.downloadProgress[variant] = 0.0
                self.isDownloading[variant] = false
                self.acknowledgeCompletedDownload(for: variant)
                self.syncHasAnyDownloadedModel()
            }
            return "Deleted Parakeet model cache for \(variant)"
        }

        let fileManager = FileManager.default
        // Only ever touch the WhisperKit model directories VoxBox itself owns:
        // the current Application Support location and the legacy Documents location.
        // Deletion is limited to the exact per-variant subdirectories under those
        // roots — no broad substring matching over Caches/home/temp that could nuke
        // unrelated files (the pre-#65 behavior).
        let roots = ModelCachePathResolver.repoOwnedModelRoots()
        let cleanupReport = ModelCachePathResolver.removeVariantDirectories(
            for: variant,
            roots: roots,
            fileManager: fileManager,
            log: { print($0) }
        )

        let deletedCount = cleanupReport.deletedPaths.count
        let checkedPaths = cleanupReport.checkedPaths.map(\.path)

        print("🗑️ Cleanup complete. Deleted \(deletedCount) repo-owned model caches")

        if deletedCount > 0 {
            await MainActor.run {
                self.downloadProgress[variant] = 0.0
                self.isDownloading[variant] = false
                self.acknowledgeCompletedDownload(for: variant)
                self.syncHasAnyDownloadedModel()
            }
            return "Deleted \(deletedCount) items"
        } else {
            await MainActor.run {
                self.downloadProgress[variant] = 0.0
                self.isDownloading[variant] = false
                self.acknowledgeCompletedDownload(for: variant)
                self.syncHasAnyDownloadedModel()
            }
            let homePath = fileManager.homeDirectoryForCurrentUser.path
            return "No repo-owned cache found for '\(variant)'. Checked: \(checkedPaths.map { $0.replacingOccurrences(of: homePath, with: "~") }.joined(separator: ", "))"
        }
    }

    func cancelDownload(for variant: String) {
        pendingLock.lock()
        pendingProgress[variant] = nil
        pendingLock.unlock()
        if let task = activeTasks[variant] {
            task.cancel()
            activeTasks[variant] = nil
            print("Cancelled download task for \(variant)")
        }
        
        isDownloading[variant] = false
        downloadProgress[variant] = 0.0
        downloadError[variant] = nil
        downloadStatus[variant] = nil
        progressReducers[variant] = nil
        manifests[variant] = nil
        recordDownloadOutcome(variant: variant, succeeded: false)
        syncHasAnyDownloadedModel()

        if AIModel.engineKind(for: variant) == .apple { return }

        // Delete any partial download
        Task {
            let result = await deleteModel(variant: variant)
            print("🗑️ Cleaned up partial download: \(result)")
        }
    }
    
    // MARK: - Helper Functions
    
    /// Calculate total size of a directory recursively
    static func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    /// Format bytes into human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
