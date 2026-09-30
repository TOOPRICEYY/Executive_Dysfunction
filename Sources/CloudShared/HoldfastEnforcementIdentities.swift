import Foundation

/// Every enforcement identity the document can name.
///
/// A shield lives in a `ManagedSettingsStore` named after the group and window
/// that justified it, and `ManagedSettings` cannot be enumerated: a store can
/// only be reached by reconstructing its name. Anything that stops being named
/// therefore keeps its shield forever with nothing left to lift it.
///
/// Three sources of identity outlive the schedule that created them:
///
/// * A Blocking Group that is switched off still has windows, and its stores
///   still exist.
/// * A Retreat's groups are independent copies with their own group and window
///   identities. When the Retreat ends they leave the compiled rules entirely,
///   taking their names with them.
/// * A Retreat keeps every version it has ever had, so older versions name
///   identities that no current rule mentions.
///
/// Collecting all of them is what makes a sweep possible.
enum HoldfastEnforcementIdentities {
    struct WindowIdentity: Hashable, Sendable {
        var groupID: UUID
        var windowID: UUID
        /// Whether this identity belongs to the live schedule. Everything else
        /// is reachable only so that it can be cleared.
        var isCurrentlyEnforceable: Bool
    }

    /// Every (group, window) pair the document can name.
    ///
    /// A pair is enforceable only when it comes from an enabled baseline group
    /// or an active Retreat's current version -- exactly the set that receives a
    /// Device Activity monitor.
    static func allWindowIdentities(
        document: CloudPreferencesDocument,
        now: Date = Date()
    ) -> Set<WindowIdentity> {
        var enforceable: Set<WindowIdentity> = []
        var reachable: Set<WindowIdentity> = []

        func collect(_ group: CloudBlockingGroup, enforceable isEnforceable: Bool) {
            // Both the stored slots and the derived blocking windows can have
            // been used as an identity, depending on the paint mode in force
            // when the shield was written.
            let windows = group.timeWindow.slots + group.timeWindow.effectiveBlockingSlots()
            for window in windows {
                let identity = WindowIdentity(
                    groupID: group.id,
                    windowID: window.id,
                    isCurrentlyEnforceable: isEnforceable
                )
                if isEnforceable {
                    enforceable.insert(identity)
                } else {
                    reachable.insert(identity)
                }
            }
        }

        for group in document.baseline.blockingGroups {
            collect(group, enforceable: group.isEnabled)
        }

        for retreat in document.retreats {
            let currentVersionNumber = retreat.currentVersion?.number
            let isActive = retreat.isActive(at: now)
            for version in retreat.versions {
                let isLive = isActive && version.number == currentVersionNumber
                for group in version.blockingGroups {
                    collect(group, enforceable: isLive && group.isEnabled)
                }
            }
        }

        // An identity that is enforceable anywhere must not also appear as
        // sweepable, or the sweep would clear a live shield.
        let enforceableKeys = Set(enforceable.map { IdentityKey($0) })
        let sweepable = reachable.filter { !enforceableKeys.contains(IdentityKey($0)) }
        return enforceable.union(sweepable)
    }

    /// Every rule identity the document can name, for the per-rule usage stores.
    static func enforcedUsageRuleIDs(document: CloudPreferencesDocument, now: Date = Date()) -> Set<UUID> {
        // Usage-only rules have no window identities. Inferring this set from
        // windows would erase their threshold shields on every sync.
        Set(document.compiledRules(at: now)
            .filter { $0.isEnabled && $0.usageLimitEnabled }
            .map(\.id))
    }

    /// Every rule identity the document can name, for the per-rule usage stores.
    static func allRuleIdentities(document: CloudPreferencesDocument) -> Set<UUID> {
        var identities = Set(document.baseline.blockingGroups.map(\.id))
        identities.formUnion(document.rules.map(\.id))
        for retreat in document.retreats {
            for version in retreat.versions {
                identities.formUnion(version.blockingGroups.map(\.id))
            }
        }
        return identities
    }

    private struct IdentityKey: Hashable {
        var groupID: UUID
        var windowID: UUID

        init(_ identity: WindowIdentity) {
            groupID = identity.groupID
            windowID = identity.windowID
        }
    }
}
