import XCTest

final class MacFilterActivationAuthorizationTests: XCTestCase {
    private let attempt = MacFilterActivationAttempt(
        desiredStateGeneration: 17,
        expectedBundleIdentifier: "com.example.Holdfast.Filter",
        expectedProviderBuild: "44"
    )

    func testActivationRequiresSuccessfullyConfirmedDisabledPreference() {
        XCTAssertNil(disabledProof(operationSucceeded: false, isEnabled: false))
        XCTAssertNil(disabledProof(operationSucceeded: true, isEnabled: true))
        XCTAssertFalse(
            MacFilterActivationAuthorization.canRequestSystemExtensionActivation(
                for: attempt,
                disabledPreferenceProof: nil,
                runtime: runtime()
            )
        )
        XCTAssertTrue(
            MacFilterActivationAuthorization.canRequestSystemExtensionActivation(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                runtime: runtime()
            )
        )
    }

    func testDisabledPreferenceProofIsBoundToDesiredStateGeneration() {
        XCTAssertNil(disabledProof(runtimeGeneration: 18))
        XCTAssertFalse(
            MacFilterActivationAuthorization.canRequestSystemExtensionActivation(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                runtime: runtime(generation: 18)
            )
        )
    }

    func testPropertiesProofRequiresExactEnabledCurrentBuild() {
        XCTAssertNotNil(initialPropertiesProof(properties: [property()]))
        XCTAssertNil(initialPropertiesProof(properties: [property(bundleIdentifier: "com.example.Other")]))
        XCTAssertNil(initialPropertiesProof(properties: [property(bundleVersion: "43")]))
        XCTAssertNil(initialPropertiesProof(properties: [property(isEnabled: false)]))
        XCTAssertNil(initialPropertiesProof(properties: [property(isAwaitingApproval: true)]))
        XCTAssertNil(initialPropertiesProof(properties: [property(isUninstalling: true)]))
    }

    func testInstalledButDisabledExactBuildRemainsPendingInsteadOfFailingActivation() {
        XCTAssertEqual(
            MacFilterActivationAuthorization.propertiesState(
                for: attempt,
                properties: [property(isEnabled: false)]
            ),
            .installedDisabled
        )
        XCTAssertNil(initialPropertiesProof(properties: [property(isEnabled: false)]))
    }

    func testAwaitingApprovalExactBuildRemainsPending() {
        XCTAssertEqual(
            MacFilterActivationAuthorization.propertiesState(
                for: attempt,
                properties: [property(isEnabled: false, isAwaitingApproval: true)]
            ),
            .awaitingUserApproval
        )
    }

    func testOnlyExactEnabledCurrentBuildCanBecomeReady() {
        XCTAssertEqual(
            MacFilterActivationAuthorization.propertiesState(
                for: attempt,
                properties: [property()]
            ),
            .enabled
        )
        XCTAssertEqual(
            MacFilterActivationAuthorization.propertiesState(
                for: attempt,
                properties: [
                    property(bundleVersion: "43"),
                    property(isUninstalling: true)
                ]
            ),
            .unavailable
        )
    }

    func testPropertiesCallbackFromSupersededGenerationIsRejected() {
        XCTAssertNil(initialPropertiesProof(requestGeneration: 16))
        XCTAssertNil(initialPropertiesProof(runtimeGeneration: 18))
    }

    func testStaleAsyncPreparationIsRejected() {
        XCTAssertNil(
            completion(
                callbackPreparationGeneration: 4,
                currentPreparationGeneration: 5
            )
        )
        XCTAssertNil(
            completion(
                callbackPreparationGeneration: 5,
                currentPreparationGeneration: 5,
                runtimeGeneration: 18
            )
        )
    }

    func testInitialPropertiesProofCannotAuthorizeEnabledSave() {
        let completion = completion(
            callbackPreparationGeneration: 5,
            currentPreparationGeneration: 5
        )
        XCTAssertFalse(
            MacFilterActivationAuthorization.canSaveEnabledPreference(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                finalPropertiesProof: initialPropertiesProof(),
                preparationCompletion: completion,
                currentPreparationGeneration: 5,
                runtime: runtime()
            )
        )
    }

