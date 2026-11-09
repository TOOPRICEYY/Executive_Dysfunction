import XCTest

final class MacFilterPreferenceTimeoutSafetyTests: XCTestCase {
    private let generation: UInt64 = 17
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let freshness: TimeInterval = 12

    func testSlowPreSaveChecksDoNotSafetyLockOrRemovePreferences() {
        for stage in [MacFilterPreferenceTimeoutSafety.Stage.loading, .verifyingExtension] {
            for target in [MacFilterPreferenceTimeoutTarget.enable, .preparationSuspension] {
                XCTAssertEqual(
                    MacFilterPreferenceTimeoutSafety.action(
                        timedOutGeneration: generation,
                        currentPreferenceGeneration: generation,
                        armedDeadlineGeneration: generation,
                        activeMutationGeneration: generation,
                        currentlyWantsDisabled: false,
                        target: target,
                        stage: stage
                    ),
                    .retryReadOnlyOperation
                )
            }
        }
    }

    func testSlowPropertiesReplyGetsIndependentReadBudgetNotWriteDeadline() {
        // Live regression: properties returned after ~10 seconds, before a
        // save was submitted. The old shared 8-second timer safety-locked it.
        XCTAssertEqual(MacFilterPreferenceTimeoutSafety.Stage.loading.deadline, 30)
        XCTAssertEqual(MacFilterPreferenceTimeoutSafety.Stage.verifyingExtension.deadline, 30)
        XCTAssertEqual(MacFilterPreferenceTimeoutSafety.Stage.saving.deadline, 8)
    }

