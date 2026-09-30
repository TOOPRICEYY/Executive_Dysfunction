import Foundation

/// Applies a locked rule's own waiting period on the Mac to weakenings that
/// arrive without passing the Mac's lock: an edit synced from the iPhone, a
/// hand-written iCloud value, or an Activity Group change that loosens a
/// locked Blocking Group.
///
/// Local edits that completed this Mac's unlock carry a signed weakening
/// authorization and are never held. Everything else is compared, rule by
/// rule, with what the filter is enforcing now. A weakened locked rule keeps
/// its previous (stricter) form until its unlock delay has elapsed since the
/// weakening was first seen; then the new form is applied. Passage-only and
/// unlocked rules are never held, because the Mac would not make you wait for
/// them either.
enum RemoteWeakeningHold {
    struct Result: Equatable {
        var rules: [DesktopEnforcementRule]
        /// Rule ID → when the pending weakening was first seen.
        var holds: [UUID: Date]
        var held: [HeldWeakening]
    }

    struct HeldWeakening: Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var appliesAt: Date
    }

    static func holdDuration(for lockdown: DesktopLockdownPolicy) -> TimeInterval {
        switch lockdown.severity {
        case "none", "passageOnly": 0
        default: TimeInterval(max(0, lockdown.unlockDelayDays)) * 86_400
        }
    }

    static func apply(
        previous: [DesktopEnforcementRule],
        proposed: [DesktopEnforcementRule],
        exempt: Set<UUID>,
        holds: [UUID: Date],
        now: Date
    ) -> Result {
        var rules = proposed
        var nextHolds: [UUID: Date] = [:]
        var held: [HeldWeakening] = []
        let proposedIndex = Dictionary(
            proposed.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        for old in previous where !exempt.contains(old.id) {
            // A Retreat group that has not started yet enforces nothing; its
            // Retreat's own change policy governs edits before it begins.
            if let start = old.activeFrom, start > now { continue }
            let duration = holdDuration(for: old.lockdown)
            guard duration > 0 else { continue }
            let index = proposedIndex[old.id]
            let replacement = index.map { proposed[$0] }
            let weakened = replacement.map {
                !DesktopPolicyRestrictionEvaluator.isSameOrStricter(old: old, new: $0)
            } ?? true
            guard weakened else { continue }

            let since = min(holds[old.id] ?? now, now)
            let appliesAt = since.addingTimeInterval(duration)
            guard now < appliesAt else { continue }

            var kept = old
            // Pauses have their own gate; keep whatever the ledger says now.
            kept.pausedUntil = replacement?.pausedUntil
            kept.pauseSessionStartedAt = nil
            if let index {
                rules[index] = kept
            } else {
                rules.append(kept)
            }
            nextHolds[old.id] = since
            held.append(HeldWeakening(id: old.id, name: old.name, appliesAt: appliesAt))
        }
        return Result(rules: rules, holds: nextHolds, held: held.sorted { $0.appliesAt < $1.appliesAt })
    }
}
