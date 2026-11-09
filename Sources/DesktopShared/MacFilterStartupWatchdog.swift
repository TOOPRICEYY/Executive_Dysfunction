import Foundation

/// One Network Extension preference write that is expected to produce a fresh,
/// fully-ready provider. The containing app evaluates this independently of the
/// provider so delayed readiness can be reported even when it cannot publish.
struct MacFilterStartupWatchdogAttempt: Equatable, Sendable {
    var preferenceGeneration: UInt64
    var expectedRevision: UInt64
    var expectedProviderBuild: String
    var notBefore: Date
    var deadline: Date
    var baselineSessionID: String?
    /// A changed preference restarts the provider and must produce a new
    /// session. An unchanged preference may keep the existing provider; in that
    /// case a fresh, ready heartbeat after `notBefore` is sufficient.
    var requiresFreshProviderStart: Bool = true
}

enum MacFilterStartupWatchdogAction: Equatable, Sendable {
    case wait
    case satisfied
    case cancel
    case reportFailure
}

enum MacFilterStaleHeartbeatAction: String, Equatable, Sendable {
    case ignoreWhileDisabled = "ignore-while-disabled"
    case deferToStartupWatchdog = "defer-to-startup-watchdog"
    case observeWithoutPreferenceMutation = "observe-without-preference-mutation"
}

enum MacFilterStartupWatchdog {
    /// Readiness is diagnostic evidence, not permission to remove a filter.
    /// Allow slower activation/updates before showing a recovery warning.
    static let readinessDeadline: TimeInterval = 30

    /// A ready provider's process may be suspended while no matching flow needs
    /// it. Its Dispatch timer pauses too, so a stale file alone cannot authorize
    /// removing the live Network Extension preference. Startup delays also only
    /// report a warning; neither kind of missing telemetry authorizes removal.
    static func staleHeartbeatAction(
        isBlockingDisabled: Bool,
        startupTransitionInProgress: Bool
    ) -> MacFilterStaleHeartbeatAction {
        if isBlockingDisabled { return .ignoreWhileDisabled }
        if startupTransitionInProgress { return .deferToStartupWatchdog }
        return .observeWithoutPreferenceMutation
    }

    static func action(
        for attempt: MacFilterStartupWatchdogAttempt,
        currentPreferenceGeneration: UInt64,
        wantsEnabled: Bool,
        status: FilterEnforcementStatus?,
        now: Date = Date()
    ) -> MacFilterStartupWatchdogAction {
        guard wantsEnabled,
              currentPreferenceGeneration == attempt.preferenceGeneration else {
            return .cancel
        }

        if provesReady(status, for: attempt) {
            return .satisfied
        }
        return now >= attempt.deadline ? .reportFailure : .wait
    }

    private static func provesReady(
        _ status: FilterEnforcementStatus?,
        for attempt: MacFilterStartupWatchdogAttempt
    ) -> Bool {
        guard let status,
              status.updatedAt >= attempt.notBefore,
              status.revision == attempt.expectedRevision,
              let diagnostics = status.diagnostics,
              diagnostics.providerBuild == attempt.expectedProviderBuild,
              diagnostics.heartbeatSequence >= 1,
              !diagnostics.sessionID.isEmpty,
              (status.macFilterSettings?.isReady == true || status.macFilterSettings?.isFiltering == true),
              status.macFilterSettings?.appliedPolicyRevision == status.revision else {
            return false
        }
        if attempt.requiresFreshProviderStart {
            guard diagnostics.providerStartedAt >= attempt.notBefore else { return false }
            if let baseline = attempt.baselineSessionID, !baseline.isEmpty {
                return diagnostics.sessionID != baseline
            }
        }
        return true
    }
}
