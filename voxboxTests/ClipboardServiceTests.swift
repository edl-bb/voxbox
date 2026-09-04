import XCTest
import Cocoa
@testable import voxbox

final class ClipboardServiceTests: XCTestCase {
    /// These tests use the real system pasteboard. Save the user's clipboard
    /// before each test and put it back afterwards, so running the suite on
    /// a developer's Mac does not leave `https://example.com/original` behind.
    private var savedItems: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUp() {
        super.setUp()
        savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dataByType[type] = data }
            }
            return dataByType
        }
    }

    override func tearDown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedItems.map { dataByType in
            let item = NSPasteboardItem()
            for (type, data) in dataByType { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        super.tearDown()
    }

    func testCopy() {
        let text = "Copied Text Check"
        ClipboardService.shared.copy(text: text)
        
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.string(forType: .string)
        
        XCTAssertEqual(copied, text, "Clipboard content should match copied text")
    }

    func testTemporaryPasteCanRestorePreviousClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/original", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated text")

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/original")
    }

    func testRestoreDoesNotOverwriteClipboardChangedAfterPaste() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        pasteboard.clearContents()
        pasteboard.setString("User copied something else", forType: .string)

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "User copied something else")
    }
    
    // Testing paste() is difficult in unit tests as it requires active application focus and AX permissions.
    // We primarily verify the write operation here.
}
