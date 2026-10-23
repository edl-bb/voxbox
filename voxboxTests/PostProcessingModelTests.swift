import XCTest

@testable import voxbox

final class PostProcessingModelTests: XCTestCase {

    override func tearDown() {
        OSCapabilities.testOverride = nil
        super.tearDown()
    }

    // MARK: - Catalog

    func testCatalogVariantsAreUnique() {
        let variants = PostProcessingModel.catalog.map(\.variant)
        XCTAssertEqual(variants.count, Set(variants).count)
    }

    func testAppleSystemModelLeadsTheCatalog() {
        let first = PostProcessingModel.catalog[0]
        XCTAssertEqual(first.variant, PostProcessingModel.appleSystemVariant)
        XCTAssertEqual(first.kind, .appleSystem)
        XCTAssertNil(first.huggingFaceRepo)
    }

    func testDownloadableModelsHaveReposAndSizes() {
        for model in PostProcessingModel.catalog where model.kind == .mlx {
            XCTAssertNotNil(model.huggingFaceRepo, "\(model.variant) needs a repo")
            XCTAssertGreaterThan(model.approxSizeBytes, 0)
            XCTAssertGreaterThan(model.minimumRAMGB, 0)
        }
    }

    func testOfferedCatalogIsAppleOnlyWhenCustomCleanupModelsAreOff() {
        OSCapabilities.withTestOverride(false) {
            XCTAssertEqual(PostProcessingModel.offered.map(\.kind), [.appleSystem])
            XCTAssertEqual(PostProcessingModel.offered.count, 1)
            XCTAssertFalse(OSCapabilities.customCleanupModels)
            XCTAssertFalse(PostProcessingModel.downloadableModelsEnabled)
        }
    }

    func testOfferedCatalogIncludesDownloadableModelsWhenGateIsOn() {
        OSCapabilities.withTestOverride(true) {
            XCTAssertTrue(OSCapabilities.customCleanupModels)
            XCTAssertEqual(PostProcessingModel.offered, PostProcessingModel.catalog)
            XCTAssertTrue(PostProcessingModel.offered.contains { $0.kind == .mlx })
            XCTAssertGreaterThanOrEqual(
                PostProcessingModel.offered.filter { $0.kind == .mlx }.count, 4,
                "Llama/Qwen rows must appear when the OS gate is on")
        }
    }

    // MARK: - Hugging Face API helpers

    func testMetadataAndFileURLs() {
        XCTAssertEqual(
            HuggingFaceRepoAPI.metadataURL(repo: "mlx-community/Qwen3-1.7B-4bit").absoluteString,
            "https://huggingface.co/api/models/mlx-community/Qwen3-1.7B-4bit?blobs=true")
        XCTAssertEqual(
            HuggingFaceRepoAPI.fileURL(
                repo: "mlx-community/Qwen3-1.7B-4bit", path: "model.safetensors"
            ).absoluteString,
            "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/resolve/main/model.safetensors")
    }

    func testModelFileFilterSkipsRepoHousekeeping() {
        XCTAssertTrue(HuggingFaceRepoAPI.isModelFile("model.safetensors"))
        XCTAssertTrue(HuggingFaceRepoAPI.isModelFile("config.json"))
        XCTAssertTrue(HuggingFaceRepoAPI.isModelFile("tokenizer.model"))
        XCTAssertFalse(HuggingFaceRepoAPI.isModelFile("README.md"))
        XCTAssertFalse(HuggingFaceRepoAPI.isModelFile(".gitattributes"))
        XCTAssertFalse(HuggingFaceRepoAPI.isModelFile("assets/banner.png"))
    }

    func testModelFilesParsesBlobsMetadata() throws {
        let json = """
            {
              "siblings": [
                {"rfilename": ".gitattributes", "size": 100},
                {"rfilename": "README.md", "size": 2000},
                {"rfilename": "config.json", "size": 800},
                {"rfilename": "model.safetensors", "size": 900000000},
                {"rfilename": "tokenizer.json"}
              ]
            }
            """.data(using: .utf8)!
        let files = try HuggingFaceRepoAPI.modelFiles(fromMetadata: json)
        XCTAssertEqual(
            files.map(\.path), ["config.json", "model.safetensors", "tokenizer.json"])
        XCTAssertEqual(files[1].sizeBytes, 900_000_000)
        XCTAssertEqual(files[2].sizeBytes, 0, "missing size decodes to 0")
    }

    // MARK: - Manager selection

    func testSelectionDefaultsToAppleSystem() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        XCTAssertEqual(manager.selectedVariant, PostProcessingModel.appleSystemVariant)
        XCTAssertEqual(manager.selectedModel.kind, .appleSystem)
    }

    func testDownloadableSelectionPersists() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        manager.selectedVariant = "mlx-qwen3-1.7b-4bit"
        let reloaded = PostProcessingModelManager(defaults: defaults)
        XCTAssertEqual(reloaded.selectedVariant, "mlx-qwen3-1.7b-4bit")
    }

    func testStoredDownloadableSelectionResolvesToAppleWhileParked() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        manager.selectedVariant = "mlx-qwen3-1.7b-4bit"
        OSCapabilities.withTestOverride(false) {
            XCTAssertEqual(
                manager.selectedModel.kind, .appleSystem,
                "a 1.2 choice must not silently pick a parked model")
            XCTAssertEqual(PostProcessingModel.offered.map(\.kind), [.appleSystem])
            XCTAssertEqual(
                manager.selectedVariant, "mlx-qwen3-1.7b-4bit",
                "the stored choice is kept for when the rows return")
        }
    }

    func testStoredDownloadableSelectionIsHonoredWhenGateIsOn() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        manager.selectedVariant = "mlx-qwen3-1.7b-4bit"
        OSCapabilities.withTestOverride(true) {
            XCTAssertEqual(manager.selectedModel.variant, "mlx-qwen3-1.7b-4bit")
            XCTAssertEqual(manager.selectedModel.kind, .mlx)
        }
    }

    func testDeleteFallsBackToAppleSystemSelection() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        manager.selectedVariant = "mlx-qwen3-1.7b-4bit"
        manager.deleteModel(variant: "mlx-qwen3-1.7b-4bit")
        XCTAssertEqual(manager.selectedVariant, PostProcessingModel.appleSystemVariant)
    }

    func testDeleteRefusesTheSystemModel() {
        let suite = "voxbox.tests.postprocessing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = PostProcessingModelManager(defaults: defaults)
        XCTAssertFalse(manager.deleteModel(variant: PostProcessingModel.appleSystemVariant))
    }
}
