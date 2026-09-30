import Foundation

extension DesktopEnforcementPolicy {
    /// Treats the daemon's root-owned file as an untrusted request. Only an
    /// active, structurally valid record bound to this authenticated policy and
    /// to a rule that explicitly opted in can affect the effective rule set.
    func validatedTemporaryPauseExpirations(
        from pauses: [BlockPageTemporaryPause],
        at now: Date = Date()
    ) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        let forced = sessionForcedRuleIDs(at: now)
        for pause in pauses {
            guard pause.policyRevision == revision,
                  !forced.contains(pause.ruleID),
                  pause.isStructurallyValid(),
                  pause.isActive(at: now),
                  let rule = rules.first(where: { $0.id == pause.ruleID }),
                  rule.lockdown.allowsTimeExtensions,
                  !rule.lockdown.needsNativeTemporaryAccess,
                  pause.policyFingerprint == temporaryPauseFingerprint(for: rule.id)
            else { continue }

            // The writer stores one record per rule. If a hand-edited document
            // contains duplicates, use the shorter authorization instead of
            // allowing malformed input to lengthen access.
            result[rule.id] = min(result[rule.id] ?? pause.expiresAt, pause.expiresAt)
        }
        return result
    }
}
