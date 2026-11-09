import SwiftUI

/// Drives the session-maximum control.
///
/// The maximum is stored in minutes so a group can permit a genuinely short
/// bypass, but a one-minute step would take hundreds of presses to cross eight
/// hours. The control therefore moves through `TimeAllowancePolicy`'s ladder:
/// single minutes where the choice is delicate, coarser rungs above an hour.
func maximumTemporaryAccessLadder(
    _ policy: Binding<CloudRuleLockdownPreference>
) -> Binding<Int> {
    Binding(
        get: {
            TimeAllowancePolicy.ladderIndex(
                forMinutes: policy.wrappedValue.effectiveMaximumTemporaryAccessMinutes
            )
        },
        set: { index in
            let ladder = TimeAllowancePolicy.maximumMinutesLadder
            let position = min(max(0, index), ladder.count - 1)
            policy.wrappedValue.setMaximumTemporaryAccess(minutes: ladder[position])
        }
    )
}

/// The same control over the compiled rule's own policy type.
func maximumTemporaryAccessLadder(
    _ policy: Binding<RuleLockdownPolicy>
) -> Binding<Int> {
    Binding(
        get: {
            TimeAllowancePolicy.ladderIndex(
                forMinutes: policy.wrappedValue.effectiveMaximumTemporaryAccessMinutes
            )
        },
        set: { index in
            let ladder = TimeAllowancePolicy.maximumMinutesLadder
            let position = min(max(0, index), ladder.count - 1)
            policy.wrappedValue.setMaximumTemporaryAccess(minutes: ladder[position])
        }
    )
}

extension TimeAllowancePolicy {
    static var maximumLadderRange: ClosedRange<Int> {
        0...(maximumMinutesLadder.count - 1)
    }
}
