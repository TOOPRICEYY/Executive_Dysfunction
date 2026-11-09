import Foundation

/// The kind of Network Extension preference mutation whose asynchronous
/// load/save operation exceeded its deadline.
enum MacFilterPreferenceTimeoutTarget: Equatable, Sendable {
    case enable
    case preparationSuspension
    case explicitDisable
}

/// Availability-first recovery selected for one preference-operation timeout.
enum MacFilterPreferenceTimeoutAction: Equatable, Sendable {
    /// The deadline no longer owns the active preference operation.
    case ignoreStaleOperation
    /// No write was submitted. Fence the late read callback and retry within
    /// the normal retry budget; never remove the filter or persist a latch.
    case retryReadOnlyOperation
    /// Persist the emergency-disabled state before enqueueing the ordinary
    /// disable path, so an app relaunch cannot silently enable the filter.
    case persistEmergencyDisable
    /// The ordinary disable itself stopped responding. Remove only the Network
    /// Extension preference and retry the reversible disable operation.
    case removePreferenceAndRetryDisable
}

/// Pure generation fence and recovery decision for Network Extension
/// preference callbacks, which the framework does not make cancellable.
enum MacFilterPreferenceTimeoutSafety {
    enum Stage: String, Sendable {
        case loading
        case verifyingExtension
        case saving

        var deadline: TimeInterval { self == .saving ? 8 : 30 }
    }

    static func action(
        timedOutGeneration: UInt64,
        currentPreferenceGeneration: UInt64,
        armedDeadlineGeneration: UInt64?,
        activeMutationGeneration: UInt64?,
        currentlyWantsDisabled: Bool,
        target: MacFilterPreferenceTimeoutTarget,
        stage: Stage = .saving,
        hasOutstandingEnabledSave: Bool = false
    ) -> MacFilterPreferenceTimeoutAction {
        guard timedOutGeneration == armedDeadlineGeneration,
              timedOutGeneration == activeMutationGeneration else {
            return .ignoreStaleOperation
        }

        // A slow load/properties query cannot commit an enabled preference.
        // Explicit disable still needs bounded emergency cleanup, and any
        // genuinely outstanding enabled write must keep its quarantine.
        if stage != .saving, !hasOutstandingEnabledSave,
           !currentlyWantsDisabled, target != .explicitDisable {
            return .retryReadOnlyOperation
        }

        // A newer desired state can be queued behind an older framework call.
        // That does not make the old deadline ignorable: leaving it as the
        // active owner would strand the newer operation forever. Prefer a
        // persisted emergency disable whenever the wedged operation has been
        // superseded, regardless of what that older operation was doing.
        guard timedOutGeneration == currentPreferenceGeneration else {
            return currentlyWantsDisabled
                ? .removePreferenceAndRetryDisable
                : .persistEmergencyDisable
        }

        switch target {
        case .enable, .preparationSuspension:
            return .persistEmergencyDisable
        case .explicitDisable:
            return .removePreferenceAndRetryDisable
        }
    }

    static func shouldRetryExplicitDisable(
        completedRetries: Int,
        maximumRetries: Int
    ) -> Bool {
        completedRetries >= 0
            && maximumRetries > 0
            && completedRetries < maximumRetries
    }

    static func acceptsBreakGlassCompletion(
        operationID: String,
        activeOperationID: String?,
        stillWantsDisabled: Bool
    ) -> Bool {
        !operationID.isEmpty
            && operationID == activeOperationID
            && stillWantsDisabled
    }
}

/// Determines whether the block-page daemon may still have managed loopback
/// host mappings installed for the last status published by the filter.
enum MacFilterBlockPageHostMappingSafety {
    static func mayStillBePresent(
        status: FilterEnforcementStatus?,
        now: Date = Date(),
        freshness: TimeInterval
    ) -> Bool {
        guard freshness.isFinite,
              freshness >= 0,
              let status,
              status.hasActiveWebRestrictions else {
            return false
        }
        let age = now.timeIntervalSince(status.updatedAt)
        return age.isFinite && age >= 0 && age <= freshness
    }
}
