import XCTest
@testable import voxbox

@MainActor
final class WhisperServiceTests: XCTestCase {
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testDefaultInitialization() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "")
    }
    
    // Note: detailed loadModel tests require mocking the WhisperKit dependency
    // which is external. We test the state management around it.
    
    func testStateFlags() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isTranscribing)
        // Simulate transcription start
        service.isTranscribing = true
        XCTAssertTrue(service.isTranscribing)
    }

    func testNormalizedTranscriptionRemovesBlankAudioPlaceholders() {
        let normalized = WhisperService.normalizedTranscription(
            from: " [BLANK_AUDIO]  hello   <|nospeech|> [SILENCE] "
        )

        XCTAssertEqual(normalized, "hello")
    }

    func testNormalizedTranscriptionRemovesWhisperSpecialTokens() {
        let raw = """
            <|startoftranscript|><|en|><|transcribe|><|0.00|> Let's have a go at this one. \
            One thing that's interesting here is that as a streaming model, it's got lots of \
            interim text and stuff that's showing up. This is an example using Whisper.<|15.56|><|endoftext|>
            """
        let normalized = WhisperService.normalizedTranscription(from: raw)
        XCTAssertEqual(
            normalized,
            "Let's have a go at this one. One thing that's interesting here is that as a streaming model, it's got lots of interim text and stuff that's showing up. This is an example using Whisper."
        )
        XCTAssertFalse(normalized.contains("<|"))
        XCTAssertFalse(normalized.contains("|>"))
    }

    func testNormalizedTranscriptionRemovesBracketedNoiseLabels() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind blowing] (heartbeat) answer [S]"
        )

        XCTAssertEqual(normalized, "answer")
    }

    func testNormalizedTranscriptionRemovesNoiseOnlyArtifacts() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind] (Loud noise) (indistinct)"
        )

        XCTAssertEqual(normalized, "")
    }

    func testWhisperLiveHypothesisDoesNotStackCurrentOnUnconfirmed() {
        let previous = "this is a test of streaming"
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there",
            unconfirmed: previous,
            current: "this is a test",
            previousRevisable: previous
        )
        XCTAssertEqual(snap.stable, "Hello there")
        XCTAssertEqual(snap.revisable, previous)
        XCTAssertEqual(snap.fullText, "Hello there \(previous)")
    }

    func testWhisperLiveHypothesisExtendsTailWhenCurrentCatchesUp() {
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there",
            unconfirmed: "",
            current: "this is a test of streaming and more",
            previousRevisable: "this is a test of streaming"
        )
        XCTAssertEqual(snap.revisable, "this is a test of streaming and more")
    }

    func testWhisperLiveHypothesisStripsConfirmedPrefixFromCurrent() {
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there",
            unconfirmed: "",
            current: "Hello there this is new",
            previousRevisable: ""
        )
        XCTAssertEqual(snap.stable, "Hello there")
        XCTAssertEqual(snap.revisable, "this is new")
    }

    func testWhisperLiveHypothesisHoldsTailWhileWindowRestarts() {
        let previous = "this is a reasonably long hypothesis tail"
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there",
            unconfirmed: "",
            current: "th",
            previousRevisable: previous
        )
        XCTAssertEqual(snap.revisable, previous)
        XCTAssertTrue(WhisperLiveHypothesis.shouldHold(previous: previous, next: "th"))
        XCTAssertTrue(WhisperLiveHypothesis.shouldHold(previous: previous, next: "this is a"))
        XCTAssertFalse(
            WhisperLiveHypothesis.shouldHold(
                previous: previous, next: previous + " and more"))
    }

    func testWhisperLiveHypothesisUsesUnconfirmedWhenCurrentIsWaiting() {
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello",
            unconfirmed: "there friend",
            current: WhisperLiveHypothesis.waitingCopy,
            previousRevisable: "old"
        )
        XCTAssertEqual(snap.revisable, "there friend")
    }

    func testWhisperLiveHypothesisDropsTailOnceConfirmed() {
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there friend",
            unconfirmed: "",
            current: "",
            previousRevisable: "there friend"
        )
        XCTAssertEqual(snap.revisable, "")
        XCTAssertEqual(snap.fullText, "Hello there friend")
    }

    func testWhisperLiveHypothesisStartsNewWindowAfterConfirm() {
        let snap = WhisperLiveHypothesis.snapshot(
            confirmed: "Hello there friend",
            unconfirmed: "",
            current: "OK",
            previousRevisable: "there friend"
        )
        XCTAssertEqual(snap.revisable, "OK")
        XCTAssertEqual(snap.fullText, "Hello there friend OK")
    }
}
