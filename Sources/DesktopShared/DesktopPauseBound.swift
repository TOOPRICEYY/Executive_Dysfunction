import Foundation
import os

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
    /// An authorized new session carries a different identity, so a re-grant
    /// after expiry does not require an intervening app publish to clear the
    /// old cap. Legacy policies without an identity retain conservative bounds.
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
                  rule.lockdown.effectiveMaximumTemporaryAccessMinutes > 0 else {
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
            let old = previousByID[rule.id]
            let newAuthorization = rule.pauseAuthorizationID != nil
                && rule.pauseAuthorizationID != old?.pauseAuthorizationID
            let start = newAuthorization ? now : min(old?.pauseSessionStartedAt ?? now, now)
            let ceiling = start.addingTimeInterval(
                TimeInterval(rule.lockdown.effectiveMaximumTemporaryAccessMinutes) * 60
            )
            let bounded = min(claimed, ceiling)
            if bounded < claimed {
                Logger(subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter", category: "temporary-access").notice("pause_bounded rule=\(rule.id.uuidString, privacy: .public) claimed=\(claimed.timeIntervalSince1970, privacy: .public) start=\(start.timeIntervalSince1970, privacy: .public) maximumMinutes=\(rule.lockdown.effectiveMaximumTemporaryAccessMinutes, privacy: .public) now=\(now.timeIntervalSince1970, privacy: .public)")
            }
            rule.pauseSessionStartedAt = start
            rule.pausedUntil = bounded > now ? bounded : nil
            return rule
        }
        return result
    }
}
