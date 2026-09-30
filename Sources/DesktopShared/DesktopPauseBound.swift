import Foundation

extension DesktopEnforcementPolicy {
    /// Caps every temporary pause at the rule's own session maximum, measured
    /// from when the *filter* first saw that pause, not from anything the app
    /// claims.
    ///
    /// The app builds `pausedUntil` from a ledger in preferences the device
    /// owner can edit. Clamping in the app bounds a single publish, but the app
    /// republishes routinely, so a hand-edited far-future expiry would slide
    /// forward forever. The filter keeps its accepted policy in its own
    /// Keychain, so it is the right place to remember when a pause session
    /// began. A session lasts while the app keeps claiming a pause; once the app
    /// stops claiming one (the ledger expired it), the next grant starts fresh.
    /// Residual: if a legitimate re-grant reaches the filter with no publish in
    /// between, it is treated as the same session and capped accordingly. That
    /// errs toward blocking.
    func boundingPauses(
        from previous: DesktopEnforcementPolicy,
        at now: Date = Date()
    ) -> DesktopEnforcementPolicy {
        let previousByID = Dictionary(
            previous.rules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = self
        result.rules = rules.map { rule in
            var rule = rule
            guard let claimed = rule.pausedUntil, claimed > now,
                  rule.lockdown.permitsAnyTemporaryAccess,
                  rule.lockdown.maximumTimeExtensionHours > 0 else {
                // The app no longer claims a pause: the session is over, and a
                // later grant starts a fresh one.
                rule.pausedUntil = nil
                rule.pauseSessionStartedAt = nil
                return rule
            }
            // A session continues for as long as the app keeps claiming a pause,
            // including after the filter has already exhausted it. Otherwise a
            // hand-edited ledger that simply keeps claiming a future expiry
            // would earn a fresh maximum on every republish.
            let start = min(previousByID[rule.id]?.pauseSessionStartedAt ?? now, now)
            let ceiling = start.addingTimeInterval(
                TimeInterval(rule.lockdown.maximumTimeExtensionHours) * 3_600
            )
            let bounded = min(claimed, ceiling)
            rule.pauseSessionStartedAt = start
            rule.pausedUntil = bounded > now ? bounded : nil
            return rule
        }
        return result
    }
}
