import Foundation

struct MacFilterSameBootResetConfiguration: Equatable, Sendable {
    var requiredHealthyConnectivityObservations: Int
    var minimumHealthyObservationInterval: TimeInterval
    var timeout: TimeInterval

    static let conservative = MacFilterSameBootResetConfiguration(
        requiredHealthyConnectivityObservations: 3,
        minimumHealthyObservationInterval: 1,
        timeout: 15
    )
}

/// Safety facts the app must re-check at every asynchronous boundary.
struct MacFilterSameBootResetContext: Equatable, Sendable {
    var applicationSafetyLatchIsSet: Bool
    var blockingIsDisabled: Bool
    var enforcementGeneration: UInt64
    var bootSessionIdentifier: String?
}

/// Result of a fresh `NEFilterManager.loadFromPreferences` operation. Merely
/// seeing `isEnabled == false` is insufficient: provider configuration must
/// also be absent so the disabled filter cannot be relaunched from stale data.
enum MacFilterSameBootResetPreferenceEvidence: Equatable, Sendable {
    case preferenceAbsent
    case disabledAndProviderConfigurationAbsent
    case disabledWithProviderConfiguration
    case enabled
    case unknown
}

/// Covers all work capable of landing a late enabled preference: the bounded
/// quarantine, its final sweep, break-glass removal, and active or queued
/// preference mutations. Quarantine state being nil alone is not proof.
enum MacFilterSameBootResetUncertainWorkEvidence: Equatable, Sendable {
    case confirmedIdle
    case active
    case unknown
}

enum MacFilterSameBootResetConnectivityEvidence: Equatable, Sendable {
    case healthy
    case unhealthy
    case unknown
}

/// A removal callback is only evidence that macOS finished the removal
/// request. Neither callback disposition proves whether a preference exists;
/// both must be followed by an authoritative preference reload.
enum MacFilterSameBootResetRemovalCallbackEvidence: Equatable, Sendable {
    case succeeded
    case returnedError
}

/// Snapshot of every controller lane that can still mutate Network Extension
/// preferences. In particular, an enabled `saveToPreferences` remains active
/// evidence even if a newer break-glass removal has cleared the ordinary
/// mutation lane: the save callback is uncancellable and may still arrive.
struct MacFilterSameBootResetUncertainWorkSnapshot: Equatable, Sendable {
    var lateEnableQuarantineExists: Bool
    var lateEnableQuarantineTaskExists: Bool
    var lateEnableProbeExists: Bool
    var lateEnableProbeDeadlineExists: Bool
    var breakGlassRemovalIsInFlight: Bool
    var activePreferenceMutationExists: Bool
    var pendingPreferenceMutationExists: Bool
    var pendingFinalEnableVerificationExists: Bool
    var configurationOperationCount: Int
    var outstandingEnabledSaveCount: Int
}

struct MacFilterSameBootResetProbeToken: Equatable, Sendable {
    var attemptIdentifier: String
    var enforcementGeneration: UInt64
    var sequence: UInt64
}

/// Correlates the delay, DNS lookup, and HTTPS request that form one health
/// observation. The reset attempt and model token alone are insufficient: a
/// cancelled resolver can still deliver a same-attempt callback after the next
/// observation has begun.
struct MacFilterSameBootResetConnectivityProbeIdentity: Equatable, Sendable {
    var attemptIdentifier: String
    var resetGeneration: UInt64
    var operationIdentifier: String
    var token: MacFilterSameBootResetProbeToken
}

enum MacFilterSameBootResetPreferenceProofStage: Equatable, Sendable {
    case initial
    case final
}

enum MacFilterSameBootResetPhase: Equatable, Sendable {
    case awaitingPreferenceRemovalCallback(MacFilterSameBootResetProbeToken)
    case awaitingInitialPreference(MacFilterSameBootResetProbeToken)
    case awaitingUncertainWork(MacFilterSameBootResetProbeToken)
    case observingConnectivity(
        healthyObservationCount: Int,
        lastHealthyObservationAt: Date?,
        notBefore: Date,
        token: MacFilterSameBootResetProbeToken
    )
    case awaitingFinalPreference(
        connectivityCompletedAt: Date,
        token: MacFilterSameBootResetProbeToken
    )
}

struct MacFilterSameBootResetState: Equatable, Sendable {
    var attemptIdentifier: String
    var enforcementGeneration: UInt64
    var bootSessionIdentifier: String
    var startedAt: Date
    var deadline: Date
    var configuration: MacFilterSameBootResetConfiguration
    var nextProbeSequence: UInt64
    var phase: MacFilterSameBootResetPhase
}

