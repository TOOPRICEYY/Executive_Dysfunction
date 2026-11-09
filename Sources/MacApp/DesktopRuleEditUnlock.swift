import Foundation

/// Bind the wait/checkpoints to the saved policy, never to an editor draft.
struct DesktopRuleEditUnlock: Codable {
    var policy: DesktopLockdownPolicy
    var process: UnlockProcess

    static func configuration(_ policy: DesktopLockdownPolicy) -> LockdownConfiguration {
        var config = LockdownConfiguration()
        config.isEnabled = policy.severity != "none"
        config.unlockDelayDays = policy.severity == "passageOnly" ? 0 : max(0, policy.unlockDelayDays)
        config.repeatConfirmations = policy.severity == "repeatedConfirmations"
        config.passageWordCount = min(300, max(20, policy.passageWordCount))
        config.confirmationWindowHours = max(1, policy.confirmationWindowHours)
        config.editWindowHours = max(1, policy.editWindowHours)
        return config
    }

    func phase(for current: DesktopLockdownPolicy, at now: Date) -> UnlockPhase {
        guard policy == current else { return .idle }
        return Lockdown.phase(of: process, configuration: Self.configuration(current), at: now)
    }

    /// A rule's edit window must never authorize a weaker unrelated rule.
    static func canAuthorize(ruleID: UUID, existing: DesktopEnforcementPolicy,
                             proposed: DesktopEnforcementPolicy) -> Bool {
        var comparison = proposed
        comparison.weakeningAuthorizationExpiresAt = nil
        comparison.rules.removeAll { $0.id == ruleID }
        if let old = existing.rules.first(where: { $0.id == ruleID }) {
            comparison.rules.append(old)
        }
        guard comparison.lockdownSessions == existing.lockdownSessions else { return false }
        return DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: comparison)
    }
}
