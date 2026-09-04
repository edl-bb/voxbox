import XCTest

@testable import voxbox

@MainActor
final class LiveWritePipelineTests: XCTestCase {
    private func sequenced(_ seq: Int, take: Int = 1) -> SequencedSnapshot {
        SequencedSnapshot(take: take, seq: seq, snapshot: LiveTranscriptSnapshot(stable: "s\(seq)", revisable: ""))
    }

    func testReentrantEnqueueDuringWriteNeverNestsAndStillLands() async throws {
        var depth = 0
        var maxDepth = 0
        var written: [Int] = []
        var pipeline: LiveWritePipeline!
        pipeline = LiveWritePipeline(gap: .milliseconds(5)) { snapshot in
            depth += 1
            maxDepth = max(maxDepth, depth)
            written.append(snapshot.seq)
            if snapshot.seq == 1 {
                // The old code let the next snapshot run inside this write.
                pipeline.enqueue(self.sequenced(2))
            }
            depth -= 1
        }

        pipeline.enqueue(sequenced(1))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(maxDepth, 1)
        XCTAssertEqual(written, [1, 2])
        XCTAssertEqual(pipeline.reentrantEnqueues, 1)
    }

    func testBurstOfSnapshotsCoalescesToLatest() async throws {
        var written: [Int] = []
        let pipeline = LiveWritePipeline(gap: .milliseconds(30)) { written.append($0.seq) }

        pipeline.enqueue(sequenced(1))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(written, [1], "the first snapshot is written as soon as the drain runs")

        // A burst inside the gap collapses to its newest member.
        for seq in 2...50 { pipeline.enqueue(sequenced(seq)) }
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(written, [1, 50])
        XCTAssertEqual(pipeline.coalescedCount, 48)
        XCTAssertEqual(pipeline.writeCount, 2)
    }

    func testOlderSnapshotsAreDropped() async throws {
        var written: [Int] = []
        let pipeline = LiveWritePipeline(gap: .milliseconds(5)) { written.append($0.seq) }
        pipeline.enqueue(sequenced(3))
        try await Task.sleep(for: .milliseconds(30))
        pipeline.enqueue(sequenced(2))
        pipeline.enqueue(sequenced(4))
        pipeline.enqueue(sequenced(1))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(written, [3, 4])
        XCTAssertEqual(pipeline.droppedCount, 2)
    }

    func testQuiesceDropsPendingAndRejectsLaterSnapshots() async throws {
        var written: [Int] = []
        let pipeline = LiveWritePipeline(gap: .milliseconds(50)) { written.append($0.seq) }
        pipeline.enqueue(sequenced(1))
        try await Task.sleep(for: .milliseconds(10))
        pipeline.enqueue(sequenced(2))  // pending behind the gap
        await pipeline.quiesce()
        pipeline.enqueue(sequenced(3))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(written, [1])
        XCTAssertEqual(pipeline.droppedCount, 1)

        pipeline.resume()
        pipeline.enqueue(sequenced(4))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(written, [1, 4])
    }
}
