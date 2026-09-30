import Foundation
import ManagedSettings

extension RuleScheduler {
    /// Clears every shield store the document can name but no longer enforces.
    ///
    /// The reconcile pass only walks the rules it was handed, which are the ones
    /// compiled from the live schedule. A Blocking Group that was switched off,
    /// and every group belonging to a Retreat that has ended, keep their stores
    /// under names no current rule mentions -- so their shields stay applied
    /// with no monitor left to lift them, and the block never releases.
    ///
    /// `ManagedSettings` cannot be enumerated, so this reconstructs the names
    /// from the document instead. Identities from builds that generated a fresh
    /// window UUID on every sync are not recoverable this way; clearing those
    /// needs `resetAllScreenTimeRestrictions`.
    @discardableResult
    func sweepUnenforcedShieldStores(document: CloudPreferencesDocument, now: Date = Date()) -> Int {
        var cleared = 0
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(document: document, now: now)
        for identity in identities where !identity.isCurrentlyEnforceable {
            let descriptor = MonitorDescriptor.window(
                ruleID: identity.groupID,
                windowID: identity.windowID
            )
            guard EnforcementEngine.shieldIsConfigured(storeNamed: descriptor.storeName) else { continue }
            EnforcementEngine.clear(storeNamed: descriptor.storeName)
            cleared += 1
        }

        let enforcedRuleIDs = HoldfastEnforcementIdentities.enforcedUsageRuleIDs(document: document, now: now)
        for ruleID in HoldfastEnforcementIdentities.allRuleIdentities(document: document)
        where !enforcedRuleIDs.contains(ruleID) {
            let descriptor = MonitorDescriptor.usage(ruleID: ruleID)
            guard EnforcementEngine.shieldIsConfigured(storeNamed: descriptor.storeName) else { continue }
            EnforcementEngine.clear(storeNamed: descriptor.storeName)
            cleared += 1
        }

        return cleared
    }
}
