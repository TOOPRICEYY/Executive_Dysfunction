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
    /// The shared editor now carries what only the native editors had: the
    /// allow-only mode, website categories, usage limits and the lock windows.
    func testSharedEditorDetailsMergeAndAbsentOnesStayUntouched() throws {
        let original = group()
        var dto = SharedInterfaceGroup(original)
        XCTAssertEqual(dto.mode, "block")
        XCTAssertEqual(dto.categories, ["social"])
        XCTAssertEqual(dto.budget?.dailyMinutes, 45)
        XCTAssertEqual(dto.changePolicy.editWindowHours, 3)
        dto.mode = "allowOnly"; dto.categories = ["news", "video"]
        dto.budget = .init(dailyMinutes: nil, weeklyMinutes: 300)
        dto.changePolicy.editWindowHours = 1; dto.changePolicy.confirmationWindowHours = 6
        let revised = try dto.merging(into: original)
        XCTAssertEqual(revised.enforcementMode, "fortressAllowList")
        XCTAssertEqual(revised.targets?.websiteCategories, ["news", "video"])
        XCTAssertEqual(revised.usageBudget, CloudUsageBudget(dailyLimitMinutes: nil, weeklyLimitMinutes: 300))
        XCTAssertEqual(revised.modificationPolicy.editWindowHours, 1)
        XCTAssertEqual(revised.modificationPolicy.confirmationWindowHours, 6)
        // An older screen that sends none of them changes none of them.
        dto = SharedInterfaceGroup(original)
        dto.mode = nil; dto.categories = nil; dto.budget = nil
        dto.changePolicy.editWindowHours = nil; dto.changePolicy.confirmationWindowHours = nil
        let untouched = try dto.merging(into: original)
        XCTAssertEqual(untouched.targets, original.targets)
        XCTAssertEqual(untouched.usageBudget, original.usageBudget)
        XCTAssertEqual(untouched.modificationPolicy, original.modificationPolicy)
        XCTAssertEqual(untouched.enforcementMode, original.enforcementMode)
        dto.categories = ["not-a-category"]
        XCTAssertThrowsError(try dto.merging(into: original))
        dto = SharedInterfaceGroup(original); dto.budget = .init(dailyMinutes: 0, weeklyMinutes: nil)
        XCTAssertThrowsError(try dto.merging(into: original))
    }
    /// A website is enforced only while its category is on. One typed into the
    /// shared editor used to be filed under "other" without turning it on.
    func testAddedWebsiteTurnsItsCategoryOnAndClassificationApplies() throws {
        let original = group()
        XCTAssertFalse(original.targets?.websiteCategories.contains("other") ?? true)
        var dto = SharedInterfaceGroup(original)
        dto.domains += ["new.example", "chat.example"]
        dto.domainCategories = [.init(domain: "chat.example", category: "aiTools", source: "heuristic")]
        let revised = try dto.merging(into: original)
        XCTAssertEqual(revised.targets?.websiteCategories, ["social", "other", "aiTools"])
        XCTAssertEqual(revised.targets?.domains.first { $0.domain == "chat.example" }?.category, "aiTools")
        XCTAssertEqual(revised.targets?.domains.first { $0.domain == "example.com" }, original.targets?.domains.first)
        dto.domainCategories = [.init(domain: "chat.example", category: "casino", source: "heuristic")]
        XCTAssertThrowsError(try dto.merging(into: original))
        dto.domainCategories = nil
        dto.otherTargets = .init(windowsPaths: ["C:\\Games\\Game.exe"], windowsPublishers: [])
        let windows = try dto.merging(into: original)
        XCTAssertEqual(windows.targets?.windowsExecutablePaths, ["C:\\Games\\Game.exe"])
        XCTAssertEqual(windows.targets?.windowsPublisherRules, [])
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
    /// The maximum is configured in minutes now, so a value that is not a whole
    /// number of hours is legitimate. Only a value outside the permitted range
    /// is refused.
    func testTemporaryAccessAcceptsMinutesAndRefusesOutOfRange() throws {
        let original = group()
        var dto = SharedInterfaceGroup(original)

        dto.temporaryPolicy.maximumMinutes = 90
        XCTAssertEqual(
            try dto.merging(into: original).modificationPolicy.effectiveMaximumTemporaryAccessMinutes,
            90
        )

        dto.temporaryPolicy.maximumMinutes = 1
        XCTAssertEqual(
            try dto.merging(into: original).modificationPolicy.effectiveMaximumTemporaryAccessMinutes,
            1
        )

        dto.temporaryPolicy.maximumMinutes = 0
        XCTAssertThrowsError(try dto.merging(into: original))
        dto.temporaryPolicy.maximumMinutes = 481
        XCTAssertThrowsError(try dto.merging(into: original))
    }
    /// Regression: the shared screen sends dates in whole seconds, so a
    /// running retreat's `Date()`-precise end came back a fraction earlier and
    /// a plain rename was refused as shortening it.
    func testWholeSecondEchoOfAStoredRetreatDateIsTheStoredDate() {
        var retreat = CloudRetreat()
        retreat.state = .active
        retreat.plannedStart = Date(timeIntervalSince1970: 1_800_000_000.25)
        retreat.plannedEnd = Date(timeIntervalSince1970: 1_800_086_400.875)
        let wire = ISO8601DateFormatter()
        let sentStart = wire.date(from: wire.string(from: retreat.plannedStart))!
        let sentEnd = wire.date(from: wire.string(from: retreat.plannedEnd))!
        XCTAssertTrue(CloudRetreatEarlyEndGate.weakensPlannedInterval(retreat, plannedStart: sentStart, plannedEnd: sentEnd),
                      "Without snapping, the echoed end reads as shortening")

        let start = SharedInterfaceInstant.keepingStored(sentStart, stored: retreat.plannedStart)
        let end = SharedInterfaceInstant.keepingStored(sentEnd, stored: retreat.plannedEnd)
        XCTAssertEqual(start, retreat.plannedStart)
        XCTAssertEqual(end, retreat.plannedEnd)
        XCTAssertFalse(CloudRetreatEarlyEndGate.weakensPlannedInterval(retreat, plannedStart: start, plannedEnd: end))

        // A real change of a second or more is passed through untouched, so
        // shortening still reaches the change policy.
        let earlier = retreat.plannedEnd.addingTimeInterval(-60)
        XCTAssertEqual(SharedInterfaceInstant.keepingStored(earlier, stored: retreat.plannedEnd), earlier)
        XCTAssertTrue(CloudRetreatEarlyEndGate.weakensPlannedInterval(retreat, plannedStart: start, plannedEnd: earlier))
        // A new retreat has nothing stored to keep.
        XCTAssertEqual(SharedInterfaceInstant.keepingStored(sentEnd, stored: nil), sentEnd)
    }
}
