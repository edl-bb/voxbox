import XCTest
@testable import voxbox

final class HistorySwipeActionsTests: XCTestCase {

    var service: HistoryService!

    override func setUp() {
        super.setUp()
        service = HistoryService.shared
        service.resetAllDataForTesting()
    }

    override func tearDown() {
        service.resetAllDataForTesting()
        super.tearDown()
    }

    func testRequestDeleteOnlyParksTheItemForConfirmation() throws {
        service.addItem(transcript: "Keep this take", duration: 1.0)
        let item = try XCTUnwrap(service.items.first)
        var confirmation = HistoryDeleteConfirmation()

        confirmation.request(item)

        XCTAssertEqual(confirmation.pendingItem?.id, item.id)
        XCTAssertEqual(service.items.count, 1, "requestDelete must not call deleteItem")
        XCTAssertEqual(service.items.first?.transcript, "Keep this take")
    }

    func testDismissingPendingDeleteDoesNotRemoveTheTake() throws {
        service.addItem(transcript: "Still here after cancel", duration: 1.0)
        let item = try XCTUnwrap(service.items.first)
        var confirmation = HistoryDeleteConfirmation()

        confirmation.request(item)
        confirmation.dismiss()

        XCTAssertNil(confirmation.pendingItem)
        XCTAssertEqual(service.items.count, 1)
    }

    func testCopyUsesTheShownTranscriptNotTheRaw() {
        let item = HistoryItem(
            id: UUID(),
            date: Date(),
            transcript: "Cleaned output",
            duration: 1.0,
            audioFileURL: nil,
            modelUsed: nil,
            transcriptionTime: nil,
            rawTranscript: "um cleaned output"
        )

        XCTAssertEqual(HistoryCardActions.copyText(for: item), "Cleaned output")
    }
}
