import XCTest
@testable import ExecutiveDysfunction

final class CloudPreferencesTests: XCTestCase {
    func testNewerRuleWinsMerge() {
        let id = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let old = CloudRulePreference(id: id, modifiedAt: oldDate, name: "Old")
        var new = old
        new.modifiedAt = newDate
        new.name = "New"

        var document = CloudPreferencesDocument(rules: [new])
        document.merge(rule: old)
        XCTAssertEqual(document.rules.first?.name, "New")
    }

    func testNewerTombstoneRemovesRuleAndRejectsOlderRule() {
        let id = UUID()
        let rule = CloudRulePreference(
            id: id,
            modifiedAt: Date(timeIntervalSince1970: 100),
            name: "Deleted"
        )
        let deletion = CloudRuleTombstone(id: id, modifiedAt: Date(timeIntervalSince1970: 200))
        var document = CloudPreferencesDocument(rules: [rule])

        document.merge(tombstone: deletion)
        document.merge(rule: rule)

        XCTAssertTrue(document.rules.isEmpty)
        XCTAssertEqual(document.tombstones, [deletion])
    }

    func testBridgePreservesOpaqueIPhoneSelectionData() {
        var existing = BlockingRule()
        existing.selectionData = Data([1, 2, 3, 4])
        var cloud = CloudRuleBridge.cloudPreference(from: existing)
        cloud.name = "Changed on Mac"
        cloud.modifiedAt = Date().addingTimeInterval(10)

        let applied = CloudRuleBridge.applying(cloud, to: existing)

        XCTAssertEqual(applied.name, "Changed on Mac")
        XCTAssertEqual(applied.selectionData, Data([1, 2, 3, 4]))
    }
}
