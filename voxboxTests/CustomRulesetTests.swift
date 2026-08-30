import XCTest

@testable import voxbox

final class CustomRulesetTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voxbox.tests.rulesets.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Store

    func testAddRulesetAssignsDefaultNameAndBecomesActive() {
        let store = CustomRulesetStore(defaults: defaults)
        let created = store.addRuleset()
        XCTAssertEqual(created?.name, "Ruleset 1")
        XCTAssertEqual(store.rulesets.count, 1)
        XCTAssertEqual(store.activeRulesetID, created?.id)
    }

    func testStoreCapsAtFiveRulesets() {
        let store = CustomRulesetStore(defaults: defaults)
        for _ in 0..<CustomRulesetStore.maximumRulesets {
            XCTAssertNotNil(store.addRuleset())
        }
        XCTAssertFalse(store.canAddRuleset)
        XCTAssertNil(store.addRuleset(), "sixth ruleset must be refused")
        XCTAssertEqual(store.rulesets.count, CustomRulesetStore.maximumRulesets)
    }

    func testUpdatePersistsAndClampsTemperature() {
        let store = CustomRulesetStore(defaults: defaults)
        var ruleset = store.addRuleset()!
        ruleset.name = "Meeting notes"
        ruleset.instructions = "Tidy the transcript into meeting minutes."
        ruleset.temperature = 9.0
        store.update(ruleset)

        let reloaded = CustomRulesetStore(defaults: defaults)
        XCTAssertEqual(reloaded.rulesets.first?.name, "Meeting notes")
        XCTAssertEqual(
            reloaded.rulesets.first?.temperature,
            CustomRulesetStore.temperatureRange.upperBound)
    }

    func testDeleteActiveRulesetFallsBackToFirstRemaining() {
        let store = CustomRulesetStore(defaults: defaults)
        let first = store.addRuleset()!
        let second = store.addRuleset()!
        store.activeRulesetID = second.id
        store.delete(id: second.id)
        XCTAssertEqual(store.activeRulesetID, first.id)
        store.delete(id: first.id)
        XCTAssertNil(store.activeRulesetID)
    }

    func testDanglingActiveIDIsHealedOnLoad() {
        let store = CustomRulesetStore(defaults: defaults)
        let kept = store.addRuleset()!
        defaults.set(UUID().uuidString, forKey: CustomRulesetStore.activeIDKey)
        let reloaded = CustomRulesetStore(defaults: defaults)
        XCTAssertEqual(reloaded.activeRulesetID, kept.id)
    }

    func testEmptyInstructionsAreNotUsable() {
        let store = CustomRulesetStore(defaults: defaults)
        var ruleset = store.addRuleset()!
        XCTAssertNil(store.usableActiveRuleset)
        ruleset.instructions = "Fix punctuation only."
        store.update(ruleset)
        XCTAssertNotNil(store.usableActiveRuleset)
    }

    // MARK: - Formatting requests

    func testCustomRequestSendsInstructionsVerbatimWithNoBuiltInStages() {
        let ruleset = CustomCleanupRuleset(
            name: "Verbatim",
            instructions: "Rewrite the transcript as a haiku.",
            temperature: 0.7)
        let request = TranscriptFormatterService.request(
            for: "some dictated text here", ruleset: ruleset)

        XCTAssertEqual(request.instructionStages, ["Rewrite the transcript as a haiku."])
        XCTAssertFalse(request.instructions.contains(FormattingPromptStage.markdownFormatting))
        XCTAssertFalse(request.instructions.contains(FormattingPromptStage.outputTranscriptOnly))
        XCTAssertEqual(request.temperature, 0.7, accuracy: 0.0001)
        XCTAssertNil(request.maximumChangeRatio, "custom rulesets run ungoverned")
    }

    func testCustomRequestClampsTemperatureIntoRange() {
        let ruleset = CustomCleanupRuleset(name: "Hot", instructions: "x", temperature: 42)
        let request = TranscriptFormatterService.request(for: "text", ruleset: ruleset)
        XCTAssertEqual(
            request.temperature, CustomRulesetStore.temperatureRange.upperBound)
    }

    func testBuiltInRequestsStayDeterministicAndGoverned() throws {
        let request = TranscriptFormatterService.request(
            for: "some dictated text here",
            intensity: .polish,
            includeMarkdownFormatting: false)
        XCTAssertEqual(request.temperature, 0.0)
        XCTAssertEqual(
            try XCTUnwrap(request.maximumChangeRatio),
            try XCTUnwrap(FormattingIntensity.polish.maximumChangeRatio))
    }

    func testEffectiveRequestUsesRulesetWhenCustomAndUsable() {
        let ruleset = CustomCleanupRuleset(
            name: "R", instructions: "Custom rules.", temperature: 0.5)
        let request = TranscriptFormatterService.effectiveRequest(
            for: "text",
            intensity: .custom,
            includeMarkdownFormatting: true,
            customRuleset: ruleset)
        XCTAssertEqual(request.instructionStages, ["Custom rules."])
        XCTAssertNil(request.maximumChangeRatio)
    }

    func testEffectiveRequestFallsBackToLightCleanupWithoutUsableRuleset() throws {
        for ruleset in [nil, CustomCleanupRuleset(name: "Empty", instructions: "   ")] {
            let request = TranscriptFormatterService.effectiveRequest(
                for: "text",
                intensity: .custom,
                includeMarkdownFormatting: false,
                customRuleset: ruleset)
            XCTAssertEqual(
                try XCTUnwrap(request.maximumChangeRatio),
                try XCTUnwrap(FormattingIntensity.lightCleanup.maximumChangeRatio),
                "the ungoverned path is only for real user rules")
            XCTAssertTrue(
                request.instructions.contains(FormattingPromptStage.outputTranscriptOnly))
            XCTAssertEqual(request.temperature, 0.0)
        }
    }

    func testEffectiveRequestIgnoresRulesetForBuiltInLevels() {
        let ruleset = CustomCleanupRuleset(name: "R", instructions: "Custom rules.")
        let request = TranscriptFormatterService.effectiveRequest(
            for: "text",
            intensity: .lightCleanup,
            includeMarkdownFormatting: false,
            customRuleset: ruleset)
        XCTAssertFalse(request.instructions.contains("Custom rules."))
        XCTAssertNotNil(request.maximumChangeRatio)
    }
}
