import XCTest

final class MacFilterStartupWatchdogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testRunningPartialCoverageSatisfiesStartupButNotOldSessionOrWrongRevision() {
        let attempt = makeAttempt()
        var status = makeStatus(isReady: false)
        status.macFilterSettings?.isFiltering = true
        status.macFilterSettings?.missingRetryGuardDomainSuffixes = ["missing.example"]
        XCTAssertEqual(action(attempt, status: status, now: attempt.deadline), .satisfied)
        status.revision += 1
        XCTAssertEqual(action(attempt, status: status, now: attempt.deadline), .reportFailure)
        var stale = makeStatus(sessionID: "old-session", providerStartedAt: attempt.notBefore.addingTimeInterval(-1),
                               updatedAt: attempt.notBefore.addingTimeInterval(1))
        stale.macFilterSettings?.isFiltering = true
        XCTAssertEqual(action(attempt, status: stale, now: attempt.deadline), .reportFailure)
    }

    func testMissingStatusWaitsBeforeDeadlineAndReportsWithoutDisablingAtDeadline() {
        let attempt = makeAttempt()
        XCTAssertEqual(action(attempt, status: nil, now: now.addingTimeInterval(5)), .wait)
        XCTAssertEqual(action(attempt, status: nil, now: attempt.deadline), .reportFailure)
    }

    func testOldSessionCannotSatisfyAChangedEnable() {
        let attempt = makeAttempt()
        let status = makeStatus(
            sessionID: "old-session",
            providerStartedAt: attempt.notBefore.addingTimeInterval(-1),
            updatedAt: attempt.notBefore.addingTimeInterval(1)
        )
        XCTAssertEqual(action(attempt, status: status, now: attempt.deadline), .reportFailure)
    }

    func testFreshButUnreadyStatusOnlyReportsAtDeadline() {
        let attempt = makeAttempt()
        let status = makeStatus(isReady: false)
        XCTAssertEqual(action(attempt, status: status, now: attempt.deadline), .reportFailure)
    }

    func testWrongRevisionOrBuildCannotSatisfyWatchdog() {
        let attempt = makeAttempt()
        XCTAssertEqual(
            action(attempt, status: makeStatus(revision: 8), now: attempt.deadline),
            .reportFailure
        )
        XCTAssertEqual(
            action(attempt, status: makeStatus(providerBuild: "42"), now: attempt.deadline),
            .reportFailure
        )
    }

    func testFreshReadyProviderSatisfiesWatchdogEvenForIdlePolicy() {
        let attempt = makeAttempt()
        let status = makeStatus(hasActiveWebRestrictions: false)
        XCTAssertEqual(action(attempt, status: status, now: now.addingTimeInterval(2)), .satisfied)
    }

    func testUnchangedPreferenceAcceptsFreshHeartbeatFromExistingReadyProvider() {
        var attempt = makeAttempt()
        attempt.requiresFreshProviderStart = false
        let status = makeStatus(
            sessionID: "old-session",
            providerStartedAt: attempt.notBefore.addingTimeInterval(-600),
            updatedAt: attempt.notBefore.addingTimeInterval(1)
        )
        XCTAssertEqual(action(attempt, status: status, now: now.addingTimeInterval(2)), .satisfied)
    }

    func testUnchangedPreferenceStillRejectsHeartbeatOlderThanVerification() {
        var attempt = makeAttempt()
        attempt.requiresFreshProviderStart = false
        let status = makeStatus(
            sessionID: "old-session",
            providerStartedAt: attempt.notBefore.addingTimeInterval(-600),
            updatedAt: attempt.notBefore.addingTimeInterval(-1)
        )
        XCTAssertEqual(action(attempt, status: status, now: attempt.deadline), .reportFailure)
    }

    func testLateReadyReportRecoversWithoutNewActivation() {
        let attempt = makeAttempt()
        XCTAssertEqual(action(attempt, status: nil, now: attempt.deadline), .reportFailure)
        let later = attempt.deadline.addingTimeInterval(20)
        XCTAssertEqual(action(attempt, status: makeStatus(updatedAt: later), now: later), .satisfied)
    }

    func testGracePeriodAllowsMoreThanSixSeconds() {
        XCTAssertGreaterThanOrEqual(MacFilterStartupWatchdog.readinessDeadline, 30)
        XCTAssertEqual(action(makeAttempt(), status: nil, now: now.addingTimeInterval(10)), .wait)
    }

    func testStateChangeCancelsStaleWatchdog() {
        let attempt = makeAttempt()
        XCTAssertEqual(
            MacFilterStartupWatchdog.action(
                for: attempt,
                currentPreferenceGeneration: attempt.preferenceGeneration + 1,
                wantsEnabled: true,
                status: nil,
                now: attempt.deadline
            ),
            .cancel
        )
        XCTAssertEqual(
            MacFilterStartupWatchdog.action(
                for: attempt,
                currentPreferenceGeneration: attempt.preferenceGeneration,
                wantsEnabled: false,
                status: nil,
                now: attempt.deadline
            ),
            .cancel
        )
    }

    func testRuntimeStaleHeartbeatNeverAuthorizesPreferenceRemovalByItself() {
        XCTAssertEqual(
            MacFilterStartupWatchdog.staleHeartbeatAction(
                isBlockingDisabled: false,
                startupTransitionInProgress: false
            ),
            .observeWithoutPreferenceMutation
        )
        XCTAssertEqual(
            MacFilterStartupWatchdog.staleHeartbeatAction(
                isBlockingDisabled: false,
                startupTransitionInProgress: true
            ),
            .deferToStartupWatchdog
        )
        XCTAssertEqual(
            MacFilterStartupWatchdog.staleHeartbeatAction(
                isBlockingDisabled: true,
                startupTransitionInProgress: false
            ),
            .ignoreWhileDisabled
        )
    }

    private func action(
        _ attempt: MacFilterStartupWatchdogAttempt,
        status: FilterEnforcementStatus?,
        now: Date
    ) -> MacFilterStartupWatchdogAction {
        MacFilterStartupWatchdog.action(
            for: attempt,
            currentPreferenceGeneration: attempt.preferenceGeneration,
            wantsEnabled: true,
            status: status,
            now: now
        )
    }

    private func makeAttempt() -> MacFilterStartupWatchdogAttempt {
        MacFilterStartupWatchdogAttempt(
            preferenceGeneration: 9,
            expectedRevision: 7,
            expectedProviderBuild: "43",
            notBefore: now,
            deadline: now.addingTimeInterval(MacFilterStartupWatchdog.readinessDeadline),
            baselineSessionID: "old-session"
        )
    }

    private func makeStatus(
        revision: UInt64 = 7,
        sessionID: String = "new-session",
        providerStartedAt: Date? = nil,
        updatedAt: Date? = nil,
        providerBuild: String = "43",
        isReady: Bool = true,
        hasActiveWebRestrictions: Bool = true
    ) -> FilterEnforcementStatus {
        let startedAt = providerStartedAt ?? now.addingTimeInterval(1)
        let policy = DesktopEnforcementPolicy(
            revision: revision,
            issuedAt: now,
            rules: [],
            weakeningAuthorizationExpiresAt: nil,
            lockdownSessions: nil
        )
        let diagnostics = WebFilterDiagnosticsSnapshot(
            schemaVersion: WebFilterDiagnosticsSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            providerStartedAt: startedAt,
            providerVersion: "0.1.0",
            providerBuild: providerBuild,
            lastEventAt: startedAt,
            lastFlowAt: nil,
            policyRevision: revision,
            heartbeatSequence: 1,
            counters: [:],
            decisionReasons: [:],
            currentInspections: 0,
            peakInspections: 0,
            maximumInspectedBytes: 0,
            failOpenActive: false,
            failOpenUntil: nil,
            failOpenTrips: 0,
            unidentifiedDropsInWindow: 0,
            recentAnomalies: []
        )
        var status = FilterEnforcementStatus(
            policy: policy,
            at: updatedAt ?? now.addingTimeInterval(2),
            diagnostics: diagnostics
        )
        status.hasActiveWebRestrictions = hasActiveWebRestrictions
        status.macFilterSettings = MacFilterSettingsStatus(
            isReady: isReady,
            planMode: hasActiveWebRestrictions ? "domainRules" : "bypass",
            appliedPolicyRevision: revision,
            requiredRetryGuardDomainCount: hasActiveWebRestrictions ? 1 : 0,
            coveredRetryGuardDomainCount: hasActiveWebRestrictions ? 1 : 0,
            coveredRetryGuardDomainSuffixes: hasActiveWebRestrictions ? ["blocked.example"] : [],
            correlatedAddressCount: hasActiveWebRestrictions ? 1 : 0
        )
        return status
    }
}
