import Foundation

/// One device's contribution to a rule's shared temporary-access spend.
///
/// Every device writes only its own entry and readers sum the rest, so two
/// devices pausing at once cannot lose each other's spend. Absence of an entry
/// contributes nothing, which is also what makes a stale or empty read safe:
/// it can only ever forget spend that a later sync restores, never invent it.
struct TemporaryAccessContribution: Codable, Equatable, Sendable {
    var deviceID: UUID
    var ruleID: UUID
    /// Minutes granted on this device during its current contiguous pause.
    var minutesGranted: Int
    /// When this device's pause ends. Spend stops counting past it, mirroring
    /// the local rule that a session resets once the allowance expires.
    var pauseEndsAt: Date
    /// Grants counted towards passage escalation. This has its own window,
    /// independent of whether a pause is still running.
    var backoffGrants: Int
    var backoffStartedAt: Date
    var updatedAt: Date
    var sessionGrantCount: Int? = nil
}

/// The shared view of how much temporary access has been spent.
///
/// The latest authorization or cancellation also controls the shared pause.
/// Devices retain their own enforcement records and expiry monitors.
struct TemporaryAccessLedger: Codable, Equatable, Sendable {
    /// Keyed by rule and device, so a write only ever touches one entry.
    var contributions: [String: TemporaryAccessContribution] = [:]

    func additionalCommittedMinutes(forRule rule: UUID, localMinutes: Int, at now: Date) -> Int {
        let latest = contributions.values.filter { $0.ruleID == rule }.max {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.deviceID.uuidString < $1.deviceID.uuidString
        }
        guard let latest, latest.pauseEndsAt > now else { return 0 }
        return max(0, latest.minutesGranted - localMinutes)
    }

    static func key(rule: UUID, device: UUID) -> String {
        "\(rule.uuidString):\(device.uuidString)"
    }

    /// Later writes win per entry, and a key missing from `incoming` is left
    /// alone. A device that has been offline for a week must not erase what the
    /// others recorded while it was away.
    mutating func merge(_ incoming: Self, at now: Date) {
        for (key, entry) in incoming.contributions {
            guard key == Self.key(rule: entry.ruleID, device: entry.deviceID) else { continue }
            if let existing = contributions[key], existing.updatedAt >= entry.updatedAt { continue }
            contributions[key] = entry
        }
        prune(at: now)
    }

    /// Minutes other devices currently hold against this rule.
    ///
    /// `excluding` is the calling device: its own spend is already tracked
    /// locally and more precisely than its published copy, so counting the
    /// published entry too would double it.
    func committedMinutes(forRule rule: UUID, excluding device: UUID, at now: Date) -> Int {
        entries(forRule: rule, excluding: device)
            .filter { $0.pauseEndsAt > now }
            .reduce(0) { $0 + max(0, $1.minutesGranted) }
    }

    /// Grants other devices have made inside the backoff window.
    func backoffGrants(
        forRule rule: UUID,
        excluding device: UUID,
        resetDays: Int,
        at now: Date
    ) -> Int {
        let window = Double(min(365, max(1, resetDays))) * 86_400
        return entries(forRule: rule, excluding: device)
            .filter { now < $0.backoffStartedAt.addingTimeInterval(window) }
            .reduce(0) { $0 + max(0, $1.backoffGrants) }
    }

    /// Records this device's current position. Called after a grant, and again
    /// when a pause is cancelled so the minutes stop counting against others.
    mutating func record(_ contribution: TemporaryAccessContribution) {
        contributions[Self.key(rule: contribution.ruleID, device: contribution.deviceID)] = contribution
    }

    mutating func clear(rule: UUID, device: UUID) {
        contributions.removeValue(forKey: Self.key(rule: rule, device: device))
    }

    /// Entries stop mattering once both their pause and the longest possible
    /// backoff window have lapsed. Pruning keeps the cloud payload bounded
    /// without discarding anything still capable of counting.
    mutating func prune(at now: Date) {
        let longestBackoff = Double(TemporaryAllowanceBackoff.daysRange.upperBound) * 86_400
        contributions = contributions.filter { _, entry in
            entry.pauseEndsAt > now
                || now < entry.backoffStartedAt.addingTimeInterval(longestBackoff)
        }
    }

    private func entries(forRule rule: UUID, excluding device: UUID) -> [TemporaryAccessContribution] {
        contributions.values.filter { $0.ruleID == rule && $0.deviceID != device }
    }
}
