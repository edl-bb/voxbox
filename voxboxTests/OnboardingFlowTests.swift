import XCTest

@testable import voxbox

/// The pure parts of the new onboarding pages: page order, the recording
/// mode setting, the cleanup level choice, and the sample sources.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Steps

    func testFirstRunWalksEveryPageInOrder() {
        var visited: [OnboardingStep] = []
        var step: OnboardingStep? = OnboardingStep.first(startAtPermissions: false)
        while let current = step {
            visited.append(current)
            step = current.next(startAtPermissions: false)
        }
        XCTAssertEqual(visited, [.welcome, .globeKey, .permissions, .recordingMode, .cleanup, .model])
        XCTAssertEqual(visited, OnboardingStep.allCases)
    }

    func testReturningUserOnlySeesPermissions() {
        XCTAssertEqual(OnboardingStep.first(startAtPermissions: true), .permissions)
        XCTAssertNil(OnboardingStep.permissions.next(startAtPermissions: true))
    }

    func testModelPageUsesTighterPadding() {
        XCTAssertEqual(OnboardingStep.model.contentPadding, 16)
        for step in OnboardingStep.allCases where step != .model {
            XCTAssertEqual(step.contentPadding, 40, "\(step)")
        }
    }

    // MARK: - Recording mode

    func testRecordingModeKeepsTheLegacyIntegerKey() {
        XCTAssertEqual(RecordingMode.defaultsKey, "recordingMode")
        XCTAssertEqual(RecordingMode.hold.rawValue, 0, "AppDelegate reads 0 as hold")
        XCTAssertEqual(RecordingMode.toggle.rawValue, 1, "AppDelegate reads 1 as toggle")
        XCTAssertEqual(RecordingMode.default, .hold)

        let suite = "voxbox.tests.recording-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecordingMode.current(in: defaults), .hold, "unset reads as hold, like integer(forKey:)")
        RecordingMode.set(.toggle, in: defaults)
        XCTAssertEqual(defaults.integer(forKey: RecordingMode.defaultsKey), 1)
        XCTAssertEqual(RecordingMode.current(in: defaults), .toggle)
        defaults.set(7, forKey: RecordingMode.defaultsKey)
        XCTAssertEqual(RecordingMode.current(in: defaults), .hold, "garbage falls back to the default")
    }

    func testRecordingModeCopyMatchesSettings() {
        XCTAssertEqual(RecordingMode.hold.displayName, "Hold to record")
        XCTAssertEqual(RecordingMode.toggle.displayName, "Toggle")
        XCTAssertEqual(RecordingMode.hold.summary, "Hold the hotkey down to record, release when done.")
        XCTAssertEqual(RecordingMode.toggle.summary, "Press the hotkey to start recording, press again to stop.")
        for mode in RecordingMode.allCases {
            XCTAssertFalse(mode.detail.isEmpty)
            XCTAssertFalse(mode.icon.isEmpty)
        }
    }

    // MARK: - Cleanup level choice

    func testCleanupChoiceRoundTripsThroughTheSettingsKeys() {
        let suite = "voxbox.tests.cleanup-choice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for choice in CleanupLevelChoice.allCases {
            choice.apply(to: defaults)
            let enabled = defaults.bool(forKey: TranscriptFormatterService.enabledKey)
            XCTAssertEqual(enabled, choice.isEnabled, "\(choice)")
            if let intensity = choice.intensity {
                XCTAssertEqual(defaults.integer(forKey: TranscriptFormatterService.intensityKey), intensity.rawValue)
                XCTAssertEqual(CleanupLevelChoice(enabled: true, intensity: intensity), choice)
            }
        }
    }

    func testOffKeepsThePreviousIntensityForWhenCleanupIsTurnedBackOn() {
        let suite = "voxbox.tests.cleanup-choice-off.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        CleanupLevelChoice.polish.apply(to: defaults)
        CleanupLevelChoice.off.apply(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: TranscriptFormatterService.enabledKey))
        XCTAssertEqual(
            defaults.integer(forKey: TranscriptFormatterService.intensityKey),
            FormattingIntensity.polish.rawValue)
        XCTAssertEqual(CleanupLevelChoice(enabled: false, intensity: .polish), .off)
    }

    func testCleanupChoicePreviewsAndRecommendation() {
        XCTAssertEqual(CleanupLevelChoice.recommended, .light)
        XCTAssertEqual(CleanupLevelChoice.off.previewOption, .off)
        XCTAssertEqual(CleanupLevelChoice.basic.previewOption, .basic)
        XCTAssertEqual(CleanupLevelChoice.light.previewOption, .light)
        XCTAssertEqual(CleanupLevelChoice.polish.previewOption, .polish)
        XCTAssertEqual(CleanupLevelChoice.custom.previewOption, .light, "no ruleset exists during onboarding")
        XCTAssertEqual(CleanupLevelChoice.allCases.map(\.title), ["Off", "Basic", "Light cleanup", "Polish", "Custom"])
        for choice in CleanupLevelChoice.allCases {
            XCTAssertFalse(choice.blurb.isEmpty)
        }
    }

    // MARK: - Sample sources

    private func historyItem(_ text: String, raw: String?, minutesAgo: Double) -> HistoryItem {
        HistoryItem(
            id: UUID(), date: Date().addingTimeInterval(-minutesAgo * 60), transcript: text, duration: 4,
            audioFileURL: nil, modelUsed: nil, transcriptionTime: nil, rawTranscript: raw)
    }

    func testRecentSourcesPreferRawTextAndSkipShortTakes() {
        let long = "so um I think we should ship the release on thursday and tell the customers"
        let items = [
            historyItem("Ship the release on Thursday and tell the customers.", raw: long, minutesAgo: 1),
            historyItem("Too short.", raw: nil, minutesAgo: 2),
            historyItem("Pasted text only, long enough for the model to run on it here.", raw: nil, minutesAgo: 3),
        ]
        let sources = CleanupSampleSource.recent(from: items)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].text, long, "raw engine text wins over the pasted text")
        XCTAssertEqual(sources[1].text, "Pasted text only, long enough for the model to run on it here.")
        XCTAssertFalse(sources.contains { $0.isBuiltIn })
        XCTAssertEqual(Set(sources.map(\.id)).count, 2)
    }

    func testRecentSourcesAreCapped() {
        let items = (0..<8).map {
            historyItem("word one two three four five six seven eight nine \($0)", raw: nil, minutesAgo: Double($0))
        }
        XCTAssertEqual(CleanupSampleSource.recent(from: items).count, 5)
        XCTAssertEqual(CleanupSampleSource.recent(from: items, limit: 2).count, 2)
    }

    func testBuiltInSourcesMirrorTheSampleTranscripts() {
        XCTAssertEqual(CleanupSampleSource.builtIn.count, CleanupSampleTranscripts.allCases.count)
        XCTAssertEqual(CleanupSampleSource.defaultSource, .builtIn(.onboardingDefault))
        XCTAssertEqual(CleanupSampleSource.builtIn[0].text, CleanupSampleTranscripts.allCases[0].text)
        XCTAssertTrue(CleanupSampleSource.builtIn.allSatisfy(\.isBuiltIn))
    }

    func testHistoryTitleShowsWhenAndAnExcerpt() {
        let title = CleanupSampleSource.title(
            for: Date(timeIntervalSince1970: 0), text: "one two three four five six seven eight")
        XCTAssertTrue(title.hasSuffix("· one two three four five six…"), title)
        let short = CleanupSampleSource.title(for: Date(timeIntervalSince1970: 0), text: "one two")
        XCTAssertTrue(short.hasSuffix("· one two"), short)
    }

    // MARK: - Outcome status line

    func testStatusLineDescribesEachOutcome() {
        let base = TranscriptCleanupOutcome(
            rawInput: "a", modelInput: "a", output: "A.", requested: .polish, landed: .polish,
            attempts: [
                CleanupAttempt(
                    intensity: .polish, engineName: "Apple Intelligence", requestedEngineName: "Apple Intelligence",
                    rawOutput: "A.", tidiedOutput: "A.", evaluation: nil, verdict: .accepted, casingAnomaly: false,
                    durationMs: 12)
            ],
            totalDurationMs: 340, skippedReason: nil)
        XCTAssertEqual(CleanupOutcomeSummary.statusLine(for: base), "Polish · Apple Intelligence · 340 ms")

        var stepped = base
        stepped.landed = .lightCleanup
        stepped.attempts[0].intensity = .lightCleanup
        XCTAssertEqual(
            CleanupOutcomeSummary.statusLine(for: stepped),
            "Stepped down to Light cleanup · Apple Intelligence · 340 ms")

        var raw = base
        raw.landed = nil
        raw.attempts[0].verdict = .changeRatioExceeded(ratio: 0.9, budget: 0.5)
        XCTAssertEqual(
            CleanupOutcomeSummary.statusLine(for: raw),
            "Every level changed too much, so the transcript is shown as dictated.")

        var failed = raw
        failed.attempts[0].verdict = .appleContentFilter
        XCTAssertEqual(
            CleanupOutcomeSummary.statusLine(for: failed),
            "Cleanup failed: Apple Intelligence declined this text.")

        let skipped = TranscriptCleanupOutcome.withoutModel(
            rawInput: "a", modelInput: "a", output: "a", requested: .light, reason: "Cleanup is off.", durationMs: 0)
        XCTAssertEqual(CleanupOutcomeSummary.statusLine(for: skipped), "Cleanup is off.")
    }
}
