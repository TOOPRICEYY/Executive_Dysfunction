import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class SharedInterfaceGroupTests: XCTestCase {
    func testPassageComparisonKeepsAlignmentAndSupportsMaximumBackoff() {
        let short = PassageDiff.compare(typed: "river stray flows home", passage: "river quietly flows home")
        XCTAssertEqual(short.map(\.kind), [.matched, .incorrect, .missing, .matched, .matched])
        XCTAssertFalse(PassageDiff.compare(typed: "River", passage: "river", caseSensitive: true).allSatisfy { $0.kind == .matched })
        let words = (0..<38_400).map { "word\($0)" }
        let typed = words.enumerated().filter { $0.offset != 100 }.map(\.element).joined(separator: " ")
        let tokens = PassageDiff.compare(typed: typed, passage: words.joined(separator: " "))
        XCTAssertEqual(tokens.filter { $0.kind == .matched }.count, 38_399)
        XCTAssertEqual(tokens.filter { $0.kind == .missing }.map(\.text), ["word100"])
    }
    private func group() -> CloudBlockingGroup {
        var group = CloudBlockingGroup(name: "Protected settings", modificationPolicy: .init(severity: "passageOnly", passageWordCount: 40, confirmationWindowHours: 12, editWindowHours: 3))
        group.targets = CloudBlockingTargets(domains: [.init(domain: "example.com", category: "education", source: "import")],
            websiteCategories: ["social"], macApplicationIdentifiers: ["org.example.app"],
            windowsExecutablePaths: ["C:\\Example\\Example.exe"], windowsPublisherRules: ["Publisher"], deviceLocalSelectionCount: 7)
        group.usageBudget.dailyLimitMinutes = 45
        return group
    }
    func testRenamePreservesNativeOnlyFieldsAndDomainMetadata() throws {
        let original = group()
        var dto = SharedInterfaceGroup(original); dto.name = "Renamed"
        let revised = try dto.merging(into: original)
        XCTAssertEqual(revised.targets, original.targets)
        XCTAssertEqual(revised.usageBudget, original.usageBudget)
        XCTAssertEqual(revised.modificationPolicy, original.modificationPolicy)
        XCTAssertEqual(revised.timeWindow.id, original.timeWindow.id)
        XCTAssertEqual(revised.name, "Renamed")
    }
    func testUnresolvedImportsCannotBeSilentlyReplaced() {
        var original = group(); original.targets = nil
        XCTAssertThrowsError(try SharedInterfaceGroup(original).merging(into: original))
    }
    func testNewDomainsPreserveExistingMetadata() throws {
        let original = group(); var dto = SharedInterfaceGroup(original)
        dto.domains += ["https://other.example/path", "EXAMPLE.COM"]
        let revised = try dto.merging(into: original)
        XCTAssertEqual(revised.targets?.domains.count, 2)
        XCTAssertEqual(revised.targets?.domains.first, original.targets?.domains.first)
    }
    func testInvalidDomainAndWindowRejected() {
        let original = group(); var dto = SharedInterfaceGroup(original)
        dto.domains = ["javascript:bad"]
        XCTAssertThrowsError(try dto.merging(into: original))
        dto = SharedInterfaceGroup(original)
        dto.schedule.slots = [.init(weekdays: [9], startMinutes: 2, endMinutes: 3)]
        XCTAssertThrowsError(try dto.merging(into: original))
    }
    func testInheritedPolicyIsNotAccidentallyWeakenedOrPinned() throws {
        var original = group(); original.modificationPolicy.severity = "appDefault"
        let dto = SharedInterfaceGroup(original)
        XCTAssertEqual(dto.changePolicy.kind, "inherited")
        XCTAssertEqual(try dto.merging(into: original).modificationPolicy, original.modificationPolicy)
        XCTAssertThrowsError(try dto.merging(into: nil))
    }
    func testTemporaryAccessCannotTruncateFractionalHours() {
        let original = group(); var dto = SharedInterfaceGroup(original)
        dto.temporaryPolicy.maximumMinutes = 90
        XCTAssertThrowsError(try dto.merging(into: original))
    }
}
