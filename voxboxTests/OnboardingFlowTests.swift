import XCTest

@testable import voxbox

final class OnboardingFlowTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "voxbox.tests.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Recording mode

    func testRecordingModeKeepsTheStoredIntegerContract() {
        XCTAssertEqual(RecordingMode.defaultsKey, "recordingMode")
        XCTAssertEqual(RecordingMode.hold.rawValue, 0)
        XCTAssertEqual(RecordingMode.toggle.rawValue, 1)

        XCTAssertEqual(RecordingMode.current(in: defaults), .hold, "unset means hold, like integer(forKey:)")
        defaults.set(1, forKey: RecordingMode.defaultsKey)
        XCTAssertEqual(RecordingMode.current(in: defaults), .toggle)
        defaults.set(7, forKey: RecordingMode.defaultsKey)
        XCTAssertEqual(RecordingMode.current(in: defaults), .hold, "unknown values fall back to hold")

        RecordingMode.toggle.save(to: defaults)
        XCTAssertEqual(defaults.integer(forKey: "recordingMode"), 1, "the AppDelegate path reads a plain integer")
    }

    func testRecordingModeCopyNamesTheHotkey() {
        XCTAssertTrue(RecordingMode.hold.onboardingDescription(hotkey: "Fn").hasPrefix("Hold Fn while"))
        XCTAssertTrue(RecordingMode.toggle.onboardingDescription(hotkey: "⌘D").contains("Press ⌘D once"))
        XCTAssertTrue(RecordingMode.onboardingSubtitle(hotkey: "Right ⌘").contains("Right ⌘ key"))
        XCTAssertEqual(RecordingMode.hold.chipLabel, "Hold")
        XCTAssertEqual(RecordingMode.toggle.menuTitle, "Toggle on / off")
        XCTAssertEqual(RecordingMode.hold.settingsTitle, "Hold to record")
    }

    // MARK: - Steps

    func testStepsRunInOrderAndEndAtTheModelPage() {
        XCTAssertEqual(
            OnboardingStep.allCases, [.welcome, .globeKey, .recordingMode, .permissions, .cleanup, .model])
        XCTAssertEqual(OnboardingStep.welcome.next, .globeKey)
        XCTAssertEqual(OnboardingStep.recordingMode.next, .permissions)
        XCTAssertEqual(OnboardingStep.permissions.next, .cleanup)
        XCTAssertNil(OnboardingStep.model.next)
        XCTAssertTrue(OnboardingStep.model.isLast)
        XCTAssertFalse(OnboardingStep.welcome.showsStepDots)
        XCTAssertEqual(OnboardingStep.dotSteps.count, 5)
        XCTAssertEqual(OnboardingStep.model.contentPadding, 16)
        XCTAssertEqual(OnboardingStep.cleanup.contentPadding, 24)
        XCTAssertEqual(OnboardingStep.welcome.contentPadding, 40)
    }

    func testReplayFlagIsIndependentOfCompletion() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertFalse(OnboardingReplay.isRequested(in: defaults))
        OnboardingReplay.request(in: defaults)
        XCTAssertTrue(OnboardingReplay.isRequested(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"), "the pill keeps its post-onboarding phase")
        OnboardingReplay.finish(in: defaults)
        XCTAssertFalse(OnboardingReplay.isRequested(in: defaults))
        XCTAssertNil(defaults.object(forKey: OnboardingReplay.requestedKey))
    }

    // MARK: - Cleanup choice

    func testCurrentChoiceReadsTheFormatterKeys() {
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .off, "fresh install")
        defaults.set(true, forKey: TranscriptFormatterService.enabledKey)
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .lightCleanup, "enabled with no intensity is the documented default")
        defaults.set(FormattingIntensity.polish.rawValue, forKey: TranscriptFormatterService.intensityKey)
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .polish)
        defaults.set(FormattingIntensity.formatting.rawValue, forKey: TranscriptFormatterService.intensityKey)
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .basic)
        defaults.set(FormattingIntensity.custom.rawValue, forKey: TranscriptFormatterService.intensityKey)
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .custom)
        defaults.set(false, forKey: TranscriptFormatterService.enabledKey)
        XCTAssertEqual(OnboardingCleanupChoice.current(in: defaults), .off)
    }

    func testApplyWritesTheFormatterKeys() {
        let store = CustomRulesetStore(defaults: defaults)
        defaults.set(FormattingIntensity.polish.rawValue, forKey: TranscriptFormatterService.intensityKey)

        XCTAssertFalse(OnboardingCleanupChoice.off.apply(defaults: defaults, rulesetStore: store))
        XCTAssertFalse(defaults.bool(forKey: TranscriptFormatterService.enabledKey))
        XCTAssertEqual(
            defaults.integer(forKey: TranscriptFormatterService.intensityKey), FormattingIntensity.polish.rawValue,
            "Off leaves the intensity alone")

        XCTAssertFalse(OnboardingCleanupChoice.lightCleanup.apply(defaults: defaults, rulesetStore: store))
        XCTAssertTrue(defaults.bool(forKey: TranscriptFormatterService.enabledKey))
        XCTAssertEqual(defaults.integer(forKey: TranscriptFormatterService.intensityKey), FormattingIntensity.lightCleanup.rawValue)

        XCTAssertFalse(OnboardingCleanupChoice.basic.apply(defaults: defaults, rulesetStore: store))
        XCTAssertEqual(defaults.integer(forKey: TranscriptFormatterService.intensityKey), FormattingIntensity.formatting.rawValue)
        XCTAssertTrue(store.rulesets.isEmpty, "built-in levels never create rulesets")
    }

    func testCustomCreatesExactlyOneRulesetAndAsksForTheEditor() {
        let store = CustomRulesetStore(defaults: defaults)

        XCTAssertTrue(OnboardingCleanupChoice.custom.apply(defaults: defaults, rulesetStore: store), "no instructions yet")
        XCTAssertTrue(defaults.bool(forKey: TranscriptFormatterService.enabledKey))
        XCTAssertEqual(defaults.integer(forKey: TranscriptFormatterService.intensityKey), FormattingIntensity.custom.rawValue)
        XCTAssertEqual(store.rulesets.count, 1)
        XCTAssertEqual(store.rulesets.first?.name, OnboardingCleanupChoice.defaultRulesetName)
        XCTAssertEqual(store.activeRulesetID, store.rulesets.first?.id)

        XCTAssertTrue(OnboardingCleanupChoice.custom.apply(defaults: defaults, rulesetStore: store))
        XCTAssertEqual(store.rulesets.count, 1, "replaying does not create a second ruleset")

        var ruleset = store.rulesets[0]
        ruleset.instructions = "Fix punctuation only."
        store.update(ruleset)
        XCTAssertFalse(OnboardingCleanupChoice.custom.apply(defaults: defaults, rulesetStore: store), "usable ruleset: no editor needed")
    }

    func testPreviewOptionsMapToCleanupOptions() {
        let store = CustomRulesetStore(defaults: defaults)
        XCTAssertEqual(OnboardingCleanupChoice.off.previewOption(rulesetStore: store), .off)
        XCTAssertEqual(OnboardingCleanupChoice.basic.previewOption(rulesetStore: store), .basic)
        XCTAssertEqual(OnboardingCleanupChoice.lightCleanup.previewOption(rulesetStore: store), .light)
        XCTAssertEqual(OnboardingCleanupChoice.polish.previewOption(rulesetStore: store), .polish)
        XCTAssertNil(OnboardingCleanupChoice.custom.previewOption(rulesetStore: store), "no ruleset, nothing to preview")

        var ruleset = store.addRuleset()!
        ruleset.instructions = "Rewrite as a haiku."
        store.update(ruleset)
        XCTAssertEqual(OnboardingCleanupChoice.custom.previewOption(rulesetStore: store)?.isCustom, true)
    }

    // MARK: - Preview runner

    @MainActor
    func testRunnerRunsInOrderCachesAndCancels() async {
        let runner = CleanupPreviewRunner()
        var calls: [CleanupOption] = []
        runner.preview = { text, option in
            calls.append(option)
            try? await Task.sleep(nanoseconds: 10_000_000)
            return TranscriptCleanupOutcome.withoutModel(
                rawInput: text, modelInput: text, output: text.uppercased(), requested: option, reason: nil, durationMs: 1)
        }

        runner.run(text: "hello there", options: [.basic, .light])
        XCTAssertEqual(runner.state(for: .basic, text: "hello there"), .queued)
        XCTAssertEqual(runner.state(for: .light, text: "hello there"), .queued)
        XCTAssertTrue(runner.isRunning)

        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(calls, [.basic, .light])
        XCTAssertEqual(runner.outcome(for: .light, text: "hello there")?.output, "HELLO THERE")

        runner.run(text: "hello there", options: [.light, .polish])
        XCTAssertEqual(runner.state(for: .light, text: "hello there"), .done(runner.outcome(for: .light, text: "hello there")!), "cached")
        XCTAssertEqual(runner.state(for: .polish, text: "hello there"), .queued)
        runner.cancel()
        XCTAssertEqual(runner.state(for: .polish, text: "hello there"), .idle)
        XCTAssertEqual(calls.count, 2, "cancelled before polish ran")

        runner.invalidate()
        XCTAssertEqual(runner.state(for: .light, text: "hello there"), .idle)
    }
}
