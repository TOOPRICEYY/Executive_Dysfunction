import FamilyControls
import Foundation
import ManagedSettings

enum EnforcementEngine {
    static func apply(_ rule: BlockingRule, to store: ManagedSettingsStore, ignoringTemporaryAllowance: Bool = false) {
        guard ignoringTemporaryAllowance || SharedConfiguration.activeTimeAllowance(for: rule.id) == nil else {
            store.clearAllSettings()
            return
        }
        store.clearAllSettings()
        let selection = rule.selection

        switch rule.enforcementMode {
        case .blockList:
            store.shield.applications = selection.applicationTokens.nilIfEmpty
            store.shield.webDomains = selection.webDomainTokens.nilIfEmpty
            store.shield.applicationCategories = selection.categoryTokens.isEmpty
                ? nil
                : .specific(selection.categoryTokens)
            store.shield.webDomainCategories = selection.categoryTokens.isEmpty
                ? nil
                : .specific(selection.categoryTokens)

            let domains = Set(rule.enforcedDomains.map(WebDomain.init(domain:)))
            store.webContent.blockedByFilter = domains.isEmpty ? nil : .specific(domains)

        case .fortressAllowList:
            store.shield.applications = nil
            store.shield.webDomains = nil
            store.shield.applicationCategories = .all(except: selection.applicationTokens)
            store.shield.webDomainCategories = nil

            let explicitDomains = rule.enforcedDomains.map(WebDomain.init(domain:))
            let tokenDomains = selection.webDomainTokens.map(WebDomain.init(token:))
            let allowedDomains = Set(explicitDomains + tokenDomains)
            store.webContent.blockedByFilter = .all(except: allowedDomains)
        }
    }

    static func clear(storeNamed name: ManagedSettingsStore.Name) {
        ManagedSettingsStore(named: name).clearAllSettings()
    }

    static func suspend(_ rule: BlockingRule) {
        for window in rule.windows {
            clear(storeNamed: MonitorDescriptor.window(ruleID: rule.id, windowID: window.id).storeName)
        }
        clear(storeNamed: MonitorDescriptor.usage(ruleID: rule.id).storeName)
    }

    static func usageShieldIsConfigured(ruleID: UUID) -> Bool {
        shieldIsConfigured(storeNamed: MonitorDescriptor.usage(ruleID: ruleID).storeName)
    }

    /// Whether a store currently holds any restriction. Diagnostics read this to
    /// tell an applied block apart from one that was already lifted.
    static func shieldIsConfigured(storeNamed name: ManagedSettingsStore.Name) -> Bool {
        let store = ManagedSettingsStore(named: name)
        return store.shield.applications != nil
            || store.shield.applicationCategories != nil
            || store.shield.webDomains != nil
            || store.webContent.blockedByFilter != nil
    }

    static func setAntiUninstall(_ enabled: Bool) {
        let store = ManagedSettingsStore(named: SharedConfiguration.antiUninstallStoreName)
        store.application.denyAppRemoval = enabled ? true : nil
        SharedConfiguration.antiUninstallEnabled = enabled
    }

    /// Prevents bypassing a delayed unlock by manually moving the device clock.
    /// This setting remains tied to valid Family Controls authorization.
    static func setLockdownSystemHardening(_ enabled: Bool) {
        let store = ManagedSettingsStore(named: SharedConfiguration.antiUninstallStoreName)
        store.dateAndTime.requireAutomaticDateAndTime = enabled ? true : nil
    }
}

private extension Set {
    var nilIfEmpty: Set<Element>? { isEmpty ? nil : self }
}