enum MacFilterSameBootResetFailure: Equatable, Sendable {
    case invalidConfiguration
    case invalidAttemptIdentifier
    case missingBootSessionIdentifier
    case applicationSafetyLatchNotSet
    case blockingIsNotDisabled
    case enforcementGenerationChanged
    case bootSessionChanged
    case preferenceEnabled
    case preferenceUnconfirmed
    case providerConfigurationStillPresent
    case uncertainPreferenceWorkActive
    case uncertainPreferenceWorkUnconfirmed
    case connectivityUnconfirmed
    case finalPreferenceProofNotFresh
    case deadlineExceeded
}

/// A durable receipt can retire the app latch (and a same-boot harness latch)
/// but grants no authority to enable or save Network Extension preferences.
struct MacFilterSameBootResetAuthorization: Equatable, Sendable {
    var attemptIdentifier: String
    var enforcementGeneration: UInt64
    var bootSessionIdentifier: String
    var completedAt: Date

    /// Intentionally the sole disposition represented by this receipt.
    var disposition: Disposition {
        .clearApplicationSafetyLatchOnlyWhileRemainingDisabled
    }

    enum Disposition: Equatable, Sendable {
        case clearApplicationSafetyLatchOnlyWhileRemainingDisabled
    }
}

enum MacFilterSameBootResetCommand: Equatable, Sendable {
    case removeNetworkExtensionPreference(token: MacFilterSameBootResetProbeToken)
    case loadNetworkExtensionPreference(
        stage: MacFilterSameBootResetPreferenceProofStage,
        token: MacFilterSameBootResetProbeToken
    )
    case verifyNoUncertainPreferenceWork(token: MacFilterSameBootResetProbeToken)
    case observeConnectivity(
        token: MacFilterSameBootResetProbeToken,
        remainingHealthyObservations: Int,
        notBefore: Date
    )
    case ignoreStaleObservation
    case keepApplicationSafetyLatch(reason: MacFilterSameBootResetFailure)
    case authorized(MacFilterSameBootResetAuthorization)
}

struct MacFilterSameBootResetTransition: Equatable, Sendable {
    var state: MacFilterSameBootResetState?
    var command: MacFilterSameBootResetCommand
}

/// Pure, fail-closed proof state machine for resetting the app-owned safety
/// latch during one boot. It never emits an enable command and continuously
/// requires disabled intent.
enum MacFilterSameBootResetSafety {
    /// Keeps the initial observer alive for one complete cleanup-owner cycle
    /// plus enough slack to see the owner's terminal state on a later poll.
    static func initialCleanupObservationDeadline(
        startedAt: Date,
        ownerCycleBudget: TimeInterval,
        pollSlack: TimeInterval
    ) -> Date {
        let total = ownerCycleBudget + pollSlack
        guard ownerCycleBudget.isFinite,
              ownerCycleBudget > 0,
              pollSlack.isFinite,
              pollSlack >= 0,
              total.isFinite else {
            return startedAt
        }
        return startedAt.addingTimeInterval(total)
    }

    /// Grants at most one full remediation window anchored to the first
    /// orphan-cleanup claim. Callers retain the returned deadline on later
    /// claims by passing `extensionAlreadyUsed == true`.
    static func cleanupDeadlineAfterClaimingOrphanedRedrive(
        currentDeadline: Date,
        claimedAt: Date,
        remediationBudget: TimeInterval,
        extensionAlreadyUsed: Bool
    ) -> Date {
        guard !extensionAlreadyUsed,
              remediationBudget.isFinite,
              remediationBudget > 0 else {
            return currentDeadline
        }
        return max(
            currentDeadline,
            claimedAt.addingTimeInterval(remediationBudget)
        )
    }

    /// Reset may claim an outstanding enabled-save marker only after every
    /// cleanup and preference-mutation lane that could already own it is idle.
    /// Returning `true` starts another bounded quarantine/removal cycle; it
    /// never treats the marker itself as resolved.
    static func shouldRedriveOrphanedEnabledSaveCleanup(
        for snapshot: MacFilterSameBootResetUncertainWorkSnapshot
    ) -> Bool {
        guard snapshot.outstandingEnabledSaveCount > 0,
              snapshot.configurationOperationCount >= 0 else {
            return false
        }
        return !snapshot.lateEnableQuarantineExists
            && !snapshot.lateEnableQuarantineTaskExists
            && !snapshot.lateEnableProbeExists
            && !snapshot.lateEnableProbeDeadlineExists
            && !snapshot.breakGlassRemovalIsInFlight
            && !snapshot.activePreferenceMutationExists
            && !snapshot.pendingPreferenceMutationExists
            && !snapshot.pendingFinalEnableVerificationExists
            && snapshot.configurationOperationCount == 0
    }

