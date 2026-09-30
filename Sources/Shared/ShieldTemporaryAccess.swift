import FamilyControls
import Foundation
import ManagedSettings

/// A short-lived handoff from Apple's shield extension to the containing app.
/// The opaque activity token stays inside the extension; the app receives only
/// the exact rule IDs that were eligible when the user made the request.
struct PendingTemporaryAccessRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var eligibleRuleIDs: [UUID]
    /// `nil` supports systems whose shield offers one secondary button rather
    /// than the three-item 10/30/60-minute submenu. The app asks for a duration.
    var duration: TemporaryAccessDuration?
    var createdAt: Date
    var expiresAt: Date
}

enum ShieldTemporaryAccessCoordinator {
    static let requestLifetime: TimeInterval = 10 * 60

    private static let appGroupIdentifier = "group.com.GabrielPrice.ExecutiveDysfunction"
    private static let rulesKey = "blocking.rules.v1"
    private static let allowancesKey = "lockdown.rule-time-allowances.v1"
    private static let pendingRequestKey = "lockdown.pending-temporary-access.v1"

    static func loadRules() -> [BlockingRule] {
        loadRules(defaults: sharedDefaults)
    }

    static func eligibleRuleIDs(
        forApplication token: ApplicationToken,
        rules: [BlockingRule],
        at now: Date = Date()
    ) -> [UUID] {
        eligibleRuleIDs(
            rules: rules,
            at: now,
            activeAllowanceRuleIDs: activeAllowanceRuleIDs(at: now, defaults: sharedDefaults),
            currentlyEnforcedRuleIDs: currentlyEnforcedRuleIDs(in: rules)
        ) { rule in
            rule.selection.applicationTokens.contains(token)
        }
    }

    static func eligibleRuleIDs(
        forWebDomain token: WebDomainToken,
        rules: [BlockingRule],
        at now: Date = Date()
    ) -> [UUID] {
        eligibleRuleIDs(
            rules: rules,
            at: now,
            activeAllowanceRuleIDs: activeAllowanceRuleIDs(at: now, defaults: sharedDefaults),
            currentlyEnforcedRuleIDs: currentlyEnforcedRuleIDs(in: rules)
        ) { rule in
            rule.selection.webDomainTokens.contains(token)
        }
    }

    static func eligibleRuleIDs(
        forCategory token: ActivityCategoryToken,
        rules: [BlockingRule],
        at now: Date = Date()
    ) -> [UUID] {
        eligibleRuleIDs(
            rules: rules,
            at: now,
            activeAllowanceRuleIDs: activeAllowanceRuleIDs(at: now, defaults: sharedDefaults),
            currentlyEnforcedRuleIDs: currentlyEnforcedRuleIDs(in: rules)
        ) { rule in
            rule.selection.categoryTokens.contains(token)
        }
    }

    /// Saves one pending request. A later shield action intentionally replaces
    /// an earlier one, while ID-scoped clearing prevents an old sheet from
    /// deleting that newer request when it closes.
    @discardableResult
    static func savePendingRequest(
        eligibleRuleIDs: [UUID],
        duration: TemporaryAccessDuration?,
        now: Date = Date()
    ) -> PendingTemporaryAccessRequest? {
        savePendingRequest(
            eligibleRuleIDs: eligibleRuleIDs,
            duration: duration,
            now: now,
            defaults: sharedDefaults
        )
    }

    static func loadPendingRequest(now: Date = Date()) -> PendingTemporaryAccessRequest? {
        loadPendingRequest(now: now, defaults: sharedDefaults)
    }

    static func clearPendingRequest(id: UUID) {
        clearPendingRequest(id: id, defaults: sharedDefaults)
    }

    // MARK: - Testable persistence boundary

    static func loadRules(defaults: UserDefaults) -> [BlockingRule] {
        guard let data = defaults.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([BlockingRule].self, from: data)
        else { return [] }
        return rules
    }

