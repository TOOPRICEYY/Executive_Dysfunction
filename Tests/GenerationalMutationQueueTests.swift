import XCTest

final class GenerationalMutationQueueTests: XCTestCase {
    private struct Item: GenerationStamped, Equatable {
        var generation: UInt64
        var label: String
    }

    func testSingleFlightLatestWins() {
        var queue = GenerationalMutationQueue<Item>()
        let enable = Item(generation: queue.nextGeneration(), label: "enable")
        XCTAssertEqual(queue.enqueue(enable), 0)
        XCTAssertEqual(queue.startNextIfIdle(), enable)
        XCTAssertTrue(queue.isBusy)

        // Two requests arrive while the enable is in flight: only the newest waits.
        let stale = Item(generation: queue.nextGeneration(), label: "stale")
        queue.enqueue(stale)
        let disable = Item(generation: queue.nextGeneration(), label: "disable")
        XCTAssertEqual(queue.enqueue(disable), stale.generation)
        XCTAssertNil(queue.startNextIfIdle(), "Nothing starts while a mutation is in flight")

        XCTAssertFalse(queue.isCurrent(enable), "The in-flight enable completion is stale")
        queue.finishActive()
        XCTAssertEqual(queue.startNextIfIdle(), disable)
        XCTAssertTrue(queue.isCurrent(disable))
        queue.finishActive()
        XCTAssertFalse(queue.isBusy)
    }
}
