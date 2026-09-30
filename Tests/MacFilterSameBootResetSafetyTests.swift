import XCTest

final class MacFilterSameBootResetSafetyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let attemptID = "reset-1"
    private let configuration = MacFilterSameBootResetConfiguration(
        requiredHealthyConnectivityObservations: 3,
        minimumHealthyObservationInterval: 2,
        timeout: 15
    )

    func testHappyPathRequiresInitialAndFinalPreferenceProofs() throws {
        var transition = try transitionAfterRemoval(.succeeded)
        let initialToken = try loadToken(transition, stage: .initial)
        transition = MacFilterSameBootResetSafety.recordInitialPreferenceEvidence(
            .preferenceAbsent,
            token: initialToken,
            for: try XCTUnwrap(transition.state),
            context: context,
            now: now
        )
        let workToken = try uncertainWorkToken(transition)
        transition = MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
            .confirmedIdle,
            token: workToken,
            for: try XCTUnwrap(transition.state),
            context: context,
            now: now
        )

        transition = try recordHealthy(transition, at: now)
        transition = try recordHealthy(transition, at: now.addingTimeInterval(2))
        transition = try recordHealthy(transition, at: now.addingTimeInterval(4))

        let finalToken = try loadToken(transition, stage: .final)
        XCTAssertNotEqual(finalToken, initialToken)
        let completedAt = now.addingTimeInterval(5)
        transition = MacFilterSameBootResetSafety.recordFinalPreferenceEvidence(
            .disabledAndProviderConfigurationAbsent,
            uncertainWork: .confirmedIdle,
            token: finalToken,
            for: try XCTUnwrap(transition.state),
            context: context,
            now: completedAt
        )

        let receipt = try authorization(transition)
        XCTAssertNil(transition.state)
        XCTAssertEqual(receipt.attemptIdentifier, attemptID)
        XCTAssertEqual(receipt.enforcementGeneration, context.enforcementGeneration)
        XCTAssertEqual(receipt.bootSessionIdentifier, "boot-a")
        XCTAssertEqual(receipt.completedAt, completedAt)
        XCTAssertEqual(
            receipt.disposition,
            .clearApplicationSafetyLatchOnlyWhileRemainingDisabled
        )
    }

    func testStartEmitsPreferenceRemovalBeforeAnyProof() throws {
        let transition = start()
        let token = try removalToken(transition)

        XCTAssertNotNil(transition.state)
        XCTAssertEqual(token.attemptIdentifier, attemptID)
        XCTAssertThrowsError(try loadToken(transition, stage: .initial))
        XCTAssertThrowsError(try authorization(transition))
    }

    func testRemovalCallbackErrorAdvancesToAuthoritativeLoadWithoutAuthorizing() throws {
        let started = start()
        let removalToken = try removalToken(started)
        let transition = MacFilterSameBootResetSafety.recordPreferenceRemovalCallback(
            .returnedError,
            token: removalToken,
            for: try XCTUnwrap(started.state),
            context: context,
            now: now
        )

        let proofToken = try loadToken(transition, stage: .initial)
        XCTAssertNotEqual(proofToken, removalToken)
        XCTAssertNotNil(transition.state)
        XCTAssertThrowsError(try authorization(transition))
    }

    func testStaleRemovalCallbackIsIgnoredWithoutAdvancingCurrentState() throws {
        let started = start()
        let currentToken = try removalToken(started)
        let state = try XCTUnwrap(started.state)
        var staleToken = currentToken
        staleToken.sequence &+= 1

        let stale = MacFilterSameBootResetSafety.recordPreferenceRemovalCallback(
            .succeeded,
            token: staleToken,
            for: state,
            context: context,
            now: now
        )

        XCTAssertEqual(stale.state, state)
        XCTAssertEqual(stale.command, .ignoreStaleObservation)
    }

    func testOutstandingEnabledSaveKeepsUncertainWorkActiveAfterOtherLanesClear() {
        var snapshot = idleUncertainWorkSnapshot()
        snapshot.outstandingEnabledSaveCount = 1
        XCTAssertEqual(
            MacFilterSameBootResetSafety.uncertainWorkEvidence(for: snapshot),
            .active
        )

        snapshot.outstandingEnabledSaveCount = 0
        XCTAssertEqual(
            MacFilterSameBootResetSafety.uncertainWorkEvidence(for: snapshot),
            .confirmedIdle
        )
    }

    func testOrphanedOutstandingEnabledSaveRequestsCleanupRedrive() {
        var snapshot = idleUncertainWorkSnapshot()
        XCTAssertFalse(
            MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                for: snapshot
            )
        )

        snapshot.outstandingEnabledSaveCount = 1
        XCTAssertTrue(
            MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                for: snapshot
            )
        )
    }

    func testFirstOrphanedRedriveGetsOneFullBoundedCleanupBudget() {
        let initialDeadline = now.addingTimeInterval(5)
        let firstRedriveDeadline =
            MacFilterSameBootResetSafety.cleanupDeadlineAfterClaimingOrphanedRedrive(
                currentDeadline: initialDeadline,
                claimedAt: now,
                remediationBudget: 48,
                extensionAlreadyUsed: false
            )
        XCTAssertEqual(firstRedriveDeadline, now.addingTimeInterval(48))

        let repeatedRedriveDeadline =
            MacFilterSameBootResetSafety.cleanupDeadlineAfterClaimingOrphanedRedrive(
                currentDeadline: firstRedriveDeadline,
                claimedAt: now.addingTimeInterval(40),
                remediationBudget: 48,
                extensionAlreadyUsed: true
            )
        XCTAssertEqual(repeatedRedriveDeadline, firstRedriveDeadline)
    }

    func testOrphanedRedriveBudgetNeverShortensExistingDeadline() {
        let existingDeadline = now.addingTimeInterval(60)
        XCTAssertEqual(
            MacFilterSameBootResetSafety.cleanupDeadlineAfterClaimingOrphanedRedrive(
                currentDeadline: existingDeadline,
                claimedAt: now,
                remediationBudget: 48,
                extensionAlreadyUsed: false
            ),
            existingDeadline
        )
    }

    func testOwnerFailureNearInitialDeadlineCanClaimFullOrphanBudget() {
        let ownerCycleBudget: TimeInterval = 48
        let initialDeadline =
            MacFilterSameBootResetSafety.initialCleanupObservationDeadline(
                startedAt: now,
                ownerCycleBudget: ownerCycleBudget,
                pollSlack: 2
            )
        XCTAssertEqual(initialDeadline, now.addingTimeInterval(50))

        var snapshot = idleUncertainWorkSnapshot()
        snapshot.outstandingEnabledSaveCount = 1
        snapshot.breakGlassRemovalIsInFlight = true
        XCTAssertFalse(
            MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                for: snapshot
            )
        )

        let ownerFailedAt = now.addingTimeInterval(47)
        snapshot.breakGlassRemovalIsInFlight = false
        let orphanClaimedAt = ownerFailedAt.addingTimeInterval(0.25)
        XCTAssertLessThan(orphanClaimedAt, initialDeadline)
        XCTAssertTrue(
            MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                for: snapshot
            )
        )

        let extendedDeadline =
            MacFilterSameBootResetSafety.cleanupDeadlineAfterClaimingOrphanedRedrive(
                currentDeadline: initialDeadline,
                claimedAt: orphanClaimedAt,
                remediationBudget: ownerCycleBudget,
                extensionAlreadyUsed: false
            )
        XCTAssertEqual(
            extendedDeadline,
            orphanClaimedAt.addingTimeInterval(ownerCycleBudget)
        )
    }

    func testActiveCleanupOrMutationLanePreventsDuplicateRedrive() {
        let activeLaneKeyPaths: [
            WritableKeyPath<MacFilterSameBootResetUncertainWorkSnapshot, Bool>
        ] = [
            \.lateEnableQuarantineExists,
            \.lateEnableQuarantineTaskExists,
            \.lateEnableProbeExists,
            \.lateEnableProbeDeadlineExists,
            \.breakGlassRemovalIsInFlight,
            \.activePreferenceMutationExists,
            \.pendingPreferenceMutationExists,
            \.pendingFinalEnableVerificationExists,
        ]

        for keyPath in activeLaneKeyPaths {
            var snapshot = idleUncertainWorkSnapshot()
            snapshot.outstandingEnabledSaveCount = 1
            snapshot[keyPath: keyPath] = true
            XCTAssertFalse(
                MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                    for: snapshot
                )
            )
        }

        var snapshot = idleUncertainWorkSnapshot()
        snapshot.outstandingEnabledSaveCount = 1
        snapshot.configurationOperationCount = 1
        XCTAssertFalse(
            MacFilterSameBootResetSafety.shouldRedriveOrphanedEnabledSaveCleanup(
                for: snapshot
            )
        )
    }

    func testUncertainWorkSnapshotRejectsInvalidCountsAndAnyTrackedLane() {
        var snapshot = idleUncertainWorkSnapshot()
        snapshot.configurationOperationCount = -1
        XCTAssertEqual(
            MacFilterSameBootResetSafety.uncertainWorkEvidence(for: snapshot),
            .unknown
        )

        snapshot = idleUncertainWorkSnapshot()
        snapshot.breakGlassRemovalIsInFlight = true
        XCTAssertEqual(
            MacFilterSameBootResetSafety.uncertainWorkEvidence(for: snapshot),
            .active
        )
    }

    func testConnectivityCallbackRequiresExactActiveProbeIdentity() {
        let identity = MacFilterSameBootResetConnectivityProbeIdentity(
            attemptIdentifier: attemptID,
            resetGeneration: 7,
            operationIdentifier: "probe-current",
            token: MacFilterSameBootResetProbeToken(
                attemptIdentifier: attemptID,
                enforcementGeneration: 7,
                sequence: 3
            )
        )
        XCTAssertTrue(
            MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                identity: identity,
                activeIdentity: identity
            )
        )
        var stale = identity
        stale.operationIdentifier = "probe-stale"
        XCTAssertFalse(
            MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                identity: stale,
                activeIdentity: identity
            )
        )
        stale = identity
        stale.token.sequence += 1
        XCTAssertFalse(
            MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                identity: stale,
                activeIdentity: identity
            )
        )
        XCTAssertFalse(
            MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                identity: identity,
                activeIdentity: nil
            )
        )
    }

    func testStartsOnlyWithLatchDisabledIntentAndBootIdentity() {
        XCTAssertEqual(
            start(context: context(latch: false)).command,
            .keepApplicationSafetyLatch(reason: .applicationSafetyLatchNotSet)
        )
        XCTAssertEqual(
            start(context: context(disabled: false)).command,
            .keepApplicationSafetyLatch(reason: .blockingIsNotDisabled)
        )
        XCTAssertEqual(
            start(context: context(boot: nil)).command,
            .keepApplicationSafetyLatch(reason: .missingBootSessionIdentifier)
        )
    }

    func testOnlyAbsentOrDisabledWithoutProviderConfigurationPassInitialProof() throws {
        for accepted in [
            MacFilterSameBootResetPreferenceEvidence.preferenceAbsent,
            .disabledAndProviderConfigurationAbsent,
        ] {
            XCTAssertNoThrow(try transitionAfterInitialPreference(accepted))
        }

        XCTAssertEqual(
            try transitionAfterInitialPreference(.disabledWithProviderConfiguration).command,
            .keepApplicationSafetyLatch(reason: .providerConfigurationStillPresent)
        )
        XCTAssertEqual(
            try transitionAfterInitialPreference(.enabled).command,
            .keepApplicationSafetyLatch(reason: .preferenceEnabled)
        )
        XCTAssertEqual(
            try transitionAfterInitialPreference(.unknown).command,
            .keepApplicationSafetyLatch(reason: .preferenceUnconfirmed)
        )
    }

    func testRemovalSuccessAloneCannotSkipPreferenceAndWorkProofs() throws {
        let removalCompleted = try transitionAfterRemoval(.succeeded)
        let fakeWorkToken = MacFilterSameBootResetProbeToken(
            attemptIdentifier: attemptID,
            enforcementGeneration: context.enforcementGeneration,
            sequence: 3
        )
        let skipped = MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
            .confirmedIdle,
            token: fakeWorkToken,
            for: try XCTUnwrap(removalCompleted.state),
            context: context,
            now: now
        )
        XCTAssertEqual(skipped.state, removalCompleted.state)
        XCTAssertEqual(skipped.command, .ignoreStaleObservation)
    }

    func testActiveOrUnknownBroadPreferenceWorkKeepsLatch() throws {
        let initial = try transitionAfterInitialPreference(.preferenceAbsent)
        let token = try uncertainWorkToken(initial)
        let state = try XCTUnwrap(initial.state)
        XCTAssertEqual(
            MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
                .active,
                token: token,
                for: state,
                context: context,
                now: now
            ).command,
            .keepApplicationSafetyLatch(reason: .uncertainPreferenceWorkActive)
        )
        XCTAssertEqual(
            MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
                .unknown,
                token: token,
                for: state,
                context: context,
                now: now
            ).command,
            .keepApplicationSafetyLatch(reason: .uncertainPreferenceWorkUnconfirmed)
        )
    }

    func testExactlyThreeConsecutiveSpacedHealthyObservationsAreRequired() throws {
        var transition = try transitionAtConnectivity()
        transition = try recordHealthy(transition, at: now)
        transition = try recordHealthy(transition, at: now.addingTimeInterval(2))

        let beforeThird = try connectivityCommand(transition)
        XCTAssertEqual(beforeThird.remaining, 1)
        XCTAssertThrowsError(try loadToken(transition, stage: .final))

        transition = try recordHealthy(transition, at: now.addingTimeInterval(4))
        XCTAssertNoThrow(try loadToken(transition, stage: .final))
    }

    func testEarlyHealthyObservationDoesNotCount() throws {
        var transition = try transitionAtConnectivity()
        transition = try recordHealthy(transition, at: now)
        let stateBefore = transition.state
        let tokenBefore = try connectivityCommand(transition).token

        transition = try recordHealthy(transition, at: now.addingTimeInterval(1))
        XCTAssertEqual(transition.state, stateBefore)
        XCTAssertEqual(try connectivityCommand(transition).token, tokenBefore)
        XCTAssertEqual(try connectivityCommand(transition).remaining, 2)
    }

    func testConnectivityFailureResetsStreakAndKeepsLatch() throws {
        var transition = try transitionAtConnectivity()
        transition = try recordHealthy(transition, at: now)
        transition = try recordConnectivity(.unhealthy, transition, at: now.addingTimeInterval(2))
        let reset = try connectivityCommand(transition)
        XCTAssertEqual(reset.remaining, 3)
        XCTAssertEqual(reset.notBefore, now.addingTimeInterval(4))
        XCTAssertThrowsError(try authorization(transition))
    }

    func testUnknownConnectivityFailsClosed() throws {
        let transition = try recordConnectivity(
            .unknown,
            try transitionAtConnectivity(),
            at: now
        )
        XCTAssertEqual(
            transition.command,
            .keepApplicationSafetyLatch(reason: .connectivityUnconfirmed)
        )
    }

    func testFinalProofMustPostdateConnectivityAndRecheckBroadWork() throws {
        let final = try transitionAtFinalPreference()
        let token = try loadToken(final, stage: .final)
        let state = try XCTUnwrap(final.state)

        XCTAssertEqual(
            MacFilterSameBootResetSafety.recordFinalPreferenceEvidence(
                .preferenceAbsent,
                uncertainWork: .confirmedIdle,
                token: token,
                for: state,
                context: context,
                now: now.addingTimeInterval(4)
            ).command,
            .keepApplicationSafetyLatch(reason: .finalPreferenceProofNotFresh)
        )
        XCTAssertEqual(
            MacFilterSameBootResetSafety.recordFinalPreferenceEvidence(
                .preferenceAbsent,
                uncertainWork: .active,
                token: token,
                for: state,
                context: context,
                now: now.addingTimeInterval(5)
            ).command,
            .keepApplicationSafetyLatch(reason: .uncertainPreferenceWorkActive)
        )
    }

    func testStaleProofTokenIsIgnoredAndCannotAuthorize() throws {
        let final = try transitionAtFinalPreference()
        let state = try XCTUnwrap(final.state)
        let stale = MacFilterSameBootResetProbeToken(
            attemptIdentifier: attemptID,
            enforcementGeneration: context.enforcementGeneration,
            sequence: 1
        )
        let transition = MacFilterSameBootResetSafety.recordFinalPreferenceEvidence(
            .preferenceAbsent,
            uncertainWork: .confirmedIdle,
            token: stale,
            for: state,
            context: context,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(transition.state, state)
        XCTAssertEqual(transition.command, .ignoreStaleObservation)
    }

    func testGenerationBootDesiredStateAndLatchChangesFenceCallbacks() throws {
        let started = start()
        let token = try removalToken(started)
        let state = try XCTUnwrap(started.state)

        XCTAssertEqual(
            removal(.succeeded, token, state, context(generation: 8)).command,
            .keepApplicationSafetyLatch(reason: .enforcementGenerationChanged)
        )
        XCTAssertEqual(
            removal(.succeeded, token, state, context(boot: "boot-b")).command,
            .keepApplicationSafetyLatch(reason: .bootSessionChanged)
        )
        XCTAssertEqual(
            removal(.succeeded, token, state, context(disabled: false)).command,
            .keepApplicationSafetyLatch(reason: .blockingIsNotDisabled)
        )
        XCTAssertEqual(
            removal(.succeeded, token, state, context(latch: false)).command,
            .keepApplicationSafetyLatch(reason: .applicationSafetyLatchNotSet)
        )
    }

    func testTimeoutAndInvalidConfigurationsKeepLatch() throws {
        let started = start()
        let token = try removalToken(started)
        let state = try XCTUnwrap(started.state)
        XCTAssertEqual(
            removal(.succeeded, token, state, context, now: state.deadline).command,
            .keepApplicationSafetyLatch(reason: .deadlineExceeded)
        )

        XCTAssertEqual(
            start(configuration: configuration(required: 1)).command,
            .keepApplicationSafetyLatch(reason: .invalidConfiguration)
        )
        XCTAssertEqual(
            start(configuration: configuration(required: 3, interval: 5, timeout: 10)).command,
            .keepApplicationSafetyLatch(reason: .invalidConfiguration)
        )
    }

    private var context: MacFilterSameBootResetContext {
        context()
    }

    private func context(
        latch: Bool = true,
        disabled: Bool = true,
        generation: UInt64 = 7,
        boot: String? = "boot-a"
    ) -> MacFilterSameBootResetContext {
        MacFilterSameBootResetContext(
            applicationSafetyLatchIsSet: latch,
            blockingIsDisabled: disabled,
            enforcementGeneration: generation,
            bootSessionIdentifier: boot
        )
    }

    private func start(
        context: MacFilterSameBootResetContext? = nil,
        configuration: MacFilterSameBootResetConfiguration? = nil
    ) -> MacFilterSameBootResetTransition {
        MacFilterSameBootResetSafety.start(
            attemptIdentifier: attemptID,
            context: context ?? self.context,
            now: now,
            configuration: configuration ?? self.configuration
        )
    }

    private func transitionAfterInitialPreference(
        _ evidence: MacFilterSameBootResetPreferenceEvidence
    ) throws -> MacFilterSameBootResetTransition {
        let started = try transitionAfterRemoval(.succeeded)
        return initial(
            evidence,
            try loadToken(started, stage: .initial),
            try XCTUnwrap(started.state),
            context
        )
    }

    private func transitionAfterRemoval(
        _ evidence: MacFilterSameBootResetRemovalCallbackEvidence
    ) throws -> MacFilterSameBootResetTransition {
        let started = start()
        return removal(
            evidence,
            try removalToken(started),
            try XCTUnwrap(started.state),
            context
        )
    }

    private func transitionAtConnectivity() throws -> MacFilterSameBootResetTransition {
        let initial = try transitionAfterInitialPreference(.preferenceAbsent)
        let token = try uncertainWorkToken(initial)
        return MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
            .confirmedIdle,
            token: token,
            for: try XCTUnwrap(initial.state),
            context: context,
            now: now
        )
    }

    private func transitionAtFinalPreference() throws -> MacFilterSameBootResetTransition {
        var transition = try transitionAtConnectivity()
        transition = try recordHealthy(transition, at: now)
        transition = try recordHealthy(transition, at: now.addingTimeInterval(2))
        return try recordHealthy(transition, at: now.addingTimeInterval(4))
    }

    private func initial(
        _ evidence: MacFilterSameBootResetPreferenceEvidence,
        _ token: MacFilterSameBootResetProbeToken,
        _ state: MacFilterSameBootResetState,
        _ context: MacFilterSameBootResetContext,
        now: Date? = nil
    ) -> MacFilterSameBootResetTransition {
        MacFilterSameBootResetSafety.recordInitialPreferenceEvidence(
            evidence,
            token: token,
            for: state,
            context: context,
            now: now ?? self.now
        )
    }

    private func removal(
        _ evidence: MacFilterSameBootResetRemovalCallbackEvidence,
        _ token: MacFilterSameBootResetProbeToken,
        _ state: MacFilterSameBootResetState,
        _ context: MacFilterSameBootResetContext,
        now: Date? = nil
    ) -> MacFilterSameBootResetTransition {
        MacFilterSameBootResetSafety.recordPreferenceRemovalCallback(
            evidence,
            token: token,
            for: state,
            context: context,
            now: now ?? self.now
        )
    }

    private func recordHealthy(
        _ transition: MacFilterSameBootResetTransition,
        at date: Date
    ) throws -> MacFilterSameBootResetTransition {
        try recordConnectivity(.healthy, transition, at: date)
    }

    private func recordConnectivity(
        _ evidence: MacFilterSameBootResetConnectivityEvidence,
        _ transition: MacFilterSameBootResetTransition,
        at date: Date
    ) throws -> MacFilterSameBootResetTransition {
        let probe = try connectivityCommand(transition)
        return MacFilterSameBootResetSafety.recordConnectivityEvidence(
            evidence,
            token: probe.token,
            for: try XCTUnwrap(transition.state),
            context: context,
            now: date
        )
    }

    private func loadToken(
        _ transition: MacFilterSameBootResetTransition,
        stage expectedStage: MacFilterSameBootResetPreferenceProofStage
    ) throws -> MacFilterSameBootResetProbeToken {
        guard case let .loadNetworkExtensionPreference(stage, token) = transition.command,
              stage == expectedStage else {
            throw TestError.unexpectedCommand
        }
        return token
    }

    private func removalToken(
        _ transition: MacFilterSameBootResetTransition
    ) throws -> MacFilterSameBootResetProbeToken {
        guard case let .removeNetworkExtensionPreference(token) = transition.command else {
            throw TestError.unexpectedCommand
        }
        return token
    }

    private func uncertainWorkToken(
        _ transition: MacFilterSameBootResetTransition
    ) throws -> MacFilterSameBootResetProbeToken {
        guard case let .verifyNoUncertainPreferenceWork(token) = transition.command else {
            throw TestError.unexpectedCommand
        }
        return token
    }

    private func connectivityCommand(
        _ transition: MacFilterSameBootResetTransition
    ) throws -> (
        token: MacFilterSameBootResetProbeToken,
        remaining: Int,
        notBefore: Date
    ) {
        guard case let .observeConnectivity(token, remaining, notBefore) =
                transition.command else {
            throw TestError.unexpectedCommand
        }
        return (token, remaining, notBefore)
    }

    private func authorization(
        _ transition: MacFilterSameBootResetTransition
    ) throws -> MacFilterSameBootResetAuthorization {
        guard case let .authorized(receipt) = transition.command else {
            throw TestError.unexpectedCommand
        }
        return receipt
    }

    private func configuration(
        required: Int = 3,
        interval: TimeInterval = 2,
        timeout: TimeInterval = 15
    ) -> MacFilterSameBootResetConfiguration {
        MacFilterSameBootResetConfiguration(
            requiredHealthyConnectivityObservations: required,
            minimumHealthyObservationInterval: interval,
            timeout: timeout
        )
    }

    private func idleUncertainWorkSnapshot()
        -> MacFilterSameBootResetUncertainWorkSnapshot {
        MacFilterSameBootResetUncertainWorkSnapshot(
            lateEnableQuarantineExists: false,
            lateEnableQuarantineTaskExists: false,
            lateEnableProbeExists: false,
            lateEnableProbeDeadlineExists: false,
            breakGlassRemovalIsInFlight: false,
            activePreferenceMutationExists: false,
            pendingPreferenceMutationExists: false,
            pendingFinalEnableVerificationExists: false,
            configurationOperationCount: 0,
            outstandingEnabledSaveCount: 0
        )
    }

    private enum TestError: Error {
        case unexpectedCommand
    }
}
