import Foundation

/// Pure scheduling state for the bounded period during which an uncertain
/// enabled-preference save may still complete after its caller timed out.
///
/// A successful verification/removal does not end the quarantine: the original
/// uncancellable save may land later, so the containing app keeps checking until
/// `deadline`. The record is intentionally boot- and generation-bound.
struct MacFilterLateEnableQuarantineState: Equatable, Sendable {
    var generation: UInt64
    var bootSessionIdentifier: String?
    var startedAt: Date
    var deadline: Date
    var retryInterval: TimeInterval
    var nextAttemptAt: Date
    var nextAttemptSequence: UInt64
    var activeAttemptSequence: UInt64?
}

enum MacFilterLateEnableQuarantineCommand: Equatable, Sendable {
    case wait(until: Date)
    case verifyAndRemove(attemptSequence: UInt64)
    case ignoreStaleAttempt
    case cancel
    case finished
}

struct MacFilterLateEnableQuarantineTransition: Equatable, Sendable {
    var state: MacFilterLateEnableQuarantineState?
    var command: MacFilterLateEnableQuarantineCommand
}

enum MacFilterLateEnableQuarantineSafety {
    static func start(
        generation: UInt64,
        bootSessionIdentifier: String?,
        now: Date = Date(),
        gracePeriod: TimeInterval,
        retryInterval: TimeInterval
    ) -> MacFilterLateEnableQuarantineState? {
        guard gracePeriod.isFinite,
              gracePeriod > 0,
              retryInterval.isFinite,
              retryInterval > 0 else {
            return nil
        }
        return MacFilterLateEnableQuarantineState(
            generation: generation,
            bootSessionIdentifier: normalized(bootSessionIdentifier),
            startedAt: now,
            deadline: now.addingTimeInterval(gracePeriod),
            retryInterval: retryInterval,
            nextAttemptAt: now,
            nextAttemptSequence: 1,
            activeAttemptSequence: nil
        )
    }

    /// Advances the scheduler and claims at most one verification/removal
    /// attempt. Callers must retain the returned state before starting work.
    static func advance(
        _ state: MacFilterLateEnableQuarantineState,
        currentGeneration: UInt64,
        currentBootSessionIdentifier: String?,
        stillWantsDisabled: Bool,
        now: Date = Date()
    ) -> MacFilterLateEnableQuarantineTransition {
        guard currentGeneration == state.generation, stillWantsDisabled else {
            return MacFilterLateEnableQuarantineTransition(state: nil, command: .cancel)
        }
        guard isSameBoot(state, currentBootSessionIdentifier) else {
            return MacFilterLateEnableQuarantineTransition(state: nil, command: .finished)
        }
        guard now < state.deadline else {
            return MacFilterLateEnableQuarantineTransition(state: nil, command: .finished)
        }
        if state.activeAttemptSequence != nil {
            return MacFilterLateEnableQuarantineTransition(
                state: state,
                command: .wait(until: state.deadline)
            )
        }
        guard now >= state.nextAttemptAt else {
            return MacFilterLateEnableQuarantineTransition(
                state: state,
                command: .wait(until: min(state.nextAttemptAt, state.deadline))
            )
        }

        var claimed = state
        let sequence = claimed.nextAttemptSequence
        claimed.activeAttemptSequence = sequence
        claimed.nextAttemptSequence &+= 1
        return MacFilterLateEnableQuarantineTransition(
            state: claimed,
            command: .verifyAndRemove(attemptSequence: sequence)
        )
    }

    /// Accepts either success, failure, or a per-attempt timeout. All outcomes
    /// schedule another check because none can cancel the original late save.
    static func completeAttempt(
        _ state: MacFilterLateEnableQuarantineState,
        attemptSequence: UInt64,
        currentGeneration: UInt64,
        currentBootSessionIdentifier: String?,
        stillWantsDisabled: Bool,
        now: Date = Date()
    ) -> MacFilterLateEnableQuarantineTransition {
        guard currentGeneration == state.generation,
              stillWantsDisabled,
              state.activeAttemptSequence == attemptSequence else {
            return MacFilterLateEnableQuarantineTransition(
                state: state,
                command: .ignoreStaleAttempt
            )
        }
        guard isSameBoot(state, currentBootSessionIdentifier), now < state.deadline else {
            return MacFilterLateEnableQuarantineTransition(state: nil, command: .finished)
        }

        var completed = state
        completed.activeAttemptSequence = nil
        completed.nextAttemptAt = min(
            now.addingTimeInterval(completed.retryInterval),
            completed.deadline
        )
        return MacFilterLateEnableQuarantineTransition(
            state: completed,
            command: .wait(until: completed.nextAttemptAt)
        )
    }

    /// An enable path must consult this gate before loading or saving an
    /// enabled preference. Quarantine wins over a new enable request until its
    /// bounded same-boot lifetime ends or its owner explicitly changes state.
    static func allowsEnabledPreference(
        during state: MacFilterLateEnableQuarantineState?,
        currentGeneration: UInt64,
        currentBootSessionIdentifier: String?,
        now: Date = Date()
    ) -> Bool {
        guard let state,
              state.generation == currentGeneration,
              isSameBoot(state, currentBootSessionIdentifier),
              now < state.deadline else {
            return true
        }
        return false
    }

    private static func isSameBoot(
        _ state: MacFilterLateEnableQuarantineState,
        _ currentIdentifier: String?
    ) -> Bool {
        let currentIdentifier = normalized(currentIdentifier)
        if let recorded = state.bootSessionIdentifier, let currentIdentifier {
            return recorded == currentIdentifier
        }
        // Missing UUID evidence is ambiguous. Keeping the short quarantine is
        // safer than allowing an uncertain late save to re-enable the filter.
        return true
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
