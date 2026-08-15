import XCTest

@testable import voxbox

final class RetentionServiceTests: XCTestCase {

    var history: HistoryService!

    override func setUp() {
        super.setUp()
        history = HistoryService.shared
        history.resetAllDataForTesting()
    }

    override func tearDown() {
        history.resetAllDataForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func makeItem(ageDays: Double, audioFileURL: URL? = nil) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            date: Date().addingTimeInterval(-ageDays * 24 * 60 * 60),
            transcript: "Transcript aged \(ageDays) days",
            duration: 5,
            audioFileURL: audioFileURL,
            modelUsed: nil,
            transcriptionTime: nil
        )
    }

    // MARK: - Cutoff computation

    func testCutoffIsNilForKeepForever() {
        XCTAssertNil(RetentionService.cutoff(for: RetentionService.keepForever))
    }

    func testCutoffSubtractsRetention() {
        let now = Date()
        let cutoff = RetentionService.cutoff(for: 3600, now: now)
        XCTAssertEqual(cutoff, now.addingTimeInterval(-3600))
    }

    func testDefaultsAreOneDayAudioThirtyDaysTranscript() {
        XCTAssertEqual(RetentionService.defaultAudioRetention, 24 * 60 * 60)
        XCTAssertEqual(RetentionService.defaultTranscriptRetention, 30 * 24 * 60 * 60)
    }

    // MARK: - Audio expiry (transcript kept)

    func testExpiredAudioIsDeletedButTranscriptKept() throws {
        let oldAudio = try makeAudioFile()
        let freshAudio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: freshAudio) }

        history.items = [
            makeItem(ageDays: 0, audioFileURL: freshAudio),
            makeItem(ageDays: 2, audioFileURL: oldAudio),
        ]

        history.applyRetention(
            audioCutoff: Date().addingTimeInterval(-24 * 60 * 60),
            transcriptCutoff: nil)

        XCTAssertEqual(history.items.count, 2, "Transcripts must survive audio expiry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshAudio.path))
        XCTAssertNil(history.items[1].audioFileURL, "Expired item should drop its audio reference")
        XCTAssertNotNil(history.items[0].audioFileURL)
    }

    // MARK: - Transcript expiry

    func testExpiredTranscriptsAreRemovedEntirely() throws {
        let oldAudio = try makeAudioFile()
        history.items = [
            makeItem(ageDays: 1),
            makeItem(ageDays: 40, audioFileURL: oldAudio),
        ]

        history.applyRetention(
            audioCutoff: nil,
            transcriptCutoff: Date().addingTimeInterval(-30 * 24 * 60 * 60))

        XCTAssertEqual(history.items.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldAudio.path),
            "Removing an expired transcript must also remove its audio file")
    }

    func testKeepForeverRemovesNothing() throws {
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        history.items = [makeItem(ageDays: 400, audioFileURL: audio)]

        history.applyRetention(audioCutoff: nil, transcriptCutoff: nil)

        XCTAssertEqual(history.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testStatsSurviveRetention() {
        history.addItem(transcript: "Some words to count", duration: 5)
        let statsCount = history.transcriptionCount()
        let wordCount = history.totalWordCount()

        // Expire everything.
        history.applyRetention(audioCutoff: nil, transcriptCutoff: Date().addingTimeInterval(60))

        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual(history.transcriptionCount(), statsCount)
        XCTAssertEqual(history.totalWordCount(), wordCount)
    }
}
