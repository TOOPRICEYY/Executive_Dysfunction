import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class TamperJournalTests: XCTestCase {
    func testMergeIsOrderedUniqueAndBounded() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let a = TamperEvent(id: UUID(), kind: TamperEventKind.emergencyDisable.rawValue, detail: "", at: base, origin: "mac-app")
        let b = TamperEvent(id: UUID(), kind: "someFutureKind", detail: "", at: base.addingTimeInterval(-10), origin: "mac-filter")
        let merged = TamperJournal.merged([a], [b, a])
        XCTAssertEqual(merged, [b, a])
        XCTAssertEqual(b.title, "someFutureKind", "Unknown kinds from newer builds stay readable")

        let many = (0..<(TamperJournal.maximumEvents + 20)).map {
            TamperEvent(id: UUID(), kind: "x", detail: "", at: base.addingTimeInterval(Double($0)), origin: "t")
        }
        let bounded = TamperJournal.merged([], many)
        XCTAssertEqual(bounded.count, TamperJournal.maximumEvents)
        XCTAssertEqual(bounded.last, many.last)
    }

    func testInstalledJournalPersistsToItsLedger() {
        let ledger = InMemoryKeyValueLedger()
        let journal = TamperJournal()
        journal.install(storage: ledger, origin: "mac-app")
        journal.record(.clockTamperDetected, detail: "offset_seconds=3600")

        let reloaded = TamperJournal()
        reloaded.install(storage: ledger, origin: "mac-app")
        XCTAssertEqual(reloaded.events().map(\.kind), [TamperEventKind.clockTamperDetected.rawValue])
        XCTAssertEqual(reloaded.events().first?.origin, "mac-app")
    }
}
