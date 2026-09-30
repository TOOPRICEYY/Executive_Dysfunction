import Foundation

/// Decides what to do when the content-filter preference is found switched off
/// while Holdfast still intends to enforce, i.e. someone used System Settings
/// rather than the app's passage-gated disable.
///
/// It never re-enables immediately: the most likely honest reason to use System
/// Settings is a network outage, and snapping the filter straight back would
/// recreate it. Instead the event is journaled and the filter is re-armed after
/// a grace period, which turns a permanent off-switch into a short pause.
/// The app's own passage disable remains the way to stay off.
enum ExternalFilterToggleGate {
    static let reenableGrace: TimeInterval = 15 * 60

    struct Inputs: Equatable {
        var appIntendsEnforcement: Bool
        var mutationInFlight: Bool
        var preferenceEnabled: Bool
        var firstObservedOffAt: Date?
    }

    enum Action: Equatable {
        case none
        /// Newly noticed: record it and schedule a re-check at the given time.
        case recordAndSchedule(reenableAt: Date)
        /// Still off after the grace period: turn enforcement back on.
        case reenable
        /// The preference is on again (or the app no longer wants it on).
        case clear
    }

    static func decide(_ inputs: Inputs, at now: Date) -> Action {
        guard inputs.appIntendsEnforcement, !inputs.mutationInFlight else {
            return inputs.firstObservedOffAt == nil ? .none : .clear
        }
        if inputs.preferenceEnabled {
            return inputs.firstObservedOffAt == nil ? .none : .clear
        }
        guard let since = inputs.firstObservedOffAt else {
            return .recordAndSchedule(reenableAt: now.addingTimeInterval(reenableGrace))
        }
        return now.timeIntervalSince(since) >= reenableGrace ? .reenable : .none
    }
}