    static func uncertainWorkEvidence(
        for snapshot: MacFilterSameBootResetUncertainWorkSnapshot
    ) -> MacFilterSameBootResetUncertainWorkEvidence {
        guard snapshot.configurationOperationCount >= 0,
              snapshot.outstandingEnabledSaveCount >= 0 else {
            return .unknown
        }
        let hasUncertainWork = snapshot.lateEnableQuarantineExists
            || snapshot.lateEnableQuarantineTaskExists
            || snapshot.lateEnableProbeExists
            || snapshot.lateEnableProbeDeadlineExists
            || snapshot.breakGlassRemovalIsInFlight
            || snapshot.activePreferenceMutationExists
            || snapshot.pendingPreferenceMutationExists
            || snapshot.pendingFinalEnableVerificationExists
            || snapshot.configurationOperationCount > 0
            || snapshot.outstandingEnabledSaveCount > 0
        return hasUncertainWork ? .active : .confirmedIdle
    }

    static func acceptsConnectivityCallback(
        identity: MacFilterSameBootResetConnectivityProbeIdentity,
        activeIdentity: MacFilterSameBootResetConnectivityProbeIdentity?
    ) -> Bool {
        identity == activeIdentity
    }

    static func start(
        attemptIdentifier: String,
        context: MacFilterSameBootResetContext,
        now: Date = Date(),
        configuration: MacFilterSameBootResetConfiguration = .conservative
    ) -> MacFilterSameBootResetTransition {
        guard let attemptIdentifier = normalized(attemptIdentifier) else {
            return denied(.invalidAttemptIdentifier)
        }
        guard isValid(configuration) else {
            return denied(.invalidConfiguration)
        }
        guard context.applicationSafetyLatchIsSet else {
            return denied(.applicationSafetyLatchNotSet)
        }
        guard context.blockingIsDisabled else {
            return denied(.blockingIsNotDisabled)
        }
        guard let bootIdentifier = normalized(context.bootSessionIdentifier) else {
            return denied(.missingBootSessionIdentifier)
        }

        let token = MacFilterSameBootResetProbeToken(
            attemptIdentifier: attemptIdentifier,
            enforcementGeneration: context.enforcementGeneration,
            sequence: 1
        )
        let state = MacFilterSameBootResetState(
            attemptIdentifier: attemptIdentifier,
            enforcementGeneration: context.enforcementGeneration,
            bootSessionIdentifier: bootIdentifier,
            startedAt: now,
            deadline: now.addingTimeInterval(configuration.timeout),
            configuration: configuration,
            nextProbeSequence: 2,
            phase: .awaitingPreferenceRemovalCallback(token)
        )
        return MacFilterSameBootResetTransition(
            state: state,
            command: .removeNetworkExtensionPreference(token: token)
        )
    }

    /// A current removal callback advances to an authoritative initial load
    /// regardless of whether `removeFromPreferences` reported success or an
    /// error. In particular, callback success never acts as absence proof, and
    /// callback error never prevents proving an already-absent preference.
    static func recordPreferenceRemovalCallback(
        _ evidence: MacFilterSameBootResetRemovalCallbackEvidence,
        token: MacFilterSameBootResetProbeToken,
        for state: MacFilterSameBootResetState,
        context: MacFilterSameBootResetContext,
        now: Date = Date()
    ) -> MacFilterSameBootResetTransition {
        if let guarded = guardObservation(state, token: token, context: context, now: now) {
            return guarded
        }
        guard case .awaitingPreferenceRemovalCallback(token) = state.phase else {
            return ignored(state)
        }
        switch evidence {
        case .succeeded, .returnedError:
            let (next, nextToken) = advancing(state)
            var awaiting = next
            awaiting.phase = .awaitingInitialPreference(nextToken)
            return MacFilterSameBootResetTransition(
                state: awaiting,
                command: .loadNetworkExtensionPreference(
                    stage: .initial,
                    token: nextToken
                )
            )
        }
    }

