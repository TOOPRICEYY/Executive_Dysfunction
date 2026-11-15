import Foundation

/// The Mac's record of locally authorized temporary pauses.
///
/// Local enforcement replica of pauses authorized here or received via iCloud.
///
/// The escalation rules are shared with iOS through `TimeAllowancePolicy`, so
/// the second pause in a session costs the same doubled passage on both
/// platforms.
enum MacTemporaryPauseStore {
    static let defaultsKey = "desktop-enforcement.temporary-pauses.v1"

    enum GrantError: Error, Equatable {
        case notPermitted
        case exceedsSessionMaximum(maximumMinutes: Int)
        /// The new minutes' wait would end after the scheduled access does.
        case alreadyScheduled(endsAt: Date)

        var message: String {
            switch self {
            case .notPermitted:
                "This Blocking Group's security policy does not allow temporary access."
            case let .exceedsSessionMaximum(maximumMinutes):
                "This pause would exceed the group's configured maximum of \(TimeAllowancePolicy.describeMaximum(minutes: maximumMinutes)) for the current session."
            case let .alreadyScheduled(endsAt):
                "Access is already scheduled. Request more after it ends at \(endsAt.formatted(date: .omitted, time: .shortened))."
            }
        }
    }

    static func load(defaults: any KeyValueLedger) -> [UUID: RuleTimeAllowance] {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([UUID: RuleTimeAllowance].self, from: data)
        else { return [:] }
        return stored
    }