    @discardableResult
    static func savePendingRequest(
        eligibleRuleIDs: [UUID],
        duration: TemporaryAccessDuration?,
        now: Date,
        defaults: UserDefaults
    ) -> PendingTemporaryAccessRequest? {
        let eligible = Array(Set(eligibleRuleIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !eligible.isEmpty else { return nil }
        let request = PendingTemporaryAccessRequest(
            id: UUID(),
            eligibleRuleIDs: eligible,
            duration: duration,
            createdAt: now,
            expiresAt: now.addingTimeInterval(requestLifetime)
        )
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        defaults.set(data, forKey: pendingRequestKey)
        return request
    }

    static func loadPendingRequest(
        now: Date,
        defaults: UserDefaults
    ) -> PendingTemporaryAccessRequest? {
        guard let data = defaults.data(forKey: pendingRequestKey),
              let request = try? JSONDecoder().decode(PendingTemporaryAccessRequest.self, from: data),
              !request.eligibleRuleIDs.isEmpty,
              now >= request.createdAt,
              now < request.expiresAt
        else {
            defaults.removeObject(forKey: pendingRequestKey)
            return nil
        }
        return request
    }

    static func clearPendingRequest(id: UUID, defaults: UserDefaults) {
        guard let data = defaults.data(forKey: pendingRequestKey),
              let request = try? JSONDecoder().decode(PendingTemporaryAccessRequest.self, from: data),
              request.id == id else { return }
        defaults.removeObject(forKey: pendingRequestKey)
    }

    /// Shared core for opaque token matching. A block list owns a target when it
    /// selected that token; a Fortress rule owns it when the target is absent
    /// from that rule's exception selection.
    static func eligibleRuleIDs(
        rules: [BlockingRule],
        at now: Date,
        activeAllowanceRuleIDs: Set<UUID> = [],
        currentlyEnforcedRuleIDs: Set<UUID>? = nil,
        targetIsSelected: (BlockingRule) -> Bool
    ) -> [UUID] {
        rules.compactMap { rule -> UUID? in
            let isCurrentlyEnforcing = currentlyEnforcedRuleIDs?.contains(rule.id)
                ?? (rule.usageLimitEnabled || rule.windows.contains(where: { $0.isActive(at: now) }))
            guard rule.isEnabled,
                  rule.lockdownPolicy.allowsTimeExtensions,
                  !activeAllowanceRuleIDs.contains(rule.id),
                  isCurrentlyEnforcing
            else { return nil }
            let selected = targetIsSelected(rule)
            switch rule.enforcementMode {
            case .blockList:
                return selected ? rule.id : nil
            case .fortressAllowList:
                return selected ? nil : rule.id
            }
        }
        .reduce(into: Set<UUID>()) { result, id in _ = result.insert(id) }
        .sorted { $0.uuidString < $1.uuidString }
    }

    static func activeAllowanceRuleIDs(
        at now: Date,
        defaults: UserDefaults
    ) -> Set<UUID> {
        guard let data = defaults.data(forKey: allowancesKey),
              let allowances = try? JSONDecoder().decode([UUID: RuleTimeAllowance].self, from: data)
        else { return [] }
        return Set(allowances.values.filter { $0.isActive(at: now) }.map(\.ruleID))
    }

    /// Named Managed Settings stores are the authoritative provenance for a
    /// shield. A usage limit is not active merely because it is configured; its
    /// per-rule store receives restrictions only after the threshold fires.
    static func currentlyEnforcedRuleIDs(in rules: [BlockingRule]) -> Set<UUID> {
        Set(rules.compactMap { rule in
            let activeWindow = rule.windows.contains { window in
                storeHasRestrictions(named: "ed.w.\(rule.id.uuidString).\(window.id.uuidString)")
            }
            let activeUsage = storeHasRestrictions(named: "ed.u.\(rule.id.uuidString)")
            return activeWindow || activeUsage ? rule.id : nil
        })
    }

    private static func storeHasRestrictions(named rawName: String) -> Bool {
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(rawName))
        return store.shield.applications != nil
            || store.shield.applicationCategories != nil
            || store.shield.webDomains != nil
            || store.shield.webDomainCategories != nil
            || store.webContent.blockedByFilter != nil
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
