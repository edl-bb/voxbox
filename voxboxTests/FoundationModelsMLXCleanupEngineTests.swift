import XCTest
import FoundationModels

@testable import voxbox

@available(macOS 27, *)
@MainActor
final class FoundationModelsMLXCleanupEngineTests: XCTestCase {

    private var qwenCatalog: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == "mlx-qwen3-1.7b-4bit" }!
    }

    private var llamaCatalog: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == "mlx-llama-3.2-1b-instruct-4bit" }!
    }

    // MARK: - T1 availability (no weights)

    func testIsAvailableWhenConfigTokenizerAndSafetensorsExist() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePlaceholderModelFiles(in: directory)

        let engine = FoundationModelsMLXCleanupEngine(model: qwenCatalog, directory: directory)
        XCTAssertTrue(engine.isAvailable)
        XCTAssertEqual(engine.displayName, "Qwen 3 1.7B")
    }

    func testIsUnavailableInEmptyDirectoryAndConstructionDoesNotThrow() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = FoundationModelsMLXCleanupEngine(model: qwenCatalog, directory: directory)
        XCTAssertFalse(engine.isAvailable)
        XCTAssertEqual(engine.displayName, qwenCatalog.name)
    }

    func testIsUnavailableWhenSafetensorsAreMissing() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))

        let engine = FoundationModelsMLXCleanupEngine(model: qwenCatalog, directory: directory)
        XCTAssertFalse(engine.isAvailable)
    }

    func testCleanupOnEmptyDirectoryThrowsRuntimeUnavailable() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FoundationModelsMLXCleanupEngine(model: qwenCatalog, directory: directory)

        let request = TranscriptFormatterService.request(
            for: "um so I think we should ship on thursday",
            intensity: .lightCleanup,
            includeMarkdownFormatting: false)
        do {
            _ = try await engine.cleanup(request)
            XCTFail("empty dir must throw so TranscriptCleanupPipeline can fall back")
        } catch MLXCleanupEngineError.runtimeUnavailable {
            // Pipeline.run already retries on Apple Intelligence for any
            // non-contentFilter error from a non-Apple engine.
        }
    }

    func testRuntimeUnavailableFallsBackThroughExistingPipeline() async throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FoundationModelsMLXCleanupEngine(model: qwenCatalog, directory: directory)
        let fallback = ScriptedCleanupEngine(displayName: "Apple Intelligence") { _ in
            "So I think we should ship the release on Thursday and tell Priya."
        }
        let pipeline = TranscriptCleanupPipeline.scripted(
            engine: engine, fallback: fallback, selected: qwenCatalog)

        let outcome = await pipeline.clean(
            raw: "um so I think uh we should ship the release on thursday and tell priya",
            plan: .test(.light))

        XCTAssertTrue(outcome.fellBackToSystemModel)
        XCTAssertEqual(outcome.engineName, "Apple Intelligence")
        XCTAssertFalse(outcome.output.isEmpty)
    }

    func testBuiltInCleanupUsesGreedyGenerationOptions() {
        let request = TranscriptFormatterService.request(
            for: "um so I think we should ship on thursday",
            intensity: .lightCleanup,
            includeMarkdownFormatting: false)
        XCTAssertNil(
            AppleIntelligenceCleanupEngine.generationOptions(for: request).temperature,
            "built-in levels stay greedy; the session pool uses these options for MLX too")
        XCTAssertEqual(request.temperature, 0)
    }

    func testCatalogExtraEOSTokensMatchLLMRegistry() {
        XCTAssertEqual(qwenCatalog.extraEOSTokens, ["<|im_end|>"])
        XCTAssertEqual(
            PostProcessingModel.catalog.first { $0.variant == "mlx-qwen3-4b-4bit" }!.extraEOSTokens,
            ["<|im_end|>"])
        XCTAssertEqual(llamaCatalog.extraEOSTokens, ["<|eot_id|>"])
        XCTAssertEqual(
            PostProcessingModel.catalog.first { $0.variant == "mlx-llama-3.2-3b-instruct-4bit" }!
                .extraEOSTokens,
            ["<|eot_id|>"])
        XCTAssertEqual(PostProcessingModel.catalog[0].extraEOSTokens, [])
    }

    func testFamilyDetectsFromVariantAndConfig() throws {
        XCTAssertEqual(LocalModelFamily.detect(variant: qwenCatalog.variant), .qwen3)
        XCTAssertEqual(LocalModelFamily.detect(variant: llamaCatalog.variant), .llama3)
        XCTAssertEqual(LocalModelFamily.detect(modelType: "llama"), .llama3)
        XCTAssertEqual(LocalModelFamily.detect(modelType: "qwen3"), .qwen3)

        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"model_type\":\"qwen3\"}".utf8).write(
            to: directory.appendingPathComponent("config.json"))
        XCTAssertEqual(try LocalModelFamily.detect(in: directory), .qwen3)
    }

    // MARK: - T2 live (weights on disk)

    func testLiveLlamaLightCleanupProducesNonEmptyOutput() async throws {
        continueAfterFailure = false
        let model = llamaCatalog
        let dir = PostProcessingModelManager.storageDir(for: model.variant)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path),
            "env-block: Llama 3.2 1B weights missing at \(dir.path)")

        executionTimeAllowance = 180
        let engine = FoundationModelsMLXCleanupEngine(model: model, directory: dir)
        XCTAssertEqual(engine.displayName, "Llama 3.2 1B Instruct")
        XCTAssertTrue(engine.isAvailable, "config.json exists but hasModelFiles is false at \(dir.path)")

        let pipeline = TranscriptCleanupPipeline.scripted(engine: engine, selected: model)
        let outcome = await TranscriptCleanupPreview.preview(
            text: "um so I think we should ship the release on thursday and tell priya",
            option: .light,
            includeMarkdown: false,
            autoEdit: false,
            allowStepDown: false,
            pipeline: pipeline)

        XCTAssertFalse(outcome.output.isEmpty, "Llama Light cleanup returned empty text: \(outcome)")
        XCTAssertEqual(engine.displayName, "Llama 3.2 1B Instruct")
        XCTAssertEqual(
            outcome.engineName, "Llama 3.2 1B Instruct",
            "cleanup must run on the catalog model, not fall back: \(outcome.error ?? "no error"); attempts: \(outcome.attempts)")
        XCTAssertFalse(outcome.fellBackToSystemModel)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-fm-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePlaceholderModelFiles(in directory: URL) throws {
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data().write(to: directory.appendingPathComponent("dummy.safetensors"))
    }
}
