import XCTest
// The desktop decision layer is compiled directly into this hostless test
// bundle; see project.yml. Importing the app module would drag in
// NetworkExtension and a live filter configuration.

final class DesktopLockdownSessionTests: XCTestCase {
    func testCancellationAuthorizationHasStableAuthenticatedEncoding() throws {
        var value = policy(sessions: [])
        value.lockdownCancellationAuthorization = DesktopLockdownCancellationAuthorization(
            sessionIDs: [UUID(), UUID(), UUID()], expiresAt: now.addingTimeInterval(3600))
        let key = Data(repeating: 1, count: 32)
        let signature = try DesktopPolicyAuthenticator.authenticationCode(for: value, key: key)
        for _ in 0..<10 {
            let decoded = try JSONDecoder().decode(DesktopEnforcementPolicy.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(try DesktopPolicyAuthenticator.authenticationCode(for: decoded, key: key), signature)
        }
    }
    func testSharedRoundTripPreservesTargetsDeadlineAndExitPolicy() throws {
        var held = session(hours: 12)
        held.ruleSnapshots = [dormantRule()]
        let portable = held.cloudSession(currentRules: [])
        let decoded = try JSONDecoder().decode(CloudLockdownSession.self, from: JSONEncoder().encode(portable))
        let imported = DesktopLockdownSession.fromCloud(decoded)
        XCTAssertEqual(imported.id, held.id)
        XCTAssertEqual(imported.endsAt, held.endsAt)
        XCTAssertEqual(imported.earlyExitPassage, held.earlyExitPassage)
        XCTAssertEqual(imported.lockdown.severity, held.lockdown.severity)
        XCTAssertEqual(imported.lockdown.unlockDelayDays, held.lockdown.unlockDelayDays)
        XCTAssertTrue(policy(sessions: [imported], rules: []).blocksDomain("x.com", at: now))
    }

    func testScopedCancellationCannotReleaseOtherSessionOrWeakenRules() {
        let first = session(hours: 1), second = session(hours: 2)
        let original = policy(sessions: [first, second])
        var proposed = policy(sessions: [])
        proposed.lockdownCancellationAuthorization = DesktopLockdownCancellationAuthorization(sessionIDs: [first.id], expiresAt: first.endsAt)
        let result = proposed.carryingForwardSessions(from: original, at: now)
        XCTAssertEqual(result.lockdownSessions?.map(\.id), [second.id])
        proposed.rules[0].domains = []
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: original, with: proposed, at: now))
    }

    func testScopedCancellationExpiresAndSurvivesPolicyRoundTrip() throws {
        let held = session(hours: 1)
        var proposed = policy(sessions: [])
        proposed.lockdownCancellationAuthorization = DesktopLockdownCancellationAuthorization(sessionIDs: [held.id], expiresAt: now.addingTimeInterval(60))
        let decoded = try JSONDecoder().decode(DesktopEnforcementPolicy.self, from: JSONEncoder().encode(proposed))
        XCTAssertTrue(decoded.carryingForwardSessions(from: policy(sessions: [held]), at: now).activeSessions(at: now).isEmpty)
        XCTAssertEqual(decoded.carryingForwardSessions(from: policy(sessions: [held]), at: now.addingTimeInterval(61)).lockdownSessions?.count, 1)
    }

    func testBrowserPauseCannotRemoveLockdownRuleBeforeEvaluation() {
        let original = policy(sessions: [session(hours: 1)])
        let paused = original.excludingTemporarilyPausedRules([ruleID], at: now)
        XCTAssertTrue(paused.blocksDomain("x.com", at: now))
        let expired = original.excludingTemporarilyPausedRules([ruleID], at: now.addingTimeInterval(3_600))
        XCTAssertFalse(expired.blocksDomain("x.com", at: now.addingTimeInterval(3_600)))
    }

    func testNativePauseAndBlockPageControlsAreOverridden() {
        var rule = dormantRule()
        rule.pausedUntil = now.addingTimeInterval(7_200)
        rule.lockdown.allowsTimeExtensions = true
        let value = policy(sessions: [session(hours: 1)], rules: [rule])
        XCTAssertTrue(value.blocksDomain("x.com", at: now))
        let status = FilterEnforcementStatus(policy: value, at: now)
        XCTAssertEqual(status.blockPageRules?.first?.allowsTimeExtensions, false)
        XCTAssertNil(status.temporaryAllowanceExpirations?[ruleID])
        XCTAssertFalse(value.blocksDomain("x.com", at: now.addingTimeInterval(3_600)))
    }

    func testSnapshotSurvivesDeletedGroupAndEndsExactlyOnTime() {
        var hold = session(hours: 1)
        hold.ruleSnapshots = [dormantRule()]
        let value = policy(sessions: [hold], rules: [])
        XCTAssertTrue(value.blocksDomain("x.com", at: now))
        XCTAssertFalse(value.blocksDomain("x.com", at: hold.endsAt))
    }

    func testSnapshotAndNewTargetsAreBothEnforcedDuringLockdown() {
        var hold = session(hours: 1)
        hold.ruleSnapshots = [dormantRule()]
        var edited = dormantRule()
        edited.domains = ["youtube.com"]
        let value = policy(sessions: [hold], rules: [edited])
        XCTAssertTrue(value.blocksDomain("x.com", at: now))
        XCTAssertTrue(value.blocksDomain("youtube.com", at: now))
        XCTAssertFalse(value.blocksDomain("example.com", at: now))
    }

    func testCannotRemoveSelectedIDsOrPostponeSessionWithoutAuthorization() {
        let hold = session()
        var weakened = hold
        weakened.ruleIDs = []
        weakened.startedAt = now.addingTimeInterval(60)
        weakened.earlyExitPassage = ""
        let result = policy(sessions: [weakened]).carryingForwardSessions(from: policy(sessions: [hold]), at: now)
        XCTAssertEqual(result.lockdownSessions?.first?.ruleIDs, hold.ruleIDs)
        XCTAssertEqual(result.lockdownSessions?.first?.startedAt, hold.startedAt)
        XCTAssertEqual(result.lockdownSessions?.first?.earlyExitPassage, hold.earlyExitPassage)
        XCTAssertTrue(result.blocksDomain("x.com", at: now))
    }

    func testOverlappingLockdownsOnlyReleaseAfterLastExpiry() {
        let value = policy(sessions: [session(hours: 1), session(hours: 2)])
        XCTAssertTrue(value.blocksDomain("x.com", at: now.addingTimeInterval(3_600)))
        XCTAssertFalse(value.blocksDomain("x.com", at: now.addingTimeInterval(7_200)))
    }
    func testRuleEditingRequiresPassageWaitAndExpires() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var saved = lockdown()
        saved.severity = "passageOnly"
        let grant = DesktopRuleEditUnlock(policy: saved, process: UnlockProcess(startedAt: start))
        guard case .unlocked = grant.phase(for: saved, at: start) else { return XCTFail("Passage-only should open immediately") }
        guard case .idle = grant.phase(for: saved, at: start.addingTimeInterval(3_601)) else { return XCTFail("Edit window must expire") }
        var stronger = saved
        stronger.unlockDelayDays = 4
        guard case .idle = grant.phase(for: stronger, at: start) else { return XCTFail("Changed policy invalidates grant") }
        saved.severity = "delayed"
        saved.unlockDelayDays = 2
        let delayed = DesktopRuleEditUnlock(policy: saved, process: UnlockProcess(startedAt: start))
        guard case .waiting = delayed.phase(for: saved, at: start) else { return XCTFail("Must respect saved delay") }
    }

    func testRuleEditAuthorizationCannotWeakenAnotherGroupOrSession() {
        let first = dormantRule()
        var second = first
        second.id = UUID()
        let original = policy(sessions: nil, rules: [first, second])
        var proposed = original
        proposed.rules[0].domains = []
        XCTAssertTrue(DesktopRuleEditUnlock.canAuthorize(ruleID: first.id, existing: original, proposed: proposed))
        proposed.rules[1].domains = []
        XCTAssertFalse(DesktopRuleEditUnlock.canAuthorize(ruleID: first.id, existing: original, proposed: proposed))
        proposed = original
        proposed.lockdownSessions = [DesktopLockdownSessionGate.makeSession(ruleIDs: [first.id], duration: 60, lockdown: lockdown())]
        XCTAssertFalse(DesktopRuleEditUnlock.canAuthorize(ruleID: first.id, existing: original, proposed: proposed))
    }

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

