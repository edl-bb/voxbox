import XCTest
@testable import voxbox

final class ModelDownloadServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }
    
    func testInitialState() {
        let service = ModelDownloadService.shared
        
        // Ensure no lingering downloads from other runs
        // (Note: Shared singleton might have state if tests run in parallel or sequence without clearing)
        // We can't easily clear private vars, but we can check types.
        
        XCTAssertNotNil(service.downloadProgress)
        XCTAssertNotNil(service.isDownloading)
    }

    func testCandidatePathsStayWithinRepoOwnedRoots() throws {
        // Simulate the two repo-owned WhisperKit model roots (current App Support +
        // legacy Documents), matching ModelStorage's `.../models/argmaxinc/whisperkit-coreml`.
        let currentRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "AppSupport/VoxBox/models/argmaxinc/whisperkit-coreml"))
        let legacyRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        let roots = [currentRoot, legacyRoot]
        let variant = "openai_whisper-medium"

        let directPath = try createDirectory(at: currentRoot.appendingPathComponent(variant))
        // A hub-style nested layout under a repo-owned root should still be found by
        // exact-name matching.
        let nestedPath = try createDirectory(
            at: legacyRoot.appendingPathComponent("snapshots/123/\(variant)"))
        // A directory that only *contains* the variant name must NOT be a candidate.
        _ = try createDirectory(at: currentRoot.appendingPathComponent("\(variant)-backup"))
        // A model outside any repo-owned root must NOT be a candidate.
        _ = try createDirectory(at: tempRoot.appendingPathComponent(variant))

        let candidatePaths = ModelCachePathResolver.candidatePaths(
            for: variant,
            roots: roots
        )
        let normalizedCandidatePaths = Set(candidatePaths.map(normalizedPath))

        XCTAssertTrue(normalizedCandidatePaths.contains(normalizedPath(directPath)))
        XCTAssertTrue(normalizedCandidatePaths.contains(normalizedPath(nestedPath)))
        XCTAssertFalse(
            normalizedCandidatePaths.contains(
                normalizedPath(currentRoot.appendingPathComponent("\(variant)-backup"))
            )
        )
        XCTAssertFalse(
            normalizedCandidatePaths.contains(
                normalizedPath(tempRoot.appendingPathComponent(variant))
            )
        )
    }

    func testRemoveVariantDirectoriesOnlyDeletesExactRepoOwnedMatches() throws {
        let currentRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "AppSupport/VoxBox/models/argmaxinc/whisperkit-coreml"))
        let legacyRoot = try createDirectory(
            at: tempRoot.appendingPathComponent(
                "Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        let roots = [currentRoot, legacyRoot]
        let variant = "openai_whisper-medium"

        let directPath = try createDirectory(at: currentRoot.appendingPathComponent(variant))
        let nestedPath = try createDirectory(
            at: legacyRoot.appendingPathComponent("snapshots/abc123/\(variant)"))
        // "<variant>-backup" lives inside a repo-owned root but its name only contains
        // the variant — it must survive.
        let backupPath = try createDirectory(
            at: currentRoot.appendingPathComponent("\(variant)-backup"))
        // An unrelated directory outside any repo-owned root must survive.
        let unrelatedPath = try createDirectory(
            at: tempRoot.appendingPathComponent("\(variant)-notes"))

        let report = ModelCachePathResolver.removeVariantDirectories(
            for: variant,
            roots: roots
        )

        XCTAssertEqual(
            Set(report.deletedPaths.map(normalizedPath)),
            Set([directPath, nestedPath].map(normalizedPath))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPath.path))
    }

    func testFluidDownloadProgressDoesNotStickAtHalf() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyFluid(
            fraction: 0.02,
            phase: .downloading(completedFiles: 0, totalFiles: 23),
            expectedBytes: 500_000_000,
            now: 1
        )
        XCTAssertLessThan(reducer.status.fraction, 0.1)
        XCTAssertTrue(reducer.status.title.contains("of"))
        XCTAssertEqual(reducer.status.totalBytes, 500_000_000)

        reducer.applyFluid(
            fraction: 0.5,
            phase: .downloading(completedFiles: 23, totalFiles: 23),
            expectedBytes: 500_000_000,
            now: 10
        )
        XCTAssertGreaterThan(reducer.status.fraction, 0.8)
        XCTAssertLessThan(reducer.status.fraction, 1)

        // Later loadModels calls report 0.5 "already present" — bar must not jump back.
        reducer.applyFluid(
            fraction: 0.5,
            phase: .downloading(completedFiles: 0, totalFiles: 0),
            expectedBytes: 500_000_000,
            now: 11
        )
        XCTAssertGreaterThan(reducer.status.fraction, 0.8)

        reducer.applyFluid(
            fraction: 0.75,
            phase: .preparing(fileName: "Encoder.mlmodelc"),
            expectedBytes: 500_000_000,
            now: 12
        )
        XCTAssertEqual(reducer.status.title, "Preparing Encoder…")
        XCTAssertEqual(reducer.status.subtitle, "Compiling the model for this Mac")
        XCTAssertGreaterThanOrEqual(reducer.status.fraction, 0.82)
    }

    func testFluidHalfCapDoesNotIgnoreRemainingFiles() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyFluid(
            fraction: 0.5,
            phase: .downloading(completedFiles: 3, totalFiles: 23),
            expectedBytes: 500_000_000,
            now: 1
        )
        let afterCap = reducer.status.fraction
        XCTAssertTrue(reducer.status.title.contains("of"))
        XCTAssertEqual(reducer.status.totalBytes, 500_000_000)

        reducer.applyFluid(
            fraction: 0.5,
            phase: .downloading(completedFiles: 12, totalFiles: 23),
            expectedBytes: 500_000_000,
            now: 4
        )
        XCTAssertTrue(reducer.status.subtitle.contains("13 of 23 files"))
        XCTAssertGreaterThan(reducer.status.fraction, afterCap)
        XCTAssertFalse(reducer.status.subtitle.isEmpty)
    }

    func testEstimatorKeepsLastRateWhenChunkGoesQuiet() {
        var estimator = DownloadRateEstimator()
        _ = estimator.add(fraction: 0.10, at: 0, expectedBytes: 100_000_000)
        let moving = estimator.add(fraction: 0.30, at: 2, expectedBytes: 100_000_000)
        let quiet = estimator.add(fraction: 0.3001, at: 2.1, expectedBytes: 100_000_000)
        XCTAssertGreaterThan(moving.bps, 0)
        XCTAssertEqual(quiet.bps, moving.bps, accuracy: 1)
    }

    func testHuggingFaceManifestUsesFileSizesAndSkipsOtherPrecisions() {
        let items: [[String: Any]] = [
            ["path": "Encoder.mlmodelc/coremldata.bin", "type": "file", "size": 200_000_000],
            ["path": "EncoderInt4.mlmodelc/coremldata.bin", "type": "file", "size": 80_000_000],
            ["path": "parakeet_vocab.json", "type": "file", "size": 1_024],
            ["path": "Decoder.mlmodelc", "type": "directory"],
        ]
        let entries = HuggingFaceModelManifest.parseEntries(items)
        let manifest = HuggingFaceModelManifest.manifest(
            from: entries,
            requiredNames: HuggingFaceModelManifest.requiredNames(for: ParakeetCatalog.v3Variant)
        )
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.totalBytes, 200_001_024)
        XCTAssertFalse(manifest.files.contains(where: { $0.path.contains("EncoderInt4") }))
    }

    func testUnknownRemoteSizesDoNotInflateManifestTotal() {
        let entries = HuggingFaceModelManifest.parseEntries([
            ["path": "Encoder.mlmodelc/weight.bin", "type": "file", "size": 50_000_000],
            ["path": "Decoder.mlmodelc/weight.bin", "type": "file"],
        ])
        let manifest = HuggingFaceModelManifest.manifest(
            from: entries,
            requiredNames: ["Encoder.mlmodelc", "Decoder.mlmodelc"]
        )
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.totalBytes, 50_000_000)
    }

    func testByteTickDrivesTitleFromManifestSizes() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyManifest(
            ModelDownloadManifest.make(files: [
                .init(path: "Encoder.mlmodelc/coremldata.bin", size: 400_000_000)
            ])
        )
        reducer.applyTick(
            phase: .downloading(completedFiles: 3, totalFiles: 23),
            receivedBytes: 100_000_000,
            totalBytes: 400_000_000,
            now: 0
        )
        XCTAssertEqual(
            reducer.status.title,
            "\(ModelDownloadFormatting.formatBytes(100_000_000)) of \(ModelDownloadFormatting.formatBytes(400_000_000))"
        )
        XCTAssertEqual(reducer.status.subtitle, "4 of 23 files")
        XCTAssertEqual(reducer.status.fraction, 0.82 * 0.25, accuracy: 0.001)

        reducer.applyTick(
            phase: .downloading(completedFiles: 8, totalFiles: 23),
            receivedBytes: 160_000_000,
            totalBytes: 400_000_000,
            now: 2.5
        )
        XCTAssertGreaterThan(reducer.status.bytesPerSecond, 20_000_000)
        XCTAssertNotNil(reducer.status.eta)
        XCTAssertTrue(reducer.status.subtitle.contains("of 23 files"))
        XCTAssertGreaterThan(reducer.status.fraction, 0.3)
    }

    func testConcurrentProgressSumsFinishedAndInFlightBytes() {
        let progress = ConcurrentDownloadProgress()
        progress.addFinishedFile(size: 100)
        progress.setInFlight(path: "a.bin", written: 30)
        progress.setInFlight(path: "b.bin", written: 20)
        var snap = progress.snapshot()
        XCTAssertEqual(snap.receivedBytes, 150)
        XCTAssertEqual(snap.finishedFiles, 1)

        progress.completeInFlight(path: "a.bin", size: 80)
        snap = progress.snapshot()
        XCTAssertEqual(snap.receivedBytes, 200)
        XCTAssertEqual(snap.finishedFiles, 2)
    }

    func testRateLimitParsesTAndRetriesOnce() {
        XCTAssertEqual(
            HuggingFaceRateLimit.delaySeconds(from: #""api";r=0;t=55"#),
            55
        )
        XCTAssertEqual(
            HuggingFaceRateLimit.delaySeconds(fromHeaderFields: ["RateLimit": #""resolvers";r=0;t=12"#]),
            12
        )
        XCTAssertNil(HuggingFaceRateLimit.delaySeconds(from: "no-quota"))
        XCTAssertEqual(
            HuggingFaceRateLimit.retryDelaySeconds(
                statusCode: 429, rateLimitHeader: #""api";r=0;t=8"#, attempt: 0),
            8
        )
        XCTAssertEqual(
            HuggingFaceRateLimit.retryDelaySeconds(
                statusCode: 429, rateLimitHeader: nil, attempt: 0),
            1
        )
        XCTAssertNil(
            HuggingFaceRateLimit.retryDelaySeconds(
                statusCode: 429, rateLimitHeader: #""api";t=8"#, attempt: 1)
        )
        XCTAssertNil(
            HuggingFaceRateLimit.retryDelaySeconds(
                statusCode: 404, rateLimitHeader: #""api";t=8"#, attempt: 0)
        )
    }

    func testDestinationRejectsPathTraversal() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-cache")
        XCTAssertThrowsError(
            try ModelFileDownloader.resolvedDestination(path: "../escape.bin", cacheRoot: root)
        ) { error in
            XCTAssertEqual(error as? ModelFileDownloadError, .destinationOutsideCache)
        }
        XCTAssertNoThrow(
            try ModelFileDownloader.resolvedDestination(
                path: "Encoder.mlmodelc/coremldata.bin", cacheRoot: root)
        )
    }

    func testMidChunkBytesMoveTheBar() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyTick(
            phase: .downloading(completedFiles: 11, totalFiles: 17),
            receivedBytes: 10_700_000,
            totalBytes: 227_500_000,
            now: 0
        )
        let start = reducer.status.fraction
        reducer.applyTick(
            phase: .downloading(completedFiles: 11, totalFiles: 17),
            receivedBytes: 40_000_000,
            totalBytes: 227_500_000,
            now: 0.4
        )
        reducer.applyTick(
            phase: .downloading(completedFiles: 11, totalFiles: 17),
            receivedBytes: 80_000_000,
            totalBytes: 227_500_000,
            now: 2.2
        )
        XCTAssertGreaterThan(reducer.status.fraction, start)
        XCTAssertFalse(reducer.status.isAwaitingChunk)
        XCTAssertTrue(reducer.status.title.contains("of"))
        XCTAssertGreaterThan(reducer.status.bytesPerSecond, 0)
    }

    func testCompletionHighlightOnlyForUnusedFreshDownload() {
        XCTAssertTrue(
            ModelDownloadCompletion.isHighlighted(
                downloaded: true, active: false, recentlyCompleted: true)
        )
        XCTAssertFalse(
            ModelDownloadCompletion.isHighlighted(
                downloaded: true, active: true, recentlyCompleted: true)
        )
        XCTAssertFalse(
            ModelDownloadCompletion.isHighlighted(
                downloaded: true, active: false, recentlyCompleted: false)
        )
        XCTAssertFalse(
            ModelDownloadCompletion.isHighlighted(
                downloaded: false, active: false, recentlyCompleted: true)
        )
    }

    func testProgressEasingIsEaseInOut() {
        XCTAssertEqual(DownloadProgressEasing.smoothstep(0), 0, accuracy: 0.0001)
        XCTAssertEqual(DownloadProgressEasing.smoothstep(1), 1, accuracy: 0.0001)
        XCTAssertEqual(DownloadProgressEasing.smoothstep(0.5), 0.5, accuracy: 0.0001)
        XCTAssertLessThan(DownloadProgressEasing.smoothstep(0.25), 0.25)
        XCTAssertGreaterThan(DownloadProgressEasing.smoothstep(0.75), 0.75)

        let start = DownloadProgressEasing.interpolate(from: 0.45, to: 0.52, elapsed: 0)
        let mid = DownloadProgressEasing.interpolate(from: 0.45, to: 0.52, elapsed: 0.25)
        let end = DownloadProgressEasing.interpolate(from: 0.45, to: 0.52, elapsed: 0.5)
        XCTAssertEqual(start, 0.45, accuracy: 0.0001)
        XCTAssertGreaterThan(mid, start)
        XCTAssertLessThan(mid, end)
        XCTAssertEqual(end, 0.52, accuracy: 0.0001)
    }

    func testWhisperRisingFractionMovesBarWellAboveListingFloor() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyDownloadSample(
            whisper: true,
            fraction: 0,
            phase: .listing,
            receivedBytes: 0,
            totalBytes: 0,
            expectedBytes: 75_000_000,
            now: 0
        )
        XCTAssertLessThanOrEqual(reducer.status.fraction, 0.02)

        reducer.applyDownloadSample(
            whisper: true,
            fraction: 0.42,
            phase: .downloading(completedFiles: 3, totalFiles: 12),
            receivedBytes: 3,
            totalBytes: 12,
            expectedBytes: 75_000_000,
            now: 1
        )
        XCTAssertEqual(reducer.status.fraction, 0.42, accuracy: 0.001)
        XCTAssertGreaterThan(reducer.status.fraction, 0.01)
        XCTAssertFalse(reducer.status.isAwaitingChunk)
        XCTAssertEqual(reducer.status.totalBytes, 75_000_000)
        XCTAssertGreaterThan(reducer.status.receivedBytes, 20_000_000)
        XCTAssertTrue(reducer.status.title.contains("of"))
        XCTAssertFalse(reducer.status.subtitle.contains("Receiving data"))
        XCTAssertFalse(reducer.status.subtitle.contains("Still receiving"))
    }

    func testQuietWhisperTicksDoNotFlipAwaitingChunk() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyDownloadSample(
            whisper: true,
            fraction: 0.18,
            phase: .downloading(completedFiles: 1, totalFiles: 12),
            receivedBytes: 1,
            totalBytes: 12,
            expectedBytes: 75_000_000,
            now: 0
        )
        XCTAssertFalse(reducer.status.isAwaitingChunk)
        XCTAssertFalse(reducer.status.subtitle.contains("Still receiving"))

        reducer.applyDownloadSample(
            whisper: true,
            fraction: 0.18,
            phase: .downloading(completedFiles: 1, totalFiles: 12),
            receivedBytes: 1,
            totalBytes: 12,
            expectedBytes: 75_000_000,
            now: 0.4
        )
        reducer.applyDownloadSample(
            whisper: true,
            fraction: 0.18,
            phase: .downloading(completedFiles: 1, totalFiles: 12),
            receivedBytes: 1,
            totalBytes: 12,
            expectedBytes: 75_000_000,
            now: 0.8
        )
        XCTAssertFalse(reducer.status.isAwaitingChunk)
        XCTAssertFalse(reducer.status.subtitle.contains("Still receiving"))
        XCTAssertEqual(reducer.status.fraction, 0.18, accuracy: 0.001)
    }

    func testQuietByteTicksDoNotMarkAwaitingUntilSilenceWindow() {
        var reducer = ModelDownloadProgressReducer()
        reducer.applyTick(
            phase: .downloading(completedFiles: 2, totalFiles: 10),
            receivedBytes: 20_000_000,
            totalBytes: 100_000_000,
            now: 0
        )
        XCTAssertFalse(reducer.status.isAwaitingChunk)

        reducer.applyTick(
            phase: .downloading(completedFiles: 2, totalFiles: 10),
            receivedBytes: 20_000_000,
            totalBytes: 100_000_000,
            now: 0.4
        )
        XCTAssertFalse(reducer.status.isAwaitingChunk)

        XCTAssertTrue(reducer.tick(now: 1.6))
        XCTAssertTrue(reducer.status.isAwaitingChunk)
    }

    func testOnceThrowingContinuationResumesCancelAndIgnoresSecondResume() async {
        let gate = OnceThrowingContinuation<Int>()
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                gate.arm(cont)
                gate.resume(throwing: CancellationError())
                gate.resume(throwing: URLError(.cancelled))
                gate.resume(returning: 99)
            }
            XCTFail("Cancelled continuation should throw")
        } catch is CancellationError {
            // Expected — the first resume won and later resumes were no-ops.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloaderMissingFileResumesContinuation() async {
        let source = tempRoot.appendingPathComponent("missing-\(UUID().uuidString).bin")
        do {
            try await ModelFileDownloader.download(
                from: source,
                relativePath: "out.bin",
                cacheRoot: tempRoot
            ) { _, _ in }
            XCTFail("Missing file should fail the download")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testDownloaderCancelResumesContinuation() async {
        let source = tempRoot.appendingPathComponent("payload.bin")
        try? Data(repeating: 7, count: 2_000_000).write(to: source)

        let task = Task {
            try await ModelFileDownloader.download(
                from: source,
                relativePath: "cancelled.bin",
                cacheRoot: tempRoot
            ) { _, _ in }
        }
        task.cancel()

        do {
            try await task.value
            // A file:// copy can finish before cancel is observed; either
            // outcome means the continuation resumed instead of leaking.
        } catch {
            XCTAssertTrue(error is CancellationError || error is URLError)
        }
    }

    func testByteEstimatorKeepsLastRateWhenBytesStall() {
        var estimator = ByteRateEstimator()
        _ = estimator.add(received: 10_000_000, total: 100_000_000, at: 0)
        let moving = estimator.add(received: 40_000_000, total: 100_000_000, at: 2.5)
        let quiet = estimator.add(received: 40_000_000, total: 100_000_000, at: 5)
        XCTAssertGreaterThan(moving.bps, 0)
        XCTAssertEqual(quiet.bps, moving.bps, accuracy: 1)
    }

    func testDownloadRateAndETAFormatting() {
        XCTAssertEqual(ModelDownloadFormatting.percent(0.492), "49%")
        XCTAssertEqual(ModelDownloadFormatting.formatSpeed(2_097_152), "2.0 MB/s")
        XCTAssertEqual(ModelDownloadFormatting.formatETA(8), "a few seconds left")
        XCTAssertEqual(ModelDownloadFormatting.formatETA(40), "about 40s left")
        XCTAssertEqual(ModelDownloadFormatting.formatETA(125), "about 2 min left")
        XCTAssertEqual(ModelDownloadFormatting.shortFileName("JointDecisionv3.mlmodelc"), "Joint")

        var estimator = DownloadRateEstimator()
        _ = estimator.add(fraction: 0.10, at: 0, expectedBytes: 100_000_000)
        let rate = estimator.add(fraction: 0.30, at: 2, expectedBytes: 100_000_000)
        XCTAssertGreaterThan(rate.bps, 0)
        XCTAssertNotNil(rate.eta)
    }

    @discardableResult
    private func createDirectory(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return path.replacingOccurrences(
                of: "/private/var/",
                with: "/var/",
                options: [.anchored]
            )
        }
        return path
    }
}
