import Foundation

extension TemporaryAccessLedger {
    /// A pause is shared by the person, including explicit cancellation. Use
    /// the latest authorization, never restart its timer on the receiving device.
    func applyingSharedPauses(
        to local: [UUID: RuleTimeAllowance], device: UUID,
        maximumMinutes: [UUID: Int], waitMinutes: [UUID: Int] = [:], at now: Date
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
            var opensAt: Date? = nil
            var expiry = min(latest.pauseEndsAt, latest.updatedAt.addingTimeInterval(Double(maximum) * 60))
            if latest.isPendingRecord, let opening = latest.pauseOpensAt, let end = latest.pendingPauseEndsAt {
                // Never earlier than this device's own wait from the moment
                // the grant was made, nor later than a day after it.
                let ownWait = Double(TemporaryAccessWait.clamped(waitMinutes[rule] ?? 0)) * 60
                let floor = latest.updatedAt.addingTimeInterval(ownWait)
                guard opening <= latest.updatedAt.addingTimeInterval(Double(TemporaryAccessWait.range.upperBound) * 60 + 5) else {
                    result[rule] = nil
                    continue
                }
                let start = max(opening, floor)
                opensAt = start
                expiry = min(end, start.addingTimeInterval(Double(maximum) * 60))
            }
            guard latest.minutesGranted > 0, latest.minutesGranted <= maximum, expiry > now,
                  opensAt.map({ expiry > $0 }) ?? true else {
                result[rule] = nil
                continue
            }
            result[rule] = RuleTimeAllowance(
                ruleID: rule, expiresAt: expiry,
                totalMinutesGranted: latest.minutesGranted,
                grantCount: max(1, latest.sessionGrantCount ?? latest.backoffGrants),
                restoreUsageShield: local[rule]?.restoreUsageShield ?? false,
                opensAt: opensAt
            )
        }
        return result
    }
}

extension ICloudTemporaryAccessStore {
    /// Publishes this device's allowance for one rule, pending or open.
    ///
    /// A pending allowance is written so a build without waits cannot open
    /// it: its `pauseEndsAt` is `now`, which such a reader treats as no pause,
    /// while the real window travels in `pauseOpensAt` / `pendingPauseEndsAt`.
    /// The spend (minutes, backoff) is charged now, as for an open grant.
    @discardableResult
    func record(
        rule: UUID,
        allowance: RuleTimeAllowance?,
        backoffGrants: Int,
        backoffStartedAt: Date,
        at now: Date = Date()
    ) -> TemporaryAccessLedger {
        let pending = allowance?.isPending(at: now) == true
        return record(TemporaryAccessContribution(
            deviceID: deviceID,
            ruleID: rule,
            minutesGranted: allowance?.totalMinutesGranted ?? 0,
            pauseEndsAt: pending ? now : (allowance?.expiresAt ?? .distantPast),
            backoffGrants: backoffGrants,
            backoffStartedAt: backoffStartedAt,
            updatedAt: now,
            sessionGrantCount: allowance?.grantCount,
            pauseOpensAt: pending ? allowance?.opensAt : nil,
            pendingPauseEndsAt: pending ? allowance?.expiresAt : nil
        ), at: now)
    }
}
