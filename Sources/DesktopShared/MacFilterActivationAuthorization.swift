import Foundation

/// Pure evidence used to authorize the dangerous transition from a disabled
/// Network Extension preference to an enabled one. The app owns the asynchronous
/// work; this type only answers whether all observations belong to the same
/// desired-state generation.
struct MacFilterActivationAttempt: Equatable, Sendable {
    var desiredStateGeneration: UInt64
    var expectedBundleIdentifier: String
    var expectedProviderBuild: String
}

struct MacFilterActivationRuntimeState: Equatable, Sendable {
    var desiredStateGeneration: UInt64
    var wantsBlockingEnabled: Bool
    var isRemoving: Bool
}

struct MacFilterExtensionProperty: Equatable, Sendable {
    var bundleIdentifier: String
    var bundleVersion: String
    var isEnabled: Bool
    var isAwaitingUserApproval: Bool
    var isUninstalling: Bool
}

/// A properties callback can arrive before macOS has finished enabling a newly
/// approved system extension. Only `enabled` is authorization to continue;
/// every other state keeps the Network Extension preference disabled while the
/// app waits for fresh evidence.
enum MacFilterActivationPropertiesState: String, Equatable, Sendable {
    case enabled
    case awaitingUserApproval = "awaiting-user-approval"
    case installedDisabled = "installed-disabled"
    case unavailable
}

enum MacFilterPropertiesProofPhase: Equatable, Sendable {
    /// Proves the exact provider before asynchronous preparation begins.
    case beforePreparation
    /// Proves the exact provider again after this preparation completed and
    /// immediately before an enabled preference may be committed.
    case preparedForEnable(preparationGeneration: UInt64)
}

struct MacFilterDisabledPreferenceProof: Equatable, Sendable {
    fileprivate var desiredStateGeneration: UInt64
}

struct MacFilterExactBuildPropertiesProof: Equatable, Sendable {
    fileprivate var desiredStateGeneration: UInt64
    fileprivate var phase: MacFilterPropertiesProofPhase
}

struct MacFilterPreparationCompletion: Equatable, Sendable {
    fileprivate var desiredStateGeneration: UInt64
    fileprivate var preparationGeneration: UInt64
}

enum MacFilterActivationAuthorization {
    static func propertiesState(
        for attempt: MacFilterActivationAttempt,
        properties: [MacFilterExtensionProperty]
    ) -> MacFilterActivationPropertiesState {
        let exactBuild = properties.filter {
            $0.bundleIdentifier == attempt.expectedBundleIdentifier
                && $0.bundleVersion == attempt.expectedProviderBuild
        }
        if exactBuild.contains(where: {
            $0.isEnabled
                && !$0.isAwaitingUserApproval
                && !$0.isUninstalling
        }) {
            return .enabled
        }
        if exactBuild.contains(where: {
            $0.isAwaitingUserApproval && !$0.isUninstalling
        }) {
            return .awaitingUserApproval
        }
        if exactBuild.contains(where: {
            !$0.isEnabled && !$0.isUninstalling
        }) {
            return .installedDisabled
        }
        return .unavailable
    }

    /// A local assignment of `isEnabled = false` is not evidence. The proof is
    /// issued only after a successful preference load/save callback confirms
    /// that the persisted preference is disabled.
    static func disabledPreferenceProof(
        for attempt: MacFilterActivationAttempt,
        runtime: MacFilterActivationRuntimeState,
        preferenceOperationSucceeded: Bool,
        persistedPreferenceIsEnabled: Bool
    ) -> MacFilterDisabledPreferenceProof? {
        guard isCurrent(attempt, runtime: runtime),
              preferenceOperationSucceeded,
              !persistedPreferenceIsEnabled else {
            return nil
        }
        return MacFilterDisabledPreferenceProof(
            desiredStateGeneration: attempt.desiredStateGeneration
        )
    }

    /// The system-extension activation request must not be submitted until the
    /// disabled Network Extension preference has been confirmed.
    static func canRequestSystemExtensionActivation(
        for attempt: MacFilterActivationAttempt,
        disabledPreferenceProof: MacFilterDisabledPreferenceProof?,
        runtime: MacFilterActivationRuntimeState
    ) -> Bool {
        isCurrent(attempt, runtime: runtime)
            && disabledPreferenceProof?.desiredStateGeneration == attempt.desiredStateGeneration
    }

