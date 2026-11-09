import Foundation

extension TemporaryAccessLedger {
    /// A pause is shared by the person, including explicit cancellation. Use
    /// the latest authorization, never restart its timer on the receiving device.
    func applyingSharedPauses(
        to local: [UUID: RuleTimeAllowance], device: UUID,
        maximumMinutes: [UUID: Int], at now: Date
    ) -> [UUID: RuleTimeAllowance] {
        var result = local
        let grouped = Dictionary(grouping: contributions.values, by: \.ruleID)
        for (rule, entries) in grouped {
            let latest = entries.max {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.deviceID.uuidString < $1.deviceID.uuidString
            }!
            guard latest.deviceID != device else { continue }
            guard let maximum = maximumMinutes[rule], maximum > 0 else { continue }
            let expiry = min(latest.pauseEndsAt, latest.updatedAt.addingTimeInterval(Double(maximum) * 60))
            guard latest.minutesGranted > 0, latest.minutesGranted <= maximum, expiry > now else {
                result[rule] = nil
                continue
            }
            result[rule] = RuleTimeAllowance(
                ruleID: rule, expiresAt: expiry,
                totalMinutesGranted: latest.minutesGranted,
                grantCount: max(1, latest.sessionGrantCount ?? latest.backoffGrants),
                restoreUsageShield: local[rule]?.restoreUsageShield ?? false
            )
        }
        return result
    }

}
