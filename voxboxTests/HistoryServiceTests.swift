import XCTest
@testable import voxbox

final class HistoryServiceTests: XCTestCase {
    
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
    
    func testAddItem() {
        XCTAssertTrue(service.items.isEmpty)
        
        let transcript = "Test Transcript"
        let duration: TimeInterval = 10.0
        
        service.addItem(transcript: transcript, duration: duration)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, transcript)
        XCTAssertEqual(service.items.first?.duration, duration)
    }
    
    func testPersistence() {
        let transcript = "Persistent Item"
        service.addItem(transcript: transcript, duration: 5.0)
        
        // Simulate app restart by re-initializing (or checking UserDefaults directly)
        // Since 'init' loads from UserDefaults, creating a new instance isn't easy with singleton,
        // but we can check if UserDefaults has the data.
        
        guard let data = UserDefaults.standard.data(forKey: "history_items"),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            XCTFail("Failed to load from UserDefaults")
            return
        }
        
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.transcript, transcript)
    }
    
    func testDeleteItem() {
        service.addItem(transcript: "Item 1", duration: 1.0)
        service.addItem(transcript: "Item 2", duration: 2.0)
        
        XCTAssertEqual(service.items.count, 2)
        
        let itemToDelete = service.items.last! // "Item 1" (since newest is first)
        service.deleteItem(id: itemToDelete.id)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, "Item 2")
    }

    func testDeleteItemRemovesAudioFileWhenPresent() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data("audio".utf8).write(to: audioURL)

        service.addItem(
            transcript: "Item with audio",
            duration: 1.0,
            audioFileURL: audioURL
        )

        let itemID = try XCTUnwrap(service.items.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        service.deleteItem(id: itemID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(service.items.isEmpty)
    }

    func testClearAllPreservesStatsHistory() {
        service.addItem(transcript: "One short note", duration: 10.0)
        service.addItem(transcript: "Another slightly longer note", duration: 20.0)

        let countBeforeClear = service.transcriptionCount()
        let wordsBeforeClear = service.totalWordCount()
        let durationBeforeClear = service.totalDuration()

        service.clearAll()

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.transcriptionCount(), countBeforeClear)
        XCTAssertEqual(service.totalWordCount(), wordsBeforeClear)
        XCTAssertEqual(service.totalDuration(), durationBeforeClear)
    }

    func testRawTranscriptIsStoredAlongsideTheCleanedText() throws {
        service.addItem(
            transcript: "So I think we should ship.",
            rawTranscript: "um so I think uh we should ship",
            duration: 3.0)

        let item = try XCTUnwrap(service.items.first)
        XCTAssertEqual(item.transcript, "So I think we should ship.")
        XCTAssertEqual(item.rawTranscript, "um so I think uh we should ship")

        // Round-trip in memory: the shared UserDefaults store is also written
        // by other test processes when the suite runs in parallel.
        let decoded = try JSONDecoder().decode(HistoryItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.rawTranscript, "um so I think uh we should ship")
    }

    func testBlankRawTranscriptIsStoredAsNil() throws {
        service.addItem(transcript: "Hello", rawTranscript: "   ", duration: 1.0)
        XCTAssertNil(try XCTUnwrap(service.items.first).rawTranscript)
    }

    func testItemsRecordedBefore1_3DecodeWithoutARawTranscript() throws {
        let legacy = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"transcript":"Old item","duration":1.5}]
            """
        let decoded = try JSONDecoder().decode([HistoryItem].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].transcript, "Old item")
        XCTAssertNil(decoded[0].rawTranscript)
        XCTAssertNil(decoded[0].modelUsed)
    }

    func testStatsPersistenceUsesSeparateStore() {
        service.addItem(transcript: "Persistent stats entry", duration: 5.0)

        guard let data = UserDefaults.standard.data(forKey: "history_stats_entries"),
              let decoded = try? JSONDecoder().decode([HistoryStatsEntry].self, from: data) else {
            XCTFail("Failed to load stats from UserDefaults")
            return
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.wordCount, 3)
        XCTAssertEqual(decoded.first?.duration, 5.0)
    }
}