/// Republishing unchanged policy saves the filter configuration and restarts
/// the provider, causing a measured startup interruption for no benefit.
final class PolicyContentChangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rule(domains: Set<String>, enabled: Bool = true) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!,
            name: "Focus",
            isEnabled: enabled,
            enforcementMode: .blockList,
            windows: [],
            domains: domains,
            macApplicationIdentifiers: [],
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(
                severity: "delayed",
                unlockDelayDays: 1,
                passageWordCount: 4,
                confirmationWindowHours: 24,
                editWindowHours: 1,
                allowsTimeExtensions: false,
                maximumTimeExtensionHours: 0
            )
        )
    }

    private func policy(
        revision: UInt64,
        domains: Set<String> = ["x.com"],
        enabled: Bool = true,
        issuedAt: Date? = nil,
        sessions: [DesktopLockdownSession]? = nil
    ) -> DesktopEnforcementPolicy {
        DesktopEnforcementPolicy(
            revision: revision,
            issuedAt: issuedAt ?? now,
            rules: [rule(domains: domains, enabled: enabled)],
            weakeningAuthorizationExpiresAt: nil,
            lockdownSessions: sessions
        )
    }

    func testRevisionAndIssueTimeAloneAreNotAChange() {
        XCTAssertTrue(
            policy(revision: 240, issuedAt: now.addingTimeInterval(9_999))
                .hasSameContent(as: policy(revision: 226)),
            "A bumped revision on identical rules must not count as a change"
        )
    }

    func testRealEditsAreDetected() {
        let base = policy(revision: 1)
        XCTAssertFalse(base.hasSameContent(as: policy(revision: 1, domains: ["x.com", "reddit.com"])))
        XCTAssertFalse(base.hasSameContent(as: policy(revision: 1, enabled: false)))
        XCTAssertFalse(base.hasSameContent(as: .empty))
    }

    func testStartingOrEndingASessionIsAChange() {
        let session = DesktopLockdownSessionGate.makeSession(
            ruleIDs: [UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!],
            duration: 86_400,
            lockdown: rule(domains: []).lockdown,
            at: now
        )
        let without = policy(revision: 1)
        let with = policy(revision: 2, sessions: [session])
        XCTAssertFalse(without.hasSameContent(as: with))
        XCTAssertFalse(with.hasSameContent(as: without))
        XCTAssertTrue(with.hasSameContent(as: policy(revision: 9, sessions: [session])))
    }

    func testAnEmptySessionListEqualsNoSessionList() {
        XCTAssertTrue(policy(revision: 1, sessions: []).hasSameContent(as: policy(revision: 1, sessions: nil)))
    }
}
