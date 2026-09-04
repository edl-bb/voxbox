import XCTest

@testable import voxbox

final class ClipboardRestorePolicyTests: XCTestCase {
    private let pasted = "Hi Jack, just following up on the thing we talked about yesterday. Can you send the deck by Thursday?"

    func testProbeIsTheTailOfThePastedText() {
        XCTAssertEqual(ClipboardRestorePolicy.probe(for: "short"), "short")
        let probe = ClipboardRestorePolicy.probe(for: pasted + "  \n")
        XCTAssertEqual(probe.count, ClipboardRestorePolicy.probeLength)
        XCTAssertTrue(pasted.hasSuffix(probe))
    }

    func testRestoresAsSoonAsTheFieldShowsThePaste() {
        XCTAssertEqual(
            ClipboardRestorePolicy.decide(fieldValue: "Earlier text. " + pasted, pasted: pasted, attempt: 0),
            .restoreNow)
    }

    func testKeepsWaitingWhileTheFieldIsEmptyOrStale() {
        XCTAssertEqual(ClipboardRestorePolicy.decide(fieldValue: "", pasted: pasted, attempt: 0), .checkAgain)
        XCTAssertEqual(ClipboardRestorePolicy.decide(fieldValue: nil, pasted: pasted, attempt: 3), .checkAgain)
        XCTAssertEqual(
            ClipboardRestorePolicy.decide(fieldValue: "the typed raw text still here", pasted: pasted, attempt: 5),
            .checkAgain)
    }

    func testGivesUpAfterTheTimeoutAndRestoresAnyway() {
        XCTAssertEqual(
            ClipboardRestorePolicy.decide(fieldValue: nil, pasted: pasted, attempt: ClipboardRestorePolicy.maxAttempts - 1),
            .restoreUnverified)
        XCTAssertGreaterThanOrEqual(
            Double(ClipboardRestorePolicy.maxAttempts) * ClipboardRestorePolicy.pollInterval, 2.5,
            "an Electron composer digesting a long backspace burst needs seconds, not 350 ms")
    }
}
