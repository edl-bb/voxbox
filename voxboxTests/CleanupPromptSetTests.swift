import XCTest

@testable import voxbox

final class CleanupPromptSetTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voxbox.tests.cleanupdebug.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Compiled set

    func testWrapTemplateCarriesThePlaceholder() {
        XCTAssertTrue(CleanupPromptSet.compiled.wrapTemplate.contains(CleanupPromptSet.transcriptPlaceholder))
        XCTAssertTrue(CleanupPromptSet.legacy.wrapTemplate.contains(CleanupPromptSet.transcriptPlaceholder))
    }

    func testEveryBuiltInLevelHasABudgetAndASuffix() {
        for level in FormattingIntensity.builtInCases {
            XCTAssertNotNil(CleanupPromptSet.compiled.budget(for: level), "\(level)")
            XCTAssertNotNil(CleanupPromptSet.compiled.repeatSuffixes[level], "\(level)")
        }
        XCTAssertNil(CleanupPromptSet.compiled.budget(for: .custom))
    }

    func testBudgetsLoosenWithLevel() {
        let set = CleanupPromptSet.compiled
        let basic = set.budgets[.formatting]!
        let light = set.budgets[.lightCleanup]!
        let polish = set.budgets[.polish]!
        XCTAssertLessThan(basic.maxCostRatio, light.maxCostRatio)
        XCTAssertLessThan(light.maxCostRatio, polish.maxCostRatio)
        XCTAssertLessThanOrEqual(basic.minFreeEdits, light.minFreeEdits)
        XCTAssertLessThanOrEqual(light.minFreeEdits, polish.minFreeEdits)
        XCTAssertGreaterThan(basic.minRetention, light.minRetention)
        XCTAssertGreaterThan(light.minRetention, polish.minRetention)
    }

    func testUserPromptForCustomHasNoSuffix() {
        let set = CleanupPromptSet.compiled
        XCTAssertEqual(set.userPrompt(for: "hello", intensity: nil), "Clean up this dictation. Reply with only the cleaned text.\n\nDICTATION:\nhello")
        XCTAssertTrue(set.userPrompt(for: "hello", intensity: .polish).hasSuffix(set.repeatSuffixes[.polish]!))
    }

    func testSampleTranscriptsClearTheRealMinimumWordCount() {
        for sample in CleanupSampleTranscripts.allCases {
            XCTAssertGreaterThanOrEqual(sample.wordCount, TranscriptFormatterService.minimumWordCount * 3, sample.title)
            XCTAssertFalse(sample.title.isEmpty)
        }
        XCTAssertEqual(CleanupSampleTranscripts.onboardingDefault, .followUp)
        XCTAssertTrue(CleanupSampleTranscripts.followUp.text.contains("sam.reilly@northwindlabs.com"))
        XCTAssertTrue(CleanupSampleTranscripts.teamUpdate.text.contains("https://staging.voxbox.app"))
    }

    // MARK: - Debug overlay

    func testOverlayIsIdentityWhenNothingIsSet() {
        XCTAssertEqual(TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults), .compiled)
    }

    func testOverlayReplacesTextFieldsAndIgnoresBlankOnes() {
        TranscriptCleanupDebug.setOverlay("Be terse.", for: .light, defaults: defaults)
        TranscriptCleanupDebug.setOverlay("   ", for: .polish, defaults: defaults)
        #if DEBUG
            let set = TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults)
            XCTAssertEqual(set.light, "Be terse.")
            XCTAssertEqual(set.polish, CleanupPromptSet.compiled.polish)
            XCTAssertEqual(TranscriptCleanupDebug.overlayValue(.light, defaults: defaults), "Be terse.")
            XCTAssertNil(TranscriptCleanupDebug.overlayValue(.polish, defaults: defaults))
        #else
            XCTAssertEqual(TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults), .compiled)
        #endif
    }

    func testOverlayRejectsAWrapTemplateWithoutThePlaceholder() {
        TranscriptCleanupDebug.setOverlay("Just the text please", for: .wrapTemplate, defaults: defaults)
        XCTAssertEqual(
            TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults).wrapTemplate,
            CleanupPromptSet.compiled.wrapTemplate)
    }

    func testOverlayParsesBudgetsAndFillers() {
        TranscriptCleanupDebug.setOverlay("0.25, 4, 0.7", for: .budgetLight, defaults: defaults)
        TranscriptCleanupDebug.setOverlay("um, Uh , er", for: .pureFillers, defaults: defaults)
        #if DEBUG
            let set = TranscriptCleanupDebug.overlay(on: .compiled, defaults: defaults)
            XCTAssertEqual(set.budgets[.lightCleanup], GuardrailBudget(maxCostRatio: 0.25, minFreeEdits: 4, minRetention: 0.7))
            XCTAssertEqual(set.fillerLexicon.pureTokens, ["um", "uh", "er"])
        #endif
    }

    func testBudgetParsingRoundTripsAndRejectsGarbage() {
        let budget = GuardrailBudget(maxCostRatio: 0.2, minFreeEdits: 3, minRetention: 0.8)
        XCTAssertEqual(TranscriptCleanupDebug.parseBudget(TranscriptCleanupDebug.budgetText(budget)), budget)
        XCTAssertNil(TranscriptCleanupDebug.parseBudget("0.2, 3"))
        XCTAssertNil(TranscriptCleanupDebug.parseBudget("a, b, c"))
        XCTAssertEqual(
            TranscriptCleanupDebug.parseBudget("9, -1, 2"),
            GuardrailBudget(maxCostRatio: 5, minFreeEdits: 0, minRetention: 1), "values are clamped")
    }

    func testResetClearsEveryField() {
        for field in TranscriptCleanupDebug.Field.allCases {
            TranscriptCleanupDebug.setOverlay("x", for: field, defaults: defaults)
        }
        TranscriptCleanupDebug.resetOverlay(defaults: defaults)
        for field in TranscriptCleanupDebug.Field.allCases {
            XCTAssertNil(defaults.string(forKey: field.key), field.rawValue)
        }
    }
}
