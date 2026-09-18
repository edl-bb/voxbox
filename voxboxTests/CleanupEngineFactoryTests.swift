import XCTest

@testable import voxbox

final class CleanupEngineFactoryTests: XCTestCase {

    override func tearDown() {
        OSCapabilities.testOverride = nil
        super.tearDown()
    }

    // MARK: - Factory routing

    func testFactoryReturnsAppleIntelligenceForSystemModel() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = CleanupEngineFactory.engine(
            for: PostProcessingModel.catalog[0],
            manager: manager)

        XCTAssertTrue(
            engine is AppleIntelligenceCleanupEngine,
            "Apple Intelligence must keep its own engine type")
    }

    func testFactoryFallsBackToAppleIntelligenceWhenMLXIsNotDownloaded() {
        OSCapabilities.withTestOverride(true) {
            let (manager, defaults, suite) = makeManager()
            defer { defaults.removePersistentDomain(forName: suite) }

            // A variant the manager never scanned on disk, so `isDownloaded` is
            // false even if leftover 1.2 weights exist for catalog models.
            let parked = PostProcessingModel(
                variant: "mlx-not-downloaded-\(UUID().uuidString)",
                name: "Parked Test Model",
                provider: "Test",
                details: "Not on disk",
                kind: .mlx,
                huggingFaceRepo: "test/parked",
                approxSizeBytes: 1_000,
                minimumRAMGB: 8)
            XCTAssertFalse(manager.isDownloaded(parked.variant))

            let engine = CleanupEngineFactory.engine(for: parked, manager: manager)

            XCTAssertTrue(
                engine is AppleIntelligenceCleanupEngine,
                "missing MLX weights must not fail cleanup")
        }
    }

    func testFactoryReturnsParkedMLXStubWhenGateOffAndDownloaded() {
        OSCapabilities.withTestOverride(false) {
            let (manager, defaults, suite) = makeManager()
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = parkedCatalogModel
            manager.markDownloadedForTesting(model.variant)
            XCTAssertTrue(manager.isDownloaded(model.variant))

            let engine = CleanupEngineFactory.engine(for: model, manager: manager)
            XCTAssertTrue(
                engine is MLXCleanupEngine,
                "gate-off downloaded MLX uses the parked stub")
        }
    }

    func testFactoryReturnsFoundationModelsMLXWhenGateOnAndDownloaded() throws {
        try OSCapabilities.withTestOverride(true) {
            let (manager, defaults, suite) = makeManager()
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = parkedCatalogModel
            manager.markDownloadedForTesting(model.variant)
            XCTAssertTrue(manager.isDownloaded(model.variant))

            let engine = CleanupEngineFactory.engine(for: model, manager: manager)
            guard #available(macOS 27, *) else {
                throw XCTSkip(
                    "FoundationModelsMLXCleanupEngine requires macOS 27; this host is \(ProcessInfo.processInfo.operatingSystemVersion)")
            }
            XCTAssertTrue(
                engine is FoundationModelsMLXCleanupEngine,
                "downloaded MLX on macOS 27 must use the Foundation Models engine")
        }
    }

    // MARK: - MLX stub

    func testMLXEngineWithExistingDirectoryIsAvailableAndThrowsRuntimeUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = MLXCleanupEngine(model: parkedCatalogModel, directory: directory)
        XCTAssertTrue(engine.isAvailable, "a present directory means the stub can be selected")
        XCTAssertEqual(engine.displayName, parkedCatalogModel.name)

        let request = TranscriptFormatterService.request(
            for: "hello world this is a test of the parked engine",
            intensity: .lightCleanup,
            includeMarkdownFormatting: false)
        do {
            _ = try await engine.cleanup(request)
            XCTFail("the parked MLX stub must throw rather than run cleanup")
        } catch MLXCleanupEngineError.runtimeUnavailable {
            // expected
        } catch {
            XCTFail("expected runtimeUnavailable, got \(error)")
        }
    }

    func testMLXEngineWithMissingDirectoryIsUnavailable() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-mlx-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let engine = MLXCleanupEngine(model: parkedCatalogModel, directory: directory)
        XCTAssertFalse(engine.isAvailable)
    }

    func testFoundationModelsMLXEngineWithEmptyDirectoryIsUnavailableAndThrows() async throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip(
                "FoundationModelsMLXCleanupEngine requires macOS 27; this host is \(ProcessInfo.processInfo.operatingSystemVersion)")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-fm-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = FoundationModelsMLXCleanupEngine(
            model: parkedCatalogModel, directory: directory)
        XCTAssertFalse(engine.isAvailable, "empty dir has no config/tokenizer/weights")
        XCTAssertEqual(engine.displayName, parkedCatalogModel.name)

        let request = TranscriptFormatterService.request(
            for: "hello world this is a test of the foundation models engine",
            intensity: .lightCleanup,
            includeMarkdownFormatting: false)
        do {
            _ = try await engine.cleanup(request)
            XCTFail("missing weights must throw so the pipeline can fall back")
        } catch MLXCleanupEngineError.runtimeUnavailable {
            // expected — TranscriptCleanupPipeline already retries on Apple Intelligence
        } catch {
            XCTFail("expected runtimeUnavailable, got \(error)")
        }
    }

    // MARK: - Helpers

    private var parkedCatalogModel: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == "mlx-qwen3-1.7b-4bit" }!
    }

    private func makeManager() -> (PostProcessingModelManager, UserDefaults, String) {
        let suite = "voxbox.tests.cleanup-engine-factory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PostProcessingModelManager(defaults: defaults), defaults, suite)
    }
}
