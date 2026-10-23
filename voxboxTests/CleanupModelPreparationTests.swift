import XCTest

@testable import voxbox

@MainActor
final class CleanupModelPreparationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var manager: PostProcessingModelManager!

    override func setUp() {
        super.setUp()
        suite = "voxbox.tests.cleanup-model-preparation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        manager = PostProcessingModelManager(defaults: defaults)
    }

    override func tearDown() {
        manager.endPreparingForTesting()
        defaults.removePersistentDomain(forName: suite)
        OSCapabilities.testOverride = nil
        super.tearDown()
    }

    // MARK: - T1 preparing flag

    func testPreparingFlagIsIdleByDefault() {
        XCTAssertNil(manager.preparingVariant)
        XCTAssertFalse(manager.isPreparing(apple))
        XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(apple, manager: manager))
    }

    func testPreparingFlagIsSetForSelectedDownloadedMLXWhileHookIsActive() {
        OSCapabilities.withTestOverride(true) {
            manager.markDownloadedForTesting(qwen.variant)
            manager.selectedVariant = qwen.variant

            XCTAssertNil(
                manager.preparingVariant,
                "T1 does not load live weights; idle until the test hook runs")
            XCTAssertFalse(manager.isPreparing(qwen))
            XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(qwen, manager: manager))

            manager.beginPreparingForTesting(qwen.variant)

            XCTAssertEqual(manager.preparingVariant, qwen.variant)
            XCTAssertTrue(manager.isPreparing(qwen))
            XCTAssertTrue(CleanupModelStatusAccessory.isPreparing(qwen, manager: manager))

            manager.endPreparingForTesting()

            XCTAssertNil(manager.preparingVariant)
            XCTAssertFalse(manager.isPreparing(qwen))
            XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(qwen, manager: manager))
        }
    }

    func testAccessoryIsPreparingOnlyForThatVariant() {
        OSCapabilities.withTestOverride(true) {
            manager.markDownloadedForTesting(qwen.variant)
            manager.markDownloadedForTesting(llama.variant)
            manager.selectedVariant = qwen.variant
            manager.beginPreparingForTesting(qwen.variant)

            XCTAssertTrue(CleanupModelStatusAccessory.isPreparing(qwen, manager: manager))
            XCTAssertFalse(
                CleanupModelStatusAccessory.isPreparing(llama, manager: manager),
                "a non-selected downloadable row stays idle")
            XCTAssertFalse(
                CleanupModelStatusAccessory.isPreparing(apple, manager: manager),
                "Apple Intelligence never shows preparing")
            XCTAssertFalse(manager.isPreparing(llama))
            XCTAssertFalse(manager.isPreparing(apple))
        }
    }

    func testSelectingAppleIntelligenceClearsPreparing() {
        OSCapabilities.withTestOverride(true) {
            manager.markDownloadedForTesting(qwen.variant)
            manager.selectedVariant = qwen.variant
            manager.beginPreparingForTesting(qwen.variant)
            XCTAssertEqual(manager.preparingVariant, qwen.variant)

            manager.selectedVariant = PostProcessingModel.appleSystemVariant

            XCTAssertNil(manager.preparingVariant)
            XCTAssertFalse(manager.isPreparing(qwen))
            XCTAssertFalse(manager.isPreparing(apple))
            XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(qwen, manager: manager))
            XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(apple, manager: manager))
        }
    }

    func testDeletingSelectedModelClearsPreparing() {
        OSCapabilities.withTestOverride(true) {
            manager.markDownloadedForTesting(qwen.variant)
            manager.selectedVariant = qwen.variant
            manager.beginPreparingForTesting(qwen.variant)

            XCTAssertTrue(manager.deleteModel(variant: qwen.variant))

            XCTAssertEqual(manager.selectedVariant, PostProcessingModel.appleSystemVariant)
            XCTAssertNil(manager.preparingVariant)
            XCTAssertFalse(manager.isPreparing(qwen))
        }
    }

    func testAppleSystemKindNeverPreparesEvenIfHookSetsThatVariant() {
        manager.beginPreparingForTesting(PostProcessingModel.appleSystemVariant)
        XCTAssertFalse(manager.isPreparing(apple))
        XCTAssertFalse(CleanupModelStatusAccessory.isPreparing(apple, manager: manager))
        manager.endPreparingForTesting()
    }

    // MARK: - Catalog fixtures

    private var apple: PostProcessingModel { PostProcessingModel.catalog[0] }

    private var qwen: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == "mlx-qwen3-1.7b-4bit" }!
    }

    private var llama: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == "mlx-llama-3.2-1b-instruct-4bit" }!
    }
}
