import XCTest

@testable import voxbox

final class RulesetTestPanelTests: XCTestCase {

    private func item(_ transcript: String, raw: String? = nil, minutesAgo: Double) -> HistoryItem {
        HistoryItem(
            id: UUID(), date: Date().addingTimeInterval(-minutesAgo * 60), transcript: transcript, duration: 3,
            audioFileURL: nil, modelUsed: nil, transcriptionTime: nil, rawTranscript: raw)
    }

    func testRecentCandidatesAreNewestFirstAndCapped() {
        let items = (0..<8).map { item("take \($0)", minutesAgo: Double($0)) }.shuffled()
        let recent = RulesetTestInput.recentHistoryCandidates(from: items)
        XCTAssertEqual(recent.count, RulesetTestInput.historyLimit)
        XCTAssertEqual(recent.map(\.transcript), ["take 0", "take 1", "take 2", "take 3", "take 4"])
    }

    func testCandidatesSkipEmptyTranscripts() {
        let items = [item("   ", minutesAgo: 0), item("real take", minutesAgo: 1)]
        XCTAssertEqual(RulesetTestInput.recentHistoryCandidates(from: items).map(\.transcript), ["real take"])
    }

    func testRawTranscriptIsPreferredWhenPresent() {
        let withRaw = item("So I think we should ship.", raw: "um so I think uh we should ship", minutesAgo: 0)
        XCTAssertEqual(RulesetTestInput.text(for: withRaw).text, "um so I think uh we should ship")
        XCTAssertTrue(RulesetTestInput.text(for: withRaw).isRaw)

        let cleanedOnly = item("So I think we should ship.", minutesAgo: 0)
        XCTAssertEqual(RulesetTestInput.text(for: cleanedOnly).text, "So I think we should ship.")
        XCTAssertFalse(RulesetTestInput.text(for: cleanedOnly).isRaw)

        let blankRaw = item("Cleaned", raw: "  \n ", minutesAgo: 0)
        XCTAssertFalse(RulesetTestInput.text(for: blankRaw).isRaw)
    }

    func testPreviewLineFlattensAndTruncates() {
        XCTAssertEqual(RulesetTestInput.previewLine("first line\n\nsecond   line"), "first line second line")
        let long = String(repeating: "word ", count: 30)
        let line = RulesetTestInput.previewLine(long, maxLength: 20)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThanOrEqual(line.count, 21)
        XCTAssertEqual(RulesetTestInput.previewLine("short"), "short")
    }

    func testFingerprintTracksInstructionsAndTemperatureOnly() {
        let base = CustomCleanupRuleset(name: "A", instructions: "Fix punctuation.", temperature: 0.2)
        var renamed = base
        renamed.name = "B"
        XCTAssertEqual(RulesetTestFingerprint(ruleset: base), RulesetTestFingerprint(ruleset: renamed), "a rename does not stale the result")

        var edited = base
        edited.instructions = "Fix punctuation. "
        XCTAssertEqual(RulesetTestFingerprint(ruleset: base), RulesetTestFingerprint(ruleset: edited), "trailing whitespace is ignored")
        edited.instructions = "Rewrite as a haiku."
        XCTAssertNotEqual(RulesetTestFingerprint(ruleset: base), RulesetTestFingerprint(ruleset: edited))

        var warmer = base
        warmer.temperature = 0.7
        XCTAssertNotEqual(RulesetTestFingerprint(ruleset: base), RulesetTestFingerprint(ruleset: warmer))
    }

    func testDiagnosticsLineNamesEngineTimeChangeAndGovernance() {
        let outcome = TranscriptCleanupOutcome(
            rawInput: "um so we ship", modelInput: "um so we ship", output: "So we ship.", requested: .custom(CustomCleanupRuleset(name: "R", instructions: "x")),
            landed: .custom,
            attempts: [
                CleanupAttempt(
                    intensity: .custom, engineName: "Apple Intelligence", requestedEngineName: "Apple Intelligence",
                    rawOutput: "So we ship.", tidiedOutput: "So we ship.", evaluation: nil, verdict: .notGoverned,
                    casingAnomaly: false, durationMs: 1200)
            ],
            totalDurationMs: 1300, skippedReason: nil)
        let line = RulesetTestPanel.diagnosticsLine(for: outcome, governed: false)
        XCTAssertTrue(line.hasPrefix("Ran on Apple Intelligence"))
        XCTAssertTrue(line.contains("1.3 s"))
        XCTAssertTrue(line.contains("% changed"))
        XCTAssertTrue(line.hasSuffix("No guardrail for custom rulesets"))

        let skipped = TranscriptCleanupOutcome.withoutModel(
            rawInput: "x", modelInput: "x", output: "x", requested: .light, reason: "Cleanup is off.", durationMs: 0)
        XCTAssertTrue(RulesetTestPanel.diagnosticsLine(for: skipped, governed: true).hasPrefix("Cleanup is off."))
    }
}
