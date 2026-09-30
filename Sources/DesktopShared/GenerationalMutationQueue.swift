import Foundation

/// Anything whose staleness is decided by a monotonically increasing number.
protocol GenerationStamped {
    var generation: UInt64 { get }
}

/// The single-flight, latest-wins queue behind every Network Extension
/// preference change.
///
/// Network Extension preferences offer asynchronous load/save with no
/// cancellation, so exactly one mutation may be in flight. A newer request
/// never interrupts it; it replaces whatever is waiting, and whichever request
/// is newest when the in-flight one finishes runs next. A completion whose
/// generation is no longer current is stale and must not be acted on.
///
/// This is the first piece of `MacEnforcementController` moved into a pure
/// value type: the controller keeps its original property names as views onto
/// this state, so behavior is unchanged while the rules become testable.
struct GenerationalMutationQueue<Mutation: GenerationStamped> {
    /// The newest generation handed out. Settable so existing call sites that
    /// bump it directly keep working during the migration.
    var generation: UInt64 = 0
    var active: Mutation?
    var pending: Mutation?

    /// Reserves the next generation for a new mutation.
    mutating func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Latest wins: replaces any waiting mutation. Returns the generation it
    /// replaced (0 when nothing was waiting).
    @discardableResult
    mutating func enqueue(_ mutation: Mutation) -> UInt64 {
        let replaced = pending?.generation ?? 0
        pending = mutation
        return replaced
    }

    /// Moves the waiting mutation into flight when nothing else is running.
    /// Returns it so the caller can perform it; nil means keep waiting.
    mutating func startNextIfIdle() -> Mutation? {
        guard active == nil, let mutation = pending else { return nil }
        pending = nil
        active = mutation
        return mutation
    }

    /// Clears the in-flight mutation after its completion was handled.
    mutating func finishActive() {
        active = nil
    }

    func isCurrent(_ mutation: Mutation) -> Bool {
        mutation.generation == generation
    }

    var isBusy: Bool {
        active != nil || pending != nil
    }
}