    func testFinalSaveRequiresReverifiedExactBuildBoundToPreparation() {
        let completion = completion(
            callbackPreparationGeneration: 5,
            currentPreparationGeneration: 5
        )
        XCTAssertTrue(
            MacFilterActivationAuthorization.canSaveEnabledPreference(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                finalPropertiesProof: finalPropertiesProof(preparationGeneration: 5),
                preparationCompletion: completion,
                currentPreparationGeneration: 5,
                runtime: runtime()
            )
        )
        XCTAssertFalse(
            MacFilterActivationAuthorization.canSaveEnabledPreference(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                finalPropertiesProof: finalPropertiesProof(preparationGeneration: 4),
                preparationCompletion: completion,
                currentPreparationGeneration: 5,
                runtime: runtime()
            )
        )
    }

    func testDisableOrRemovalInvalidatesEveryAuthorization() {
        XCTAssertFalse(
            MacFilterActivationAuthorization.canRequestSystemExtensionActivation(
                for: attempt,
                disabledPreferenceProof: disabledProof(),
                runtime: runtime(wantsEnabled: false)
            )
        )
        XCTAssertNil(initialPropertiesProof(isRemoving: true))
    }

    private func runtime(
        generation: UInt64 = 17,
        wantsEnabled: Bool = true,
        isRemoving: Bool = false
    ) -> MacFilterActivationRuntimeState {
        MacFilterActivationRuntimeState(
            desiredStateGeneration: generation,
            wantsBlockingEnabled: wantsEnabled,
            isRemoving: isRemoving
        )
    }

    private func disabledProof(
        operationSucceeded: Bool = true,
        isEnabled: Bool = false,
        runtimeGeneration: UInt64 = 17
    ) -> MacFilterDisabledPreferenceProof? {
        MacFilterActivationAuthorization.disabledPreferenceProof(
            for: attempt,
            runtime: runtime(generation: runtimeGeneration),
            preferenceOperationSucceeded: operationSucceeded,
            persistedPreferenceIsEnabled: isEnabled
        )
    }

    private func property(
        bundleIdentifier: String? = nil,
        bundleVersion: String = "44",
        isEnabled: Bool = true,
        isAwaitingApproval: Bool = false,
        isUninstalling: Bool = false
    ) -> MacFilterExtensionProperty {
        MacFilterExtensionProperty(
            bundleIdentifier: bundleIdentifier ?? attempt.expectedBundleIdentifier,
            bundleVersion: bundleVersion,
            isEnabled: isEnabled,
            isAwaitingUserApproval: isAwaitingApproval,
            isUninstalling: isUninstalling
        )
    }

    private func initialPropertiesProof(
        properties: [MacFilterExtensionProperty]? = nil,
        requestGeneration: UInt64 = 17,
        runtimeGeneration: UInt64 = 17,
        isRemoving: Bool = false
    ) -> MacFilterExactBuildPropertiesProof? {
        MacFilterActivationAuthorization.exactBuildPropertiesProof(
            for: attempt,
            disabledPreferenceProof: disabledProof(),
            requestStateGeneration: requestGeneration,
            phase: .beforePreparation,
            properties: properties ?? [property()],
            runtime: runtime(generation: runtimeGeneration, isRemoving: isRemoving)
        )
    }

    private func completion(
        callbackPreparationGeneration: UInt64,
        currentPreparationGeneration: UInt64,
        runtimeGeneration: UInt64 = 17
    ) -> MacFilterPreparationCompletion? {
        MacFilterActivationAuthorization.preparationCompletion(
            for: attempt,
            disabledPreferenceProof: disabledProof(),
            initialPropertiesProof: initialPropertiesProof(),
            callbackPreparationGeneration: callbackPreparationGeneration,
            currentPreparationGeneration: currentPreparationGeneration,
            runtime: runtime(generation: runtimeGeneration)
        )
    }

    private func finalPropertiesProof(
        preparationGeneration: UInt64
    ) -> MacFilterExactBuildPropertiesProof? {
        MacFilterActivationAuthorization.exactBuildPropertiesProof(
            for: attempt,
            disabledPreferenceProof: disabledProof(),
            requestStateGeneration: attempt.desiredStateGeneration,
            phase: .preparedForEnable(preparationGeneration: preparationGeneration),
            properties: [property()],
            runtime: runtime()
        )
    }
}