    static func recordInitialPreferenceEvidence(
        _ evidence: MacFilterSameBootResetPreferenceEvidence,
        token: MacFilterSameBootResetProbeToken,
        for state: MacFilterSameBootResetState,
        context: MacFilterSameBootResetContext,
        now: Date = Date()
    ) -> MacFilterSameBootResetTransition {
        if let guarded = guardObservation(state, token: token, context: context, now: now) {
            return guarded
        }
        guard case .awaitingInitialPreference(token) = state.phase else {
            return ignored(state)
        }
        guard let failure = preferenceFailure(evidence) else {
            let (next, nextToken) = advancing(state)
            var awaiting = next
            awaiting.phase = .awaitingUncertainWork(nextToken)
            return MacFilterSameBootResetTransition(
                state: awaiting,
                command: .verifyNoUncertainPreferenceWork(token: nextToken)
            )
        }
        return denied(failure)
    }

    static func recordUncertainPreferenceWorkEvidence(
        _ evidence: MacFilterSameBootResetUncertainWorkEvidence,
        token: MacFilterSameBootResetProbeToken,
        for state: MacFilterSameBootResetState,
        context: MacFilterSameBootResetContext,
        now: Date = Date()
    ) -> MacFilterSameBootResetTransition {
        if let guarded = guardObservation(state, token: token, context: context, now: now) {
            return guarded
        }
        guard case .awaitingUncertainWork(token) = state.phase else {
            return ignored(state)
        }
        switch evidence {
        case .active:
            return denied(.uncertainPreferenceWorkActive)
        case .unknown:
            return denied(.uncertainPreferenceWorkUnconfirmed)
        case .confirmedIdle:
            let (next, nextToken) = advancing(state)
            var observing = next
            observing.phase = .observingConnectivity(
                healthyObservationCount: 0,
                lastHealthyObservationAt: nil,
                notBefore: now,
                token: nextToken
            )
            return connectivityCommand(observing)
        }
    }

    static func recordConnectivityEvidence(
        _ evidence: MacFilterSameBootResetConnectivityEvidence,
        token: MacFilterSameBootResetProbeToken,
        for state: MacFilterSameBootResetState,
        context: MacFilterSameBootResetContext,
        now: Date = Date()
    ) -> MacFilterSameBootResetTransition {
        if let guarded = guardObservation(state, token: token, context: context, now: now) {
            return guarded
        }
        guard case let .observingConnectivity(count, lastHealthyAt, notBefore, _) =
                state.phase else {
            return ignored(state)
        }
        guard now >= notBefore else {
            return connectivityCommand(state)
        }

        switch evidence {
        case .unknown:
            return denied(.connectivityUnconfirmed)
        case .unhealthy:
            let (next, nextToken) = advancing(state)
            var reset = next
            let retryAt = now.addingTimeInterval(
                state.configuration.minimumHealthyObservationInterval
            )
            reset.phase = .observingConnectivity(
                healthyObservationCount: 0,
                lastHealthyObservationAt: nil,
                notBefore: retryAt,
                token: nextToken
            )
            return connectivityCommand(reset)
        case .healthy:
            break
        }

        if let lastHealthyAt {
            let requiredDate = lastHealthyAt.addingTimeInterval(
                state.configuration.minimumHealthyObservationInterval
            )
            guard now >= requiredDate else {
                return connectivityCommand(state)
            }
        }

        let newCount = count + 1
        let (next, nextToken) = advancing(state)
        if newCount >= state.configuration.requiredHealthyConnectivityObservations {
            var awaiting = next
            awaiting.phase = .awaitingFinalPreference(
                connectivityCompletedAt: now,
                token: nextToken
            )
            return MacFilterSameBootResetTransition(
                state: awaiting,
                command: .loadNetworkExtensionPreference(stage: .final, token: nextToken)
            )
        }

        var observing = next
        observing.phase = .observingConnectivity(
            healthyObservationCount: newCount,
            lastHealthyObservationAt: now,
            notBefore: now.addingTimeInterval(
                state.configuration.minimumHealthyObservationInterval
            ),
            token: nextToken
        )
        return connectivityCommand(observing)
    }

    /// Completes only when a fresh, post-connectivity preference load proves
    /// disabled/absent and the caller simultaneously confirms that no other
    /// late-enable-capable work remains.
    static func recordFinalPreferenceEvidence(
        _ evidence: MacFilterSameBootResetPreferenceEvidence,
        uncertainWork: MacFilterSameBootResetUncertainWorkEvidence,
        token: MacFilterSameBootResetProbeToken,
        for state: MacFilterSameBootResetState,
        context: MacFilterSameBootResetContext,
        now: Date = Date()
    ) -> MacFilterSameBootResetTransition {
        if let guarded = guardObservation(state, token: token, context: context, now: now) {
            return guarded
        }
        guard case let .awaitingFinalPreference(completedAt, _) = state.phase else {
            return ignored(state)
        }
        guard now > completedAt else {
            return denied(.finalPreferenceProofNotFresh)
        }
        if let failure = preferenceFailure(evidence) {
            return denied(failure)
        }
        switch uncertainWork {
        case .active:
            return denied(.uncertainPreferenceWorkActive)
        case .unknown:
            return denied(.uncertainPreferenceWorkUnconfirmed)
        case .confirmedIdle:
            break
        }

        let authorization = MacFilterSameBootResetAuthorization(
            attemptIdentifier: state.attemptIdentifier,
            enforcementGeneration: state.enforcementGeneration,
            bootSessionIdentifier: state.bootSessionIdentifier,
            completedAt: now
        )
        return MacFilterSameBootResetTransition(
            state: nil,
            command: .authorized(authorization)
        )
    }

