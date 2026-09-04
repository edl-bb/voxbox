import XCTest

@testable import voxbox

/// Runs the built-in samples through the real Apple Intelligence model and
/// prints every attempt, so prompt changes can be judged against actual
/// output. Skipped unless `VOXBOX_APPLE_PROBE=1`:
///
///     TEST_RUNNER_VOXBOX_APPLE_PROBE=1 xcodebuild test … \
///       -only-testing:voxboxTests/AppleCleanupProbeTests
final class AppleCleanupProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOXBOX_APPLE_PROBE"] == "1", "set VOXBOX_APPLE_PROBE=1")
        try XCTSkipUnless(TranscriptFormatterService.isModelAvailable, "Apple Intelligence is not available")
    }

    /// The default guardrail refused this ordinary sentence ("pill"); the
    /// content-transformation guardrail must not.
    func testOrdinaryDictationIsNotDeclined() async {
        let text = "Let's have a little look at this pill here. Oh, yeah, it's not too bad. I'd say that's making some pretty good progress. Um Yeah, nice. Thanks."
        let outcome = await TranscriptCleanupPreview.preview(
            text: text, option: .light, includeMarkdown: false, autoEdit: false, allowStepDown: false, promptSet: .compiled)
        print("=== pill sentence · Light · landed=\(outcome.landed?.displayName ?? "raw") · error=\(outcome.error ?? "none")")
        print("OUT: \(outcome.output)")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.landed, .lightCleanup)
    }

    func testProbeEveryLevelOnTheSamples() async {
        for sample in CleanupSampleTranscripts.allCases {
            for option in [CleanupOption.basic, .light, .polish] {
                let outcome = await TranscriptCleanupPreview.preview(
                    text: sample.text, option: option, includeMarkdown: false, autoEdit: false,
                    allowStepDown: false, promptSet: .compiled)
                print("=== \(sample.title) · \(option.displayName) · landed=\(outcome.landed?.displayName ?? "raw") · \(outcome.totalDurationMs) ms")
                for attempt in outcome.attempts {
                    print("--- attempt \(attempt.intensity.displayName): \(TranscriptCleanupPipeline.describe(attempt.verdict))"
                        + (attempt.evaluation.map { String(format: " cost=%.1f kept=%.2f", $0.cost, $0.retention) } ?? ""))
                    print("RAW: \(attempt.rawOutput)")
                }
                print("OUT: \(outcome.output)")
            }
        }
    }
}