    static func save(_ pauses: [UUID: RuleTimeAllowance], defaults: any KeyValueLedger) {
        if pauses.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(try? JSONEncoder().encode(pauses), forKey: defaultsKey)
        }
    }

    /// The live record, pending or open. Bookkeeping only (spend, passage
    /// growth, extensions); enforcement and display use `open`.
    static func active(
        for ruleID: UUID,
        at now: Date,
        defaults: any KeyValueLedger
    ) -> RuleTimeAllowance? {
        guard let pause = load(defaults: defaults)[ruleID], pause.expiresAt > now else { return nil }
        return pause
    }

    /// The pause whose access is open now.
    static func open(for ruleID: UUID, at now: Date, defaults: any KeyValueLedger) -> RuleTimeAllowance? {
        guard let pause = active(for: ruleID, at: now, defaults: defaults), pause.isOpen(at: now) else { return nil }
        return pause
    }

    /// What the published policy stamps onto its rules as `pausedUntil`. Only
    /// open pauses: a pending one is published separately (see
    /// `pendingIntervals`) so an older filter cannot open it early. Expired
    /// records are dropped rather than published, so a stale entry can never
    /// release a block.
    static func activeExpirations(at now: Date, defaults: any KeyValueLedger) -> [UUID: Date] {
        load(defaults: defaults)
            .filter { $0.value.isOpen(at: now) }
            .mapValues(\.expiresAt)
    }

    /// Granted pauses still inside their wait, as opening → end.
    static func pendingIntervals(at now: Date, defaults: any KeyValueLedger) -> [UUID: DateInterval] {
        load(defaults: defaults).compactMapValues { pause in
            guard pause.isPending(at: now), let opens = pause.opensAt else { return nil }
            return DateInterval(start: opens, end: pause.expiresAt)
        }
    }

    static func activeAuthorizationIDs(at now: Date, defaults: any KeyValueLedger) -> [UUID: String] {
        load(defaults: defaults).filter { $0.value.isOpen(at: now) }.mapValues { pause in
            // Granting an extension adds the same duration to expiry and spend,
            // so this origin remains stable throughout a contiguous session.
            String(pause.expiresAt.timeIntervalSince1970 - Double(pause.totalMinutesGranted) * 60)
        }
    }

    /// Removes records that have run out, so the session maximum resets once a
    /// pause ends rather than counting against the user forever.
    @discardableResult
    static func pruneExpired(at now: Date, defaults: any KeyValueLedger) -> Int {
        let stored = load(defaults: defaults)
        let live = stored.filter { $0.value.expiresAt > now }
        guard live.count != stored.count else { return 0 }
        save(live, defaults: defaults)
        return stored.count - live.count
    }

    static func availableDurations(
        for rule: DesktopEnforcementRule,
        at now: Date,
        defaults: any KeyValueLedger,
        otherDeviceMinutes: Int = 0
    ) -> [TemporaryAccessDuration] {
        guard rule.lockdown.allowsTimeExtensions else { return [] }
        let spent = (active(for: rule.id, at: now, defaults: defaults)?.totalMinutesGranted ?? 0)
            + max(0, otherDeviceMinutes)
        return TemporaryAccessDuration.allCases.filter {
            TimeAllowancePolicy.canGrant(
                $0,
                afterMinutes: spent,
                maximumMinutes: rule.lockdown.effectiveMaximumTemporaryAccessMinutes
            )
        }
    }

    /// The passage this pause costs. The first in a session uses the rule's own
    /// length; every consecutive one doubles it.
    static func passageWordCount(
        for rule: DesktopEnforcementRule,
        at now: Date,
        defaults: any KeyValueLedger,
        otherDeviceGrants: Int = 0
    ) -> Int {
        let sessionWords = TimeAllowancePolicy.passageWordCount(
            base: rule.lockdown.effectiveTemporaryAccessPassageWordCount,
            incrementsAlreadyGranted: active(for: rule.id, at: now, defaults: defaults)?.grantCount ?? 0
        )
        if let days = rule.lockdown.temporaryAllowanceResetDays {
            // A grant taken on another device still cost a passage, so it
            // lengthens the next one here too.
            let local = TemporaryAllowanceBackoff.history(for: rule.id, defaults: defaults)
            let combined = TemporaryAllowanceBackoff.History(
                startedAt: local?.startedAt ?? now,
                grants: (local?.grants ?? 0) + max(0, otherDeviceGrants)
            )
            return TemporaryAllowanceBackoff.wordCount(base: rule.lockdown.effectiveTemporaryAccessPassageWordCount,
                history: combined, resetDays: days, at: now,
                sessionWordCount: sessionWords)
        }
        return sessionWords
    }

    static func grant(
        _ duration: TemporaryAccessDuration,
        for rule: DesktopEnforcementRule,
        at now: Date,
        defaults: any KeyValueLedger,
        otherDeviceMinutes: Int = 0
    ) -> Result<RuleTimeAllowance, GrantError> {
        guard rule.lockdown.allowsTimeExtensions else { return .failure(.notPermitted) }

        let existing = active(for: rule.id, at: now, defaults: defaults)
        let localSpent = existing?.totalMinutesGranted ?? 0
        let spent = localSpent + max(0, otherDeviceMinutes)
        guard TimeAllowancePolicy.canGrant(
            duration,
            afterMinutes: spent,
            maximumMinutes: rule.lockdown.effectiveMaximumTemporaryAccessMinutes
        ) else {
            return .failure(.exceedsSessionMaximum(
                maximumMinutes: rule.lockdown.effectiveMaximumTemporaryAccessMinutes
            ))
        }

        // Extending adds to the end of the current pause rather than restarting
        // it, so repeated grants cannot quietly stretch past the maximum. The
        // group's wait keeps a fresh grant closed until it has elapsed.
        let timing = TimeAllowancePolicy.timing(
            existing: existing, duration: duration,
            waitMinutes: rule.lockdown.effectiveTemporaryAccessWaitMinutes, now: now)
        guard case let .scheduled(opensAt, expiresAt) = timing else {
            if case let .refused(endsAt) = timing { return .failure(.alreadyScheduled(endsAt: endsAt)) }
            return .failure(.notPermitted)
        }
        let granted = RuleTimeAllowance(
            ruleID: rule.id,
            expiresAt: expiresAt,
            totalMinutesGranted: spent + duration.minutes,
            grantCount: (existing?.grantCount ?? 0) + 1,
            restoreUsageShield: existing?.restoreUsageShield ?? false,
            opensAt: opensAt > now ? opensAt : existing?.opensAt
        )
        var stored = load(defaults: defaults)
        stored[rule.id] = granted
        save(stored, defaults: defaults)
        if let days = rule.lockdown.temporaryAllowanceResetDays {
            TemporaryAllowanceBackoff.recordGrant(for: rule.id, resetDays: days, at: now, defaults: defaults)
        }
        return .success(granted)
    }

    @discardableResult
    static func cancel(ruleID: UUID, defaults: any KeyValueLedger) -> Bool {
        var stored = load(defaults: defaults)
        guard stored.removeValue(forKey: ruleID) != nil else { return false }
        save(stored, defaults: defaults)
        return true
    }
}
