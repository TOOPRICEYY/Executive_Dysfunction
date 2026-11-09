import Foundation

/// Identifies one serialized settings operation inside one provider lifetime.
/// Network Extension settings callbacks can arrive after a disable, extension
/// replacement, or policy refresh; accepting one of those stale callbacks can
/// otherwise reinstall rules after the operation that owned them has ended.
struct MacFilterSettingsOperationToken: Equatable, Sendable {
    fileprivate var lifecycleGeneration: UInt64
    fileprivate var operationGeneration: UInt64
}

/// Pure, lock-agnostic lifecycle state used by `MacWebFilterProvider` under its
/// settings lock. Only one operation may be in flight, which prevents an older
/// asynchronous `apply` completion from racing a newer policy into the system.
struct MacFilterSettingsLifecycle: Equatable, Sendable {
    private(set) var isRunning = false
    private(set) var hasOperationInFlight = false
    private var lifecycleGeneration: UInt64 = 0
    private var operationGeneration: UInt64 = 0

    mutating func startProvider() -> MacFilterSettingsOperationToken {
        lifecycleGeneration &+= 1
        operationGeneration &+= 1
        isRunning = true
        hasOperationInFlight = true
        return currentToken
    }

    mutating func beginOperation() -> MacFilterSettingsOperationToken? {
        guard isRunning, !hasOperationInFlight else { return nil }
        operationGeneration &+= 1
        hasOperationInFlight = true
        return currentToken
    }

    func accepts(_ token: MacFilterSettingsOperationToken) -> Bool {
        isRunning
            && hasOperationInFlight
            && token.lifecycleGeneration == lifecycleGeneration
            && token.operationGeneration == operationGeneration
    }

    @discardableResult
    mutating func finish(_ token: MacFilterSettingsOperationToken) -> Bool {
        guard accepts(token) else { return false }
        hasOperationInFlight = false
        return true
    }

    mutating func stopProvider() {
        isRunning = false
        hasOperationInFlight = false
        lifecycleGeneration &+= 1
        operationGeneration &+= 1
    }

    private var currentToken: MacFilterSettingsOperationToken {
        MacFilterSettingsOperationToken(
            lifecycleGeneration: lifecycleGeneration,
            operationGeneration: operationGeneration
        )
    }
}

enum MacFilterStopApplyAction: Equatable, Sendable {
    case none
    case applyFinalBypass
    case finishStop
}

/// Orders the physical calls already handed to Network Extension. Logical
/// generation checks can suppress stale bookkeeping, but they cannot cancel an
/// `apply` the OS has already accepted. Stop therefore drains those calls,
/// applies one final allow-all plan, and only then completes provider shutdown.
struct MacFilterPhysicalApplyState: Equatable, Sendable {
    private(set) var logicalAppliesInFlight = 0
    private(set) var isStopRequested = false
    private(set) var isFinalBypassInFlight = false

    mutating func reset() {
        logicalAppliesInFlight = 0
        isStopRequested = false
        isFinalBypassInFlight = false
    }

    mutating func beginLogicalApply(isCurrent: Bool) -> Bool {
        guard isCurrent, !isStopRequested else { return false }
        logicalAppliesInFlight += 1
        return true
    }

    mutating func requestStop() -> MacFilterStopApplyAction {
        isStopRequested = true
        return beginFinalBypassIfDrained()
    }

    mutating func logicalApplyFinished() -> MacFilterStopApplyAction {
        if logicalAppliesInFlight > 0 {
            logicalAppliesInFlight -= 1
        }
        return beginFinalBypassIfDrained()
    }

    mutating func finalBypassFinished() -> MacFilterStopApplyAction {
        guard isStopRequested, isFinalBypassInFlight else { return .none }
        isFinalBypassInFlight = false
        return .finishStop
    }

    private mutating func beginFinalBypassIfDrained() -> MacFilterStopApplyAction {
        guard isStopRequested,
              logicalAppliesInFlight == 0,
              !isFinalBypassInFlight else { return .none }
        isFinalBypassInFlight = true
        return .applyFinalBypass
    }
}
