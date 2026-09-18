import XCTest

@testable import voxbox

final class CleanupSessionPoolTests: XCTestCase {

    private let variant = PostProcessingModel.appleSystemVariant

    // MARK: - Key

    func testTwoTakesWithTheSameInstructionsShareAKeyAndPoolEntry() async {
        let pool = CleanupSessionPool()
        let first = lightRequest(text: "remind me to pick up milk")
        let second = lightRequest(text: "email john about the budget")
        XCTAssertNotEqual(first.userPrompt, second.userPrompt)

        let firstKey = CleanupSessionPool.Key(request: first, variant: variant)
        let secondKey = CleanupSessionPool.Key(request: second, variant: variant)
        XCTAssertEqual(firstKey, secondKey, "userPrompt is not part of the key")
        XCTAssertFalse(
            firstKey.instructionFingerprint.contains("pick up milk"),
            "fingerprint is instruction stages, not this take")

        let firstSession = await pool.session(for: firstKey, makeSession: Marker.init)
        let secondSession = await pool.session(for: secondKey, makeSession: Marker.init)

        XCTAssertTrue(firstSession === secondSession)
        let count = await pool.entryCount
        let hasFirst = await pool.hasSession(for: firstKey)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(hasFirst)
    }

    func testDifferentTemperatureIsADifferentKey() {
        let cool = TranscriptFormatterService.request(
            for: "same dictation for both temperatures",
            ruleset: CustomCleanupRuleset(
                name: "Cool", instructions: "Rewrite.", temperature: 0))
        let warm = TranscriptFormatterService.request(
            for: "same dictation for both temperatures",
            ruleset: CustomCleanupRuleset(
                name: "Warm", instructions: "Rewrite.", temperature: 0.7))

        XCTAssertEqual(cool.instructionStages, warm.instructionStages)
        XCTAssertNotEqual(
            CleanupSessionPool.Key(request: cool, variant: variant),
            CleanupSessionPool.Key(request: warm, variant: variant))
    }

    func testDifferentInstructionStagesAreADifferentKey() {
        let light = lightRequest(text: "same dictation for both intensities")
        let polish = TranscriptFormatterService.request(
            for: "same dictation for both intensities",
            intensity: .polish,
            includeMarkdownFormatting: false)

        XCTAssertNotEqual(light.instructionStages, polish.instructionStages)
        XCTAssertNotEqual(
            CleanupSessionPool.Key(request: light, variant: variant),
            CleanupSessionPool.Key(request: polish, variant: variant))
    }

    func testUserPromptIsTheRespondInputAndIsNotFingerprinted() {
        let request = lightRequest(text: "unique take text that is not an instruction")
        XCTAssertEqual(CleanupSessionPool.respondInput(for: request), request.userPrompt)
        XCTAssertNotEqual(CleanupSessionPool.respondInput(for: request), request.instructions)

        let key = CleanupSessionPool.Key(request: request, variant: variant)
        XCTAssertEqual(
            key.instructionFingerprint,
            request.instructionStages.joined(separator: "\n\n"))
        XCTAssertFalse(key.instructionFingerprint.contains(request.input))
    }

    // MARK: - Invalidate

    func testInvalidateRemovesOnlyThatVariantThenALaterRequestCreatesANewEntry() async {
        let pool = CleanupSessionPool()
        let request = lightRequest(text: "one take")
        let appleKey = CleanupSessionPool.Key(request: request, variant: variant)
        let mlxKey = CleanupSessionPool.Key(request: request, variant: "mlx-qwen")

        let appleSession = await pool.session(for: appleKey, makeSession: Marker.init)
        _ = await pool.session(for: mlxKey, makeSession: Marker.init)
        let countBefore = await pool.entryCount
        XCTAssertEqual(countBefore, 2)

        await pool.invalidate(variant: variant)

        let appleGone = await pool.hasSession(for: appleKey)
        let mlxKept = await pool.hasSession(for: mlxKey)
        let countAfterInvalidate = await pool.entryCount
        XCTAssertFalse(appleGone)
        XCTAssertTrue(mlxKept)
        XCTAssertEqual(countAfterInvalidate, 1)

        let replacement = await pool.session(for: appleKey, makeSession: Marker.init)
        XCTAssertFalse(replacement === appleSession)
        let appleBack = await pool.hasSession(for: appleKey)
        let countAfterRecreate = await pool.entryCount
        XCTAssertTrue(appleBack)
        XCTAssertEqual(countAfterRecreate, 2)
    }
}

private func lightRequest(text: String) -> FormattingRequest {
    TranscriptFormatterService.request(
        for: text, intensity: .lightCleanup, includeMarkdownFormatting: false)
}

private final class Marker: @unchecked Sendable {}
