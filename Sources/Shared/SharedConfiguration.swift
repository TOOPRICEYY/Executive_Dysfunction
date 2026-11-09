import DeviceActivity
import Foundation
import ManagedSettings

enum SharedConfiguration {
    static let appGroupIdentifier = "group.com.GabrielPrice.ExecutiveDysfunction"
    static let rulesKey = "blocking.rules.v1"
    static let antiUninstallKey = "anti.uninstall.enabled"
    static let managedActivityPrefix = "ed."
    static var antiUninstallStoreName: ManagedSettingsStore.Name {
        ManagedSettingsStore.Name("ed.guard")
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
    static var bypassHistoryDefaults: UserDefaults { defaults }

    static func loadRules() -> [BlockingRule] {
        guard let data = defaults.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([BlockingRule].self, from: data)
        else { return [] }
        return rules
    }

    static func saveRules(_ rules: [BlockingRule]) throws {
        let data = try JSONEncoder().encode(rules)
        defaults.set(data, forKey: rulesKey)
    }

    static var antiUninstallEnabled: Bool {
        get { defaults.bool(forKey: antiUninstallKey) }
        set { defaults.set(newValue, forKey: antiUninstallKey) }
    }

    static let lockdownConfigurationKey = "lockdown.configuration.v1"
    static let unlockProcessKey = "lockdown.unlock.v1"
    static let ruleUnlockProcessesKey = "lockdown.rule-unlocks.v1"
    static let retreatUnlockProcessesKey = "lockdown.retreat-unlocks.v1"
    static let ruleTimeAllowancesKey = "lockdown.rule-time-allowances.v1"
    private static let timedLockdownsKey = "enforcement.timed-lockdowns.v1"

    static func loadTimedLockdowns() -> [TimedLockdownSession] {
        guard let data = defaults.data(forKey: timedLockdownsKey) else { return [] }
        return (try? JSONDecoder().decode([TimedLockdownSession].self, from: data)) ?? []
    }

    static func saveTimedLockdowns(_ sessions: [TimedLockdownSession]) throws {
        defaults.set(try JSONEncoder().encode(sessions), forKey: timedLockdownsKey)
    }

    static func allowanceBackoffHistory(for ruleID: UUID) -> TemporaryAllowanceBackoff.History? {
        TemporaryAllowanceBackoff.history(for: ruleID, defaults: defaults)
    }

    static func recordAllowanceBackoff(for ruleID: UUID, resetDays: Int, at now: Date) {
        TemporaryAllowanceBackoff.recordGrant(for: ruleID, resetDays: resetDays, at: now, defaults: defaults)
    }

    static func loadLockdownConfiguration() -> LockdownConfiguration {
        guard let data = defaults.data(forKey: lockdownConfigurationKey),
              let configuration = try? JSONDecoder().decode(LockdownConfiguration.self, from: data)
        else { return LockdownConfiguration() }
        return configuration
    }

    static func saveLockdownConfiguration(_ configuration: LockdownConfiguration) {
        defaults.set(try? JSONEncoder().encode(configuration), forKey: lockdownConfigurationKey)
    }

    static func loadUnlockProcess() -> UnlockProcess? {
        guard let data = defaults.data(forKey: unlockProcessKey) else { return nil }
        return try? JSONDecoder().decode(UnlockProcess.self, from: data)
    }

    static func saveUnlockProcess(_ process: UnlockProcess?) {
        guard let process else {
            defaults.removeObject(forKey: unlockProcessKey)
            return
        }
        defaults.set(try? JSONEncoder().encode(process), forKey: unlockProcessKey)
    }

    static func loadRuleUnlockProcesses() -> [UUID: UnlockProcess] {
        guard let data = defaults.data(forKey: ruleUnlockProcessesKey),
              let processes = try? JSONDecoder().decode([UUID: UnlockProcess].self, from: data)
        else { return [:] }
        return processes
    }

    static func saveRuleUnlockProcesses(_ processes: [UUID: UnlockProcess]) {
        if processes.isEmpty {
            defaults.removeObject(forKey: ruleUnlockProcessesKey)
        } else {
            defaults.set(try? JSONEncoder().encode(processes), forKey: ruleUnlockProcessesKey)
        }
    }

    static func loadRetreatUnlockProcesses() -> [UUID: UnlockProcess] {
        guard let data = defaults.data(forKey: retreatUnlockProcessesKey),
              let processes = try? JSONDecoder().decode([UUID: UnlockProcess].self, from: data)
        else { return [:] }
        return processes
    }

    static func saveRetreatUnlockProcesses(_ processes: [UUID: UnlockProcess]) {
        if processes.isEmpty {
            defaults.removeObject(forKey: retreatUnlockProcessesKey)
        } else {
            defaults.set(try? JSONEncoder().encode(processes), forKey: retreatUnlockProcessesKey)
        }
    }

    static func loadRuleTimeAllowances() -> [UUID: RuleTimeAllowance] {
        guard let data = defaults.data(forKey: ruleTimeAllowancesKey),
              let allowances = try? JSONDecoder().decode([UUID: RuleTimeAllowance].self, from: data)
        else { return [:] }
        return allowances
    }

    static func saveRuleTimeAllowances(_ allowances: [UUID: RuleTimeAllowance]) {
        if allowances.isEmpty {
            defaults.removeObject(forKey: ruleTimeAllowancesKey)
        } else {
            defaults.set(try? JSONEncoder().encode(allowances), forKey: ruleTimeAllowancesKey)
        }
    }

    static func activeTimeAllowance(for ruleID: UUID, at date: Date = Date()) -> RuleTimeAllowance? {
        guard let allowance = loadRuleTimeAllowances()[ruleID], allowance.isActive(at: date) else {
            return nil
        }
        return allowance
    }

    static let shieldedWindowStoreNamesKey = "enforcement.shielded-window-stores.v1"

    /// The store names a time block shield was last written to. A shield is
    /// lifted by its monitor's `intervalDidEnd`, so any store that outlives its
    /// monitor -- a window Screen Time had no capacity for, a recomputed window
    /// identity, a deleted rule -- would otherwise stay shielded forever with
    /// nothing left to release it.
    static var shieldedWindowStoreNames: Set<String> {
        get { Set(defaults.stringArray(forKey: shieldedWindowStoreNamesKey) ?? []) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: shieldedWindowStoreNamesKey)
            } else {
                defaults.set(Array(newValue).sorted(), forKey: shieldedWindowStoreNamesKey)
            }
        }
    }

    static func recordShieldedWindowStore(_ descriptor: MonitorDescriptor) {
        shieldedWindowStoreNames.insert(descriptor.activityName.rawValue)
    }

    static func markUsageShieldForRestore(ruleID: UUID) {
        var allowances = loadRuleTimeAllowances()
        guard var allowance = allowances[ruleID], allowance.isActive(at: Date()) else { return }
        allowance.restoreUsageShield = true
        allowances[ruleID] = allowance
        saveRuleTimeAllowances(allowances)
    }

}

