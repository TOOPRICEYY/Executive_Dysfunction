import XCTest
@testable import ExecutiveDysfunctionMac

final class DesktopLockdownSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let ruleID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!

    private func lockdown(passageWords: Int = 8) -> DesktopLockdownPolicy {
        DesktopLockdownPolicy(
            severity: "delayed",
            unlockDelayDays: 0,
            passageWordCount: passageWords,
            confirmationWindowHours: 24,
            editWindowHours: 1,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 0
        )
    }

    /// A rule that is switched off and whose window is not running: exactly the
    /// state a session has to be able to override.
    private func dormantRule() -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: ruleID,
            name: "Socials",
            isEnabled: false,
            enforcementMode: .blockList,
            windows: [],
            domains: ["x.com"],
            macApplicationIdentifiers: [],
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: lockdown()
        )
    }

    private func policy(
        sessions: [DesktopLockdownSession]?,
        revision: UInt64 = 2,
        rules: [DesktopEnforcementRule]? = nil,
        authorizedUntil: Date? = nil
    ) -> DesktopEnforcementPolicy {
        DesktopEnforcementPolicy(
            revision: revision,
            issuedAt: now,
            rules: rules ?? [dormantRule()],
            weakeningAuthorizationExpiresAt: authorizedUntil,
            lockdownSessions: sessions
        )
    }

    private func session(
        hours: Double = 72,
        ruleIDs: Set<UUID>? = nil,
        id: UUID = UUID()
    ) -> DesktopLockdownSession {
        DesktopLockdownSessionGate.makeSession(
            ruleIDs: ruleIDs ?? [ruleID],
            duration: hours * 3_600,
            lockdown: lockdown(),
            at: now,
            id: id
        )
    }

    // MARK: - Enforcement

    func testSessionForcesADisabledUnscheduledRuleOn() {
        let policy = policy(sessions: [session()])
        XCTAssertTrue(policy.blocksDomain("x.com", at: now.addingTimeInterval(3_600)))
        XCTAssertTrue(policy.hasActiveWebRestrictions(at: now.addingTimeInterval(3_600)))
    }

    func testWithoutASessionTheSameRuleBlocksNothing() {
        XCTAssertFalse(policy(sessions: nil).blocksDomain("x.com", at: now))
    }

    func testEnforcementStopsExactlyAtTheEnd() {
        let policy = policy(sessions: [session(hours: 72)])
        let end = now.addingTimeInterval(72 * 3_600)
        XCTAssertTrue(policy.blocksDomain("x.com", at: end.addingTimeInterval(-1)))
        XCTAssertFalse(policy.blocksDomain("x.com", at: end))
    }

    func testMultiDayDurationsAreSupported() {
        let week = session(hours: 24 * 7)
        XCTAssertEqual(week.endsAt.timeIntervalSince(week.startedAt), 7 * 86_400, accuracy: 1)
        XCTAssertTrue(week.isActive(at: now.addingTimeInterval(6 * 86_400)))
    }

    // MARK: - Carry-forward (the teeth)

    func testRepublishingWithoutTheSessionDoesNotEndIt() {
        let running = policy(sessions: [session()], revision: 2)
        let dropped = policy(sessions: nil, revision: 3)

        let merged = dropped.carryingForwardSessions(from: running, at: now.addingTimeInterval(3_600))
        XCTAssertEqual(merged.activeSessions(at: now.addingTimeInterval(3_600)).count, 1)
        XCTAssertTrue(merged.blocksDomain("x.com", at: now.addingTimeInterval(3_600)))
    }

    func testDeletingTheRuleDoesNotHollowOutARunningSession() {
        let running = policy(sessions: [session()], revision: 2)
        let gutted = policy(sessions: nil, revision: 3, rules: [])

        let merged = gutted.carryingForwardSessions(from: running, at: now.addingTimeInterval(60))
        XCTAssertTrue(
            merged.blocksDomain("x.com", at: now.addingTimeInterval(60)),
            "A session pointing at a deleted rule would otherwise hold nothing"
        )
    }

    func testPullingTheEndForwardIsRefusedWithoutAuthorization() {
        let original = session(hours: 72)
        var shortened = original
        shortened.endsAt = now.addingTimeInterval(60)

        let merged = policy(sessions: [shortened], revision: 3)
            .carryingForwardSessions(from: policy(sessions: [original]), at: now.addingTimeInterval(120))
        XCTAssertTrue(
            merged.blocksDomain("x.com", at: now.addingTimeInterval(120)),
            "An unauthorized early end must be restored to the promised time"
        )
    }

    func testPullingTheEndForwardIsAcceptedInsideAnAuthorizedWindow() {
        let original = session(hours: 72)
        var shortened = original
        shortened.endsAt = now.addingTimeInterval(60)

        let merged = policy(
            sessions: [shortened],
            revision: 3,
            authorizedUntil: now.addingTimeInterval(600)
        ).carryingForwardSessions(from: policy(sessions: [original]), at: now.addingTimeInterval(120))
        XCTAssertFalse(merged.blocksDomain("x.com", at: now.addingTimeInterval(120)))
    }

    func testExtendingASessionIsAlwaysAllowed() {
        let original = session(hours: 24)
        var longer = original
        longer.endsAt = now.addingTimeInterval(96 * 3_600)

        let merged = policy(sessions: [longer], revision: 3)
            .carryingForwardSessions(from: policy(sessions: [original]), at: now.addingTimeInterval(60))
        XCTAssertTrue(merged.blocksDomain("x.com", at: now.addingTimeInterval(48 * 3_600)))
    }

    func testAnExpiredSessionIsNotResurrected() {
        let old = session(hours: 1)
        let later = now.addingTimeInterval(7_200)
        let merged = policy(sessions: nil, revision: 3).carryingForwardSessions(
            from: policy(sessions: [old]),
            at: later
        )
        XCTAssertTrue(merged.activeSessions(at: later).isEmpty)
        XCTAssertFalse(merged.blocksDomain("x.com", at: later))
    }

    // MARK: - Passage

    func testEarlyExitRequiresTheExactPassage() {
        let session = session()
        XCTAssertEqual(session.earlyExitPassage.split(separator: " ").count, 8)
        XCTAssertTrue(DesktopLockdownSessionGate.passageMatches(session.earlyExitPassage, session: session))
        XCTAssertTrue(DesktopLockdownSessionGate.passageMatches(session.earlyExitPassage.uppercased(), session: session))
        XCTAssertFalse(DesktopLockdownSessionGate.passageMatches("wrong words entirely", session: session))
        XCTAssertFalse(DesktopLockdownSessionGate.passageMatches("", session: session))
    }

    func testAZeroWordPassageStillNeedsAnExplicitEnd() {
        let session = DesktopLockdownSessionGate.makeSession(
            ruleIDs: [ruleID],
            duration: 3_600,
            lockdown: lockdown(passageWords: 0),
            at: now
        )
        XCTAssertTrue(session.earlyExitPassage.isEmpty)
        XCTAssertTrue(DesktopLockdownSessionGate.passageMatches("", session: session))
    }

    // MARK: - Compatibility

    func testPoliciesWrittenBeforeSessionsExistedStillDecode() throws {
        let legacy = """
        {"schemaVersion":1,"revision":7,"issuedAt":0,"rules":[]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let policy = try decoder.decode(DesktopEnforcementPolicy.self, from: legacy)
        XCTAssertEqual(policy.revision, 7)
        XCTAssertNil(policy.lockdownSessions)
    }
}
