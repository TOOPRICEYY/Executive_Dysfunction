import XCTest

final class RemoteWeakeningHoldTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let id = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    func testRemovedDomainIsHeldForTheRuleDelay() {
        let old = rule(domains: ["a.com", "b.com"], severity: "delayed", delayDays: 3)
        let new = rule(domains: ["a.com"], severity: "delayed", delayDays: 3)
        let first = RemoteWeakeningHold.apply(previous: [old], proposed: [new], exempt: [], holds: [:], now: now)
        XCTAssertEqual(first.rules, [old])
        XCTAssertEqual(first.holds, [id: now])
        XCTAssertEqual(first.held.first?.appliesAt, now.addingTimeInterval(3 * 86_400))

        let stillWaiting = RemoteWeakeningHold.apply(previous: first.rules, proposed: [new], exempt: [],
                                                     holds: first.holds, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(stillWaiting.rules, [old])

        let released = RemoteWeakeningHold.apply(previous: stillWaiting.rules, proposed: [new], exempt: [],
                                                 holds: stillWaiting.holds, now: now.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(released.rules, [new])
        XCTAssertTrue(released.holds.isEmpty)
    }

    func testDeletedLockedRuleIsKeptDuringHold() {
        let old = rule(domains: ["a.com"], severity: "repeatedConfirmations", delayDays: 2)
        let result = RemoteWeakeningHold.apply(previous: [old], proposed: [], exempt: [], holds: [:], now: now)
        XCTAssertEqual(result.rules, [old])
    }

    func testStricterPassageOnlyAndExemptChangesApplyImmediately() {
        let old = rule(domains: ["a.com"], severity: "delayed", delayDays: 3)
        let stricter = rule(domains: ["a.com", "b.com"], severity: "delayed", delayDays: 3)
        XCTAssertEqual(RemoteWeakeningHold.apply(previous: [old], proposed: [stricter], exempt: [], holds: [:], now: now).rules, [stricter])

        let passageOnly = rule(domains: ["a.com"], severity: "passageOnly", delayDays: 3)
        XCTAssertEqual(RemoteWeakeningHold.apply(previous: [passageOnly], proposed: [], exempt: [], holds: [:], now: now).rules, [])

        XCTAssertEqual(RemoteWeakeningHold.apply(previous: [old], proposed: [], exempt: [id], holds: [:], now: now).rules, [])
    }

    private func rule(domains: Set<String>, severity: String, delayDays: Int) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: id, name: "Social", isEnabled: true, enforcementMode: .blockList, windows: [],
            domains: domains, macApplicationIdentifiers: [], windowsExecutablePaths: [], windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(severity: severity, unlockDelayDays: delayDays, passageWordCount: 40,
                confirmationWindowHours: 24, editWindowHours: 24, allowsTimeExtensions: false,
                maximumTimeExtensionHours: 1)
        )
    }
}

final class RetreatIntervalTests: XCTestCase {
    func testPlannedIntervalBoundsEnforcementWithoutTheApp() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let end = start.addingTimeInterval(86_400)
        var rule = DesktopEnforcementRule(
            id: UUID(), name: "Retreat", isEnabled: true, enforcementMode: .blockList,
            windows: [.init(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_440)],
            domains: ["example.com"], macApplicationIdentifiers: [], windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(severity: "delayed", unlockDelayDays: 1, passageWordCount: 40,
                confirmationWindowHours: 24, editWindowHours: 24, allowsTimeExtensions: false,
                maximumTimeExtensionHours: 1))
        rule.activeFrom = start
        rule.activeUntil = end
        let policy = DesktopEnforcementPolicy(revision: 1, issuedAt: start, rules: [rule],
                                              weakeningAuthorizationExpiresAt: nil)
        XCTAssertTrue(policy.activeRules(at: start.addingTimeInterval(-60)).isEmpty)
        XCTAssertEqual(policy.activeRules(at: start.addingTimeInterval(60)).count, 1)
        XCTAssertTrue(policy.activeRules(at: end).isEmpty)

        var shortened = rule
        shortened.activeUntil = end.addingTimeInterval(-3_600)
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.isSameOrStricter(old: rule, new: shortened))
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.isSameOrStricter(old: rule, new: rule))
    }
}