    func testReadTimeoutDoesNotWeakenDisabledIntentOrOutstandingWriteSafety() {
        for wantsDisabled in [false, true] {
            let result = MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation,
                armedDeadlineGeneration: generation,
                activeMutationGeneration: generation,
                currentlyWantsDisabled: wantsDisabled,
                target: .enable,
                stage: .verifyingExtension,
                hasOutstandingEnabledSave: true
            )
            XCTAssertEqual(result, .persistEmergencyDisable)
        }
        XCTAssertEqual(
            MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation,
                armedDeadlineGeneration: generation,
                activeMutationGeneration: generation,
                currentlyWantsDisabled: true,
                target: .explicitDisable,
                stage: .loading
            ),
            .removePreferenceAndRetryDisable
        )
    }

    func testLateReadTimeoutCannotOwnNewRetryGeneration() {
        XCTAssertEqual(
            MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation + 1,
                armedDeadlineGeneration: generation + 1,
                activeMutationGeneration: generation + 1,
                currentlyWantsDisabled: false,
                target: .enable,
                stage: .verifyingExtension
            ),
            .ignoreStaleOperation
        )
    }

    func testSupersededButStillActiveTimeoutPersistsEmergencyDisable() {
        XCTAssertEqual(
            action(
                currentGeneration: generation + 1,
                armedGeneration: generation,
                activeGeneration: generation,
                target: .enable
            ),
            .persistEmergencyDisable
        )
    }

    func testDeadlineWithoutActiveOwnershipIsIgnored() {
        XCTAssertEqual(
            action(
                currentGeneration: generation,
                armedGeneration: generation + 1,
                activeGeneration: generation,
                target: .explicitDisable
            ),
            .ignoreStaleOperation
        )
        XCTAssertEqual(
            MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation,
                armedDeadlineGeneration: generation,
                activeMutationGeneration: nil,
                currentlyWantsDisabled: false,
                target: .preparationSuspension
            ),
            .ignoreStaleOperation
        )
    }

    func testTimedOutEnableAndPreparationSuspensionPersistEmergencyDisable() {
        XCTAssertEqual(action(target: .enable), .persistEmergencyDisable)
        XCTAssertEqual(
            action(target: .preparationSuspension),
            .persistEmergencyDisable
        )
    }

    func testTimedOutExplicitDisableRemovesPreferenceAndRetriesDisable() {
        XCTAssertEqual(
            action(target: .explicitDisable),
            .removePreferenceAndRetryDisable
        )
        XCTAssertTrue(
            MacFilterPreferenceTimeoutSafety.shouldRetryExplicitDisable(
                completedRetries: 0,
                maximumRetries: 2
            )
        )
        XCTAssertTrue(
            MacFilterPreferenceTimeoutSafety.shouldRetryExplicitDisable(
                completedRetries: 1,
                maximumRetries: 2
            )
        )
        XCTAssertFalse(
            MacFilterPreferenceTimeoutSafety.shouldRetryExplicitDisable(
                completedRetries: 2,
                maximumRetries: 2
            )
        )
    }

    func testSupersededOperationUsesCurrentDisabledIntent() {
        XCTAssertEqual(
            MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation + 1,
                armedDeadlineGeneration: generation,
                activeMutationGeneration: generation,
                currentlyWantsDisabled: true,
                target: .enable
            ),
            .removePreferenceAndRetryDisable
        )
        XCTAssertEqual(
            MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: generation,
                currentPreferenceGeneration: generation + 1,
                armedDeadlineGeneration: generation,
                activeMutationGeneration: generation,
                currentlyWantsDisabled: false,
                target: .explicitDisable
            ),
            .persistEmergencyDisable
        )
    }

    func testBreakGlassCompletionRequiresCurrentOperationAndDisabledIntent() {
        XCTAssertTrue(
            MacFilterPreferenceTimeoutSafety.acceptsBreakGlassCompletion(
                operationID: "current",
                activeOperationID: "current",
                stillWantsDisabled: true
            )
        )
        XCTAssertFalse(
            MacFilterPreferenceTimeoutSafety.acceptsBreakGlassCompletion(
                operationID: "late",
                activeOperationID: "current",
                stillWantsDisabled: true
            )
        )
        XCTAssertFalse(
            MacFilterPreferenceTimeoutSafety.acceptsBreakGlassCompletion(
                operationID: "current",
                activeOperationID: "current",
                stillWantsDisabled: false
            )
        )
    }

    func testFreshActiveFilterStatusMayStillHaveBlockPageHostMappings() {
        XCTAssertTrue(
            MacFilterBlockPageHostMappingSafety.mayStillBePresent(
                status: status(active: true, updatedAt: now.addingTimeInterval(-5)),
                now: now,
                freshness: freshness
            )
        )
    }

    func testInactiveFutureStaleAndMissingStatusesCannotRetainMappings() {
        XCTAssertFalse(mayStillBePresent(status: nil))
        XCTAssertFalse(
            mayStillBePresent(status: status(active: false, updatedAt: now))
        )
        XCTAssertFalse(
            mayStillBePresent(
                status: status(active: true, updatedAt: now.addingTimeInterval(1))
            )
        )
        XCTAssertFalse(
            mayStillBePresent(
                status: status(
                    active: true,
                    updatedAt: now.addingTimeInterval(-(freshness + 0.001))
                )
            )
        )
    }

    private func action(
        currentGeneration: UInt64? = nil,
        armedGeneration: UInt64? = nil,
        activeGeneration: UInt64? = nil,
        target: MacFilterPreferenceTimeoutTarget
    ) -> MacFilterPreferenceTimeoutAction {
        MacFilterPreferenceTimeoutSafety.action(
            timedOutGeneration: generation,
            currentPreferenceGeneration: currentGeneration ?? generation,
            armedDeadlineGeneration: armedGeneration ?? generation,
            activeMutationGeneration: activeGeneration ?? generation,
            currentlyWantsDisabled: false,
            target: target
        )
    }

    private func mayStillBePresent(status: FilterEnforcementStatus?) -> Bool {
        MacFilterBlockPageHostMappingSafety.mayStillBePresent(
            status: status,
            now: now,
            freshness: freshness
        )
    }

    private func status(active: Bool, updatedAt: Date) -> FilterEnforcementStatus {
        let policy = DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: now,
            rules: [],
            weakeningAuthorizationExpiresAt: nil,
            lockdownSessions: nil
        )
        var status = FilterEnforcementStatus(policy: policy, at: updatedAt)
        status.hasActiveWebRestrictions = active
        return status
    }
}