    /// Converts a properties callback into exact-build proof. A callback from a
    /// superseded desired-state generation is never reusable by the new attempt.
    static func exactBuildPropertiesProof(
        for attempt: MacFilterActivationAttempt,
        disabledPreferenceProof: MacFilterDisabledPreferenceProof?,
        requestStateGeneration: UInt64,
        phase: MacFilterPropertiesProofPhase,
        properties: [MacFilterExtensionProperty],
        runtime: MacFilterActivationRuntimeState
    ) -> MacFilterExactBuildPropertiesProof? {
        guard canRequestSystemExtensionActivation(
            for: attempt,
            disabledPreferenceProof: disabledPreferenceProof,
            runtime: runtime
        ), requestStateGeneration == attempt.desiredStateGeneration else {
            return nil
        }

        guard propertiesState(for: attempt, properties: properties) == .enabled else {
            return nil
        }
        return MacFilterExactBuildPropertiesProof(
            desiredStateGeneration: attempt.desiredStateGeneration,
            phase: phase
        )
    }

    static func canBeginPreparation(
        for attempt: MacFilterActivationAttempt,
        disabledPreferenceProof: MacFilterDisabledPreferenceProof?,
        propertiesProof: MacFilterExactBuildPropertiesProof?,
        runtime: MacFilterActivationRuntimeState
    ) -> Bool {
        guard isCurrent(attempt, runtime: runtime),
              disabledPreferenceProof?.desiredStateGeneration == attempt.desiredStateGeneration,
              propertiesProof?.desiredStateGeneration == attempt.desiredStateGeneration,
              propertiesProof?.phase == .beforePreparation else {
            return false
        }
        return true
    }

    /// Called by the asynchronous preparation callback. Comparing both the
    /// desired-state and preparation generations prevents an old resolver from
    /// authorizing a newer attempt.
    static func preparationCompletion(
        for attempt: MacFilterActivationAttempt,
        disabledPreferenceProof: MacFilterDisabledPreferenceProof?,
        initialPropertiesProof: MacFilterExactBuildPropertiesProof?,
        callbackPreparationGeneration: UInt64,
        currentPreparationGeneration: UInt64,
        runtime: MacFilterActivationRuntimeState
    ) -> MacFilterPreparationCompletion? {
        guard canBeginPreparation(
            for: attempt,
            disabledPreferenceProof: disabledPreferenceProof,
            propertiesProof: initialPropertiesProof,
            runtime: runtime
        ), callbackPreparationGeneration == currentPreparationGeneration else {
            return nil
        }
        return MacFilterPreparationCompletion(
            desiredStateGeneration: attempt.desiredStateGeneration,
            preparationGeneration: callbackPreparationGeneration
        )
    }

    /// Final enabled preference writes require a second exact-build properties
    /// proof obtained after preparation. The initial proof is intentionally
    /// insufficient because the extension may be disabled while DNS or host
    /// mapping preparation is in flight.
    static func canSaveEnabledPreference(
        for attempt: MacFilterActivationAttempt,
        disabledPreferenceProof: MacFilterDisabledPreferenceProof?,
        finalPropertiesProof: MacFilterExactBuildPropertiesProof?,
        preparationCompletion: MacFilterPreparationCompletion?,
        currentPreparationGeneration: UInt64,
        runtime: MacFilterActivationRuntimeState
    ) -> Bool {
        guard isCurrent(attempt, runtime: runtime),
              disabledPreferenceProof?.desiredStateGeneration == attempt.desiredStateGeneration,
              finalPropertiesProof?.desiredStateGeneration == attempt.desiredStateGeneration,
              preparationCompletion?.desiredStateGeneration == attempt.desiredStateGeneration,
              preparationCompletion?.preparationGeneration == currentPreparationGeneration,
              finalPropertiesProof?.phase == .preparedForEnable(
                preparationGeneration: currentPreparationGeneration
              ) else {
            return false
        }
        return true
    }

    private static func isCurrent(
        _ attempt: MacFilterActivationAttempt,
        runtime: MacFilterActivationRuntimeState
    ) -> Bool {
        runtime.wantsBlockingEnabled
            && !runtime.isRemoving
            && runtime.desiredStateGeneration == attempt.desiredStateGeneration
    }
}
