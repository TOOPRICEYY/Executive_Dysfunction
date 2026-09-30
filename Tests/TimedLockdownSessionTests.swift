import DeviceActivity
import XCTest
@testable import Holdfast

final class TimedLockdownSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSharedMacExitPolicyRetainsDelayAndCheckpointsOnIOS() throws {
        let session = TimedLockdownSession(rules: [BlockingRule()], startedAt: now, endsAt: now.addingTimeInterval(604_800),
            earlyExitPassage: "saved passage", sharedExitPolicy: CloudLockdownExitPolicy(
                severity: "repeatedConfirmations", unlockDelayDays: 3, passageWordCount: 120))
        let decoded = try JSONDecoder().decode(TimedLockdownSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.exitConfiguration.unlockDelayDays, 3)
        XCTAssertTrue(decoded.exitConfiguration.repeatConfirmations)
        guard case .waiting = Lockdown.phase(of: UnlockProcess(startedAt: now), configuration: decoded.exitConfiguration, at: now) else {
            return XCTFail("Import must not allow immediate passage-only exit")
        }
    }

    func testLegacySessionStillUsesPassageOnlyExit() throws {
        let session = TimedLockdownSession(rules: [], startedAt: now, endsAt: now.addingTimeInterval(3600), earlyExitPassage: "a")
        XCTAssertEqual(session.exitConfiguration.passageWordCount, 80)
        guard case .unlocked = Lockdown.phase(of: UnlockProcess(startedAt: now), configuration: session.exitConfiguration, at: now) else {
            return XCTFail("Legacy exit should not acquire a new waiting period")
        }
    }

    func testDisabledUnscheduledRuleSnapshotSurvivesRoundTrip() throws {
        var rule = BlockingRule()
        rule.isEnabled = false
        rule.windows = []
        rule.classifiedDomains = [ClassifiedDomain(domain: "x.com", category: .social, source: .user)]
        let session = TimedLockdownSession(rules: [rule], startedAt: now, endsAt: now.addingTimeInterval(3_600), earlyExitPassage: "passage")
        let decoded = try JSONDecoder().decode(TimedLockdownSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(TimedLockdownSession.expirations([decoded], at: now)[rule.id], session.endsAt)
        XCTAssertTrue(decoded.isActive(at: now))
        XCTAssertFalse(decoded.isActive(at: session.endsAt))
    }

    func testOverlappingSessionsKeepLatestEndAndIndependentShieldStores() {
        let rule = BlockingRule()
        let first = TimedLockdownSession(rules: [rule], startedAt: now, endsAt: now.addingTimeInterval(3_600), earlyExitPassage: "a")
        let second = TimedLockdownSession(rules: [rule], startedAt: now, endsAt: now.addingTimeInterval(7_200), earlyExitPassage: "b")
        XCTAssertNotEqual(first.storeName(for: rule.id), second.storeName(for: rule.id))
        XCTAssertEqual(TimedLockdownSession.expirations([first, second], at: first.endsAt)[rule.id], second.endsAt)
        XCTAssertTrue(TimedLockdownSession.expirations([first, second], at: second.endsAt).isEmpty)
    }

    func testMonitorRoundTripHasSessionIdentityNotRuleIdentity() {
        let descriptor = MonitorDescriptor.lockdown(sessionID: UUID())
        XCTAssertEqual(MonitorDescriptor.parse(descriptor.activityName), descriptor)
        XCTAssertNil(descriptor.ruleID)
        XCTAssertNil(MonitorDescriptor.parse(DeviceActivityName("ed.l.invalid")))
    }

    func testCoarseMonitorEnclosesExactDeadlineWithoutChangingIt() {
        let start = now.addingTimeInterval(127)
        let end = start.addingTimeInterval(3_600)
        let session = TimedLockdownSession(rules: [], startedAt: start, endsAt: end, earlyExitPassage: "a")
        XCTAssertLessThanOrEqual(session.monitoringInterval.start, start)
        XCTAssertGreaterThanOrEqual(session.monitoringInterval.end, end)
        XCTAssertLessThan(session.monitoringInterval.end.timeIntervalSince(end), 900)
        XCTAssertFalse(session.isActive(at: end))
        XCTAssertTrue(session.isActive(at: end.addingTimeInterval(-1)))
    }

    func testStoreBudgetIncludesSnapshotsAndCurrentTargetsButNotExpiredSessions() {
        let rules = (0..<10).map { _ in BlockingRule() }
        let session = TimedLockdownSession(rules: rules, startedAt: now, endsAt: now.addingTimeInterval(3_600), earlyExitPassage: "a")
        XCTAssertEqual(RuleScheduler.estimatedStoreCount(rules: rules, sessions: [session], at: now), 31)
        XCTAssertEqual(RuleScheduler.estimatedStoreCount(rules: rules, sessions: [session], at: session.endsAt), 11)
    }
}
