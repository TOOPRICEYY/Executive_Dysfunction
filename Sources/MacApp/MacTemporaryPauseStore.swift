import Foundation

/// The Mac's record of locally authorized temporary pauses.
///
/// A pause is device-local on purpose. The iPhone stores its allowances in its
/// own app group rather than iCloud, and pausing a block on one machine should
/// not lift it on another: the point of the pause is to get past a block in
/// front of you, not to weaken the rule everywhere.
///
/// The escalation rules are shared with iOS through `TimeAllowancePolicy`, so
/// the second pause in a session costs the same doubled passage on both
/// platforms.
enum MacTemporaryPauseStore {
    static let defaultsKey = "desktop-enforcement.temporary-pauses.v1"

    enum GrantError: Error, Equatable {
        case notPermitted
        case exceedsSessionMaximum(maximumHours: Int)

        var message: String {
            switch self {
            case .notPermitted:
                "This Blocking Group's security policy does not allow temporary access."
            case let .exceedsSessionMaximum(maximumHours):
                "This pause would exceed the group's configured maximum of \(maximumHours) additional hour(s) for the current session."
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

    static func active(
        for ruleID: UUID,
        at now: Date,
        defaults: any KeyValueLedger
    ) -> RuleTimeAllowance? {
        guard let pause = load(defaults: defaults)[ruleID], pause.expiresAt > now else { return nil }
        return pause
    }

    /// What the published policy stamps onto its rules. Expired records are
    /// dropped rather than published, so a stale entry can never release a
    /// block.
    static func activeExpirations(at now: Date, defaults: any KeyValueLedger) -> [UUID: Date] {
        load(defaults: defaults)
            .filter { $0.value.expiresAt > now }
            .mapValues(\.expiresAt)
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
        defaults: any KeyValueLedger
    ) -> [TemporaryAccessDuration] {
        guard rule.lockdown.allowsTimeExtensions else { return [] }
        let spent = active(for: rule.id, at: now, defaults: defaults)?.totalMinutesGranted ?? 0
        return TemporaryAccessDuration.allCases.filter {
            TimeAllowancePolicy.canGrant(
                $0,
                afterMinutes: spent,
                maximumHours: rule.lockdown.maximumTimeExtensionHours
            )
        }
    }

    /// The passage this pause costs. The first in a session uses the rule's own
    /// length; every consecutive one doubles it.
    static func passageWordCount(
        for rule: DesktopEnforcementRule,
        at now: Date,
        defaults: any KeyValueLedger
    ) -> Int {
        let sessionWords = TimeAllowancePolicy.passageWordCount(
            base: rule.lockdown.effectiveTemporaryAccessPassageWordCount,
            incrementsAlreadyGranted: active(for: rule.id, at: now, defaults: defaults)?.grantCount ?? 0
        )
        if let days = rule.lockdown.temporaryAllowanceResetDays {
            return TemporaryAllowanceBackoff.wordCount(base: rule.lockdown.effectiveTemporaryAccessPassageWordCount,
                history: TemporaryAllowanceBackoff.history(for: rule.id, defaults: defaults), resetDays: days, at: now,
                sessionWordCount: sessionWords)
        }
        return sessionWords
    }

    static func grant(
        _ duration: TemporaryAccessDuration,
        for rule: DesktopEnforcementRule,
        at now: Date,
        defaults: any KeyValueLedger
    ) -> Result<RuleTimeAllowance, GrantError> {
        guard rule.lockdown.allowsTimeExtensions else { return .failure(.notPermitted) }

        let existing = active(for: rule.id, at: now, defaults: defaults)
        let spent = existing?.totalMinutesGranted ?? 0
        guard TimeAllowancePolicy.canGrant(
            duration,
            afterMinutes: spent,
            maximumHours: rule.lockdown.maximumTimeExtensionHours
        ) else {
            return .failure(.exceedsSessionMaximum(
                maximumHours: rule.lockdown.maximumTimeExtensionHours
            ))
        }

        // Extending adds to the end of the current pause rather than restarting
        // it, so repeated grants cannot quietly stretch past the maximum.
        let base = existing?.expiresAt ?? now
        let granted = RuleTimeAllowance(
            ruleID: rule.id,
            expiresAt: base.addingTimeInterval(duration.seconds),
            totalMinutesGranted: spent + duration.minutes,
            grantCount: (existing?.grantCount ?? 0) + 1,
            restoreUsageShield: existing?.restoreUsageShield ?? false
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