enum MonitorDescriptor: Equatable {
    case lockdown(sessionID: UUID)
    case window(ruleID: UUID, windowID: UUID)
    case usage(ruleID: UUID)
    case allowance(ruleID: UUID)
    case usageBatch

    var activityName: DeviceActivityName {
        switch self {
        case let .lockdown(sessionID):
            DeviceActivityName("ed.l.\(sessionID.uuidString)")
        case let .window(ruleID, windowID):
            DeviceActivityName("ed.w.\(ruleID.uuidString).\(windowID.uuidString)")
        case let .usage(ruleID):
            DeviceActivityName("ed.u.\(ruleID.uuidString)")
        case let .allowance(ruleID):
            DeviceActivityName("ed.x.\(ruleID.uuidString)")
        case .usageBatch:
            DeviceActivityName("ed.ub")
        }
    }

    var storeName: ManagedSettingsStore.Name {
        ManagedSettingsStore.Name(activityName.rawValue)
    }

    var ruleID: UUID? {
        switch self {
        case let .window(ruleID, _), let .usage(ruleID), let .allowance(ruleID): ruleID
        case .usageBatch, .lockdown: nil
        }
    }

    var windowID: UUID? {
        guard case let .window(_, windowID) = self else { return nil }
        return windowID
    }

    static func parse(_ activity: DeviceActivityName) -> MonitorDescriptor? {
        let parts = activity.rawValue.split(separator: ".").map(String.init)
        guard parts.count >= 2, parts[0] == "ed" else { return nil }

        if parts.count == 2, parts[1] == "ub" { return .usageBatch }
        if parts.count == 3, parts[1] == "l", let id = UUID(uuidString: parts[2]) {
            return .lockdown(sessionID: id)
        }

        if parts.count == 3, parts[1] == "u", let ruleID = UUID(uuidString: parts[2]) {
            return .usage(ruleID: ruleID)
        }

        if parts.count == 3, parts[1] == "x", let ruleID = UUID(uuidString: parts[2]) {
            return .allowance(ruleID: ruleID)
        }

        guard parts[1] == "w",
              (parts.count == 4 || parts.count == 5),
              let ruleID = UUID(uuidString: parts[2]),
              let windowID = UUID(uuidString: parts[3])
        else { return nil }
        return .window(ruleID: ruleID, windowID: windowID)
    }
}

extension DeviceActivityEvent.Name {
    static func executiveDysfunctionThreshold(ruleID: UUID) -> Self {
        Self("ed.threshold.\(ruleID.uuidString)")
    }

    var executiveDysfunctionRuleID: UUID? {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.count == 3,
              parts[0] == "ed",
              parts[1] == "threshold"
        else { return nil }
        return UUID(uuidString: parts[2])
    }
}
