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
                let floor = Self.wholeSecondCeiling(Self.pendingGrantOrigin(of: latest, opening: opening)
                    .addingTimeInterval(ownWait))
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

    /// The moment a pending grant was made, from which a receiver measures its
    /// own wait. A record without `pendingGrantedAt` (an older writer) uses
    /// its write time, as before. A claimed origin is never earlier than the
    /// opening less the longest wait (and one second of the writer's
    /// rounding): no wait can have started before that, and it is the same
    /// bound the "opens more than a day after the write" check already puts on
    /// `updatedAt`, so this field cannot move a floor further into the past
    /// than a record's own write time could. A later claim only opens later.
    static func pendingGrantOrigin(of entry: TemporaryAccessContribution, opening: Date) -> Date {
        guard let claimed = entry.pendingGrantedAt else { return entry.updatedAt }
        let earliest = opening.addingTimeInterval(-(Double(TemporaryAccessWait.range.upperBound) * 60 + 1))
        return max(claimed, earliest)
    }

    /// Screen Time schedules at whole seconds and truncates, so a floor is
    /// rounded up: the monitor can never start a fraction before it.
    static func wholeSecondCeiling(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
    }
}

extension ICloudTemporaryAccessStore {
    /// Publishes this device's allowance for one rule, pending or open.
    ///
    /// A pending allowance is written so a build without waits cannot open
    /// it: its `pauseEndsAt` is `now`, which such a reader treats as no pause,
    /// while the real window travels in `pauseOpensAt` / `pendingPauseEndsAt`.
    /// The spend (minutes, backoff) is charged now, as for an open grant.
    ///
    /// `pendingGrantedAt` stays at the session's first pending write while
    /// the grant is extended, so receivers measure their wait from the grant,
    /// not from the extension. It is carried over only from this device's own
    /// pending entry with the identical opening: a new session (after expiry
    /// or cancellation, both of which overwrite that entry) opens later than
    /// any earlier one, so it always gets a fresh origin.
    @discardableResult
    func record(
        rule: UUID,
        allowance: RuleTimeAllowance?,
        backoffGrants: Int,
        backoffStartedAt: Date,
        at now: Date = Date()
    ) -> TemporaryAccessLedger {
        let pending = allowance?.isPending(at: now) == true
        var grantedAt: Date? = nil
        if pending {
            grantedAt = now
            if let own = load().contributions[TemporaryAccessLedger.key(rule: rule, device: deviceID)],
               own.isPendingRecord, let opening = own.pauseOpensAt, opening == allowance?.opensAt {
                grantedAt = min(now, own.pendingGrantedAt ?? own.updatedAt)
            }
        }
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
            pendingPauseEndsAt: pending ? allowance?.expiresAt : nil,
            pendingGrantedAt: grantedAt
        ), at: now)
    }
}