    private static func guardObservation(
        _ state: MacFilterSameBootResetState,
        token: MacFilterSameBootResetProbeToken,
        context: MacFilterSameBootResetContext,
        now: Date
    ) -> MacFilterSameBootResetTransition? {
        guard token == expectedToken(in: state.phase) else {
            return ignored(state)
        }
        guard context.applicationSafetyLatchIsSet else {
            return denied(.applicationSafetyLatchNotSet)
        }
        guard context.blockingIsDisabled else {
            return denied(.blockingIsNotDisabled)
        }
        guard context.enforcementGeneration == state.enforcementGeneration else {
            return denied(.enforcementGenerationChanged)
        }
        guard normalized(context.bootSessionIdentifier) == state.bootSessionIdentifier else {
            return denied(.bootSessionChanged)
        }
        guard now < state.deadline else {
            return denied(.deadlineExceeded)
        }
        return nil
    }

    private static func preferenceFailure(
        _ evidence: MacFilterSameBootResetPreferenceEvidence
    ) -> MacFilterSameBootResetFailure? {
        switch evidence {
        case .preferenceAbsent, .disabledAndProviderConfigurationAbsent:
            return nil
        case .disabledWithProviderConfiguration:
            return .providerConfigurationStillPresent
        case .enabled:
            return .preferenceEnabled
        case .unknown:
            return .preferenceUnconfirmed
        }
    }

    private static func advancing(
        _ state: MacFilterSameBootResetState
    ) -> (MacFilterSameBootResetState, MacFilterSameBootResetProbeToken) {
        var next = state
        let token = MacFilterSameBootResetProbeToken(
            attemptIdentifier: state.attemptIdentifier,
            enforcementGeneration: state.enforcementGeneration,
            sequence: state.nextProbeSequence
        )
        next.nextProbeSequence &+= 1
        return (next, token)
    }

    private static func connectivityCommand(
        _ state: MacFilterSameBootResetState
    ) -> MacFilterSameBootResetTransition {
        guard case let .observingConnectivity(count, _, notBefore, token) = state.phase else {
            preconditionFailure("Connectivity command requires connectivity phase")
        }
        return MacFilterSameBootResetTransition(
            state: state,
            command: .observeConnectivity(
                token: token,
                remainingHealthyObservations:
                    state.configuration.requiredHealthyConnectivityObservations - count,
                notBefore: notBefore
            )
        )
    }

    private static func expectedToken(
        in phase: MacFilterSameBootResetPhase
    ) -> MacFilterSameBootResetProbeToken {
        switch phase {
        case let .awaitingPreferenceRemovalCallback(token),
             let .awaitingInitialPreference(token),
             let .awaitingUncertainWork(token),
             let .observingConnectivity(_, _, _, token),
             let .awaitingFinalPreference(_, token):
            return token
        }
    }

    private static func isValid(
        _ configuration: MacFilterSameBootResetConfiguration
    ) -> Bool {
        let observations = configuration.requiredHealthyConnectivityObservations
        let interval = configuration.minimumHealthyObservationInterval
        let timeout = configuration.timeout
        guard observations >= 2,
              interval.isFinite,
              interval > 0,
              timeout.isFinite,
              timeout > 0 else {
            return false
        }
        let minimumProofDuration = Double(observations - 1) * interval
        return minimumProofDuration.isFinite && minimumProofDuration < timeout
    }

    private static func ignored(
        _ state: MacFilterSameBootResetState
    ) -> MacFilterSameBootResetTransition {
        MacFilterSameBootResetTransition(state: state, command: .ignoreStaleObservation)
    }

    private static func denied(
        _ reason: MacFilterSameBootResetFailure
    ) -> MacFilterSameBootResetTransition {
        MacFilterSameBootResetTransition(
            state: nil,
            command: .keepApplicationSafetyLatch(reason: reason)
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
