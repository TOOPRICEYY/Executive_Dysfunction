import Combine
@preconcurrency import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var rules: [BlockingRule]
    @Published private(set) var authorizationStatus: AuthorizationStatus
    @Published private(set) var antiUninstallEnabled: Bool
    @Published private(set) var lockdownConfiguration: LockdownConfiguration
    @Published private(set) var unlockPhase: UnlockPhase = .idle
    @Published private(set) var ruleUnlockPhases: [UUID: UnlockPhase] = [:]
    @Published private(set) var cloudSyncStatus = "Not synced"
    @Published private(set) var pendingCloudRuleIDs: Set<UUID> = []
    @Published private(set) var ruleTimeAllowances: [UUID: RuleTimeAllowance]
    @Published var errorMessage: String?
    @Published var isRequestingAuthorization = false

    private let authorizationCenter = AuthorizationCenter.shared
    private let scheduler = RuleScheduler()
    private let cloudStore = ICloudPreferencesStore()
    private var unlockProcess: UnlockProcess?
    private var ruleUnlockProcesses: [UUID: UnlockProcess]

    init() {
        rules = SharedConfiguration.loadRules()
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        antiUninstallEnabled = SharedConfiguration.antiUninstallEnabled
        lockdownConfiguration = SharedConfiguration.loadLockdownConfiguration()
        unlockProcess = SharedConfiguration.loadUnlockProcess()
        ruleUnlockProcesses = SharedConfiguration.loadRuleUnlockProcesses()
        ruleTimeAllowances = SharedConfiguration.loadRuleTimeAllowances()
        refreshLockdown()
        refreshRuleLockdowns()
        refreshTimeAllowances()
    }

    var isAuthorized: Bool {
        if authorizationStatus == .approved { return true }
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess { return true }
        return false
    }

    var authorizationDescription: String {
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess {
            return "Approved with app and website data access"
        }
        if authorizationStatus == .approved { return "Approved" }
        if authorizationStatus == .denied { return "Denied" }
        if authorizationStatus == .notDetermined { return "Not requested" }
        return "Unknown"
    }

    func requestAuthorization() async {
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refreshAuthorizationAndEnforcement()
        } catch {
            errorMessage = "Screen Time authorization failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ rule: BlockingRule) -> Bool {
        var rule = rule
        rule.preferenceModifiedAt = Date()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            if isRuleEditingLocked(rule.id) {
                let change = RuleRestrictionEvaluator.compare(
                    existing: rules[index],
                    proposed: rule,
                    appDefaultLockdown: lockdownConfiguration
                )
                guard change == .strictlyMoreRestrictive else {
                    return false
                }
            }
            rules[index] = rule
            if !rule.lockdownPolicy.allowsTimeExtensions {
                removeTimeAllowance(rule.id)
            }
        } else {
            rules.append(rule)
        }
        return persistAndSchedule()
    }

    func deleteRules(at offsets: IndexSet) {
        let selectedRules = offsets.compactMap { rules.indices.contains($0) ? rules[$0] : nil }
        guard !selectedRules.contains(where: { isRuleEditingLocked($0.id) }) else {
            errorMessage = "One or more selected rules are locked. Complete each rule's unlock process before removing it."
            return
        }
        for rule in selectedRules { ruleUnlockProcesses[rule.id] = nil }
        var storedAllowances = SharedConfiguration.loadRuleTimeAllowances()
        for rule in selectedRules { storedAllowances[rule.id] = nil }
        ruleTimeAllowances = storedAllowances
        SharedConfiguration.saveRuleTimeAllowances(storedAllowances)
        var tombstones = CloudTombstonePersistence.load()
        let deletedAt = Date()
        for rule in selectedRules {
            tombstones.removeAll { $0.id == rule.id }
            tombstones.append(CloudRuleTombstone(id: rule.id, modifiedAt: deletedAt))
        }
        CloudTombstonePersistence.save(tombstones)
        saveRuleUnlockProcesses()
        rules.remove(atOffsets: offsets)
        persistAndSchedule()
    }

    func setRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        guard enabled || !isRuleEditingLocked(id) else {
            errorMessage = "This rule must be unlocked before it can be disabled."
            return
        }
        rules[index].isEnabled = enabled
        if !enabled { removeTimeAllowance(id) }
        rules[index].preferenceModifiedAt = Date()
        persistAndSchedule()
    }

    func setAntiUninstall(_ enabled: Bool) {
        guard isAuthorized || !enabled else {
            errorMessage = "Grant Screen Time access before enabling anti-uninstall protection."
            return
        }
        let protectedRuleIsLocked = rules.contains { isRuleEditingLocked($0.id) }
        guard enabled || (!isEditingLocked && !protectedRuleIsLocked) else {
            errorMessage = "Anti-uninstall protects every rule. Unlock the app-wide settings and every protected rule before turning it off."
            return
        }
        EnforcementEngine.setAntiUninstall(enabled)
        antiUninstallEnabled = enabled
    }

    // MARK: - Settings lockdown

    var isEditingLocked: Bool {
        guard lockdownConfiguration.isEnabled else { return false }
        let livePhase = Lockdown.phase(
            of: unlockProcess,
            configuration: lockdownConfiguration,
            at: Date()
        )
        if case .unlocked = livePhase { return false }
        return true
    }

    func refreshLockdown(now: Date = Date()) {
        let phase = Lockdown.phase(of: unlockProcess, configuration: lockdownConfiguration, at: now)
        switch phase {
        case .cancelled:
            storeUnlockProcess(nil)
            unlockPhase = .idle
            errorMessage = "The unlock process was cancelled because a daily confirmation was missed. Start again to edit settings."
        case .idle:
            if unlockProcess != nil { storeUnlockProcess(nil) }
            unlockPhase = .idle
        default:
            unlockPhase = phase
        }
    }

    func updateLockdownConfiguration(_ configuration: LockdownConfiguration) {
        if configuration.loosens(comparedTo: lockdownConfiguration), isEditingLocked {
            errorMessage = "Lockdown is active. Weakening lockdown settings requires completing the unlock process first."
            return
        }
        lockdownConfiguration = configuration
        SharedConfiguration.saveLockdownConfiguration(configuration)
        if !configuration.isEnabled { storeUnlockProcess(nil) }
        refreshLockdown()
        refreshRuleLockdowns()
        updateSystemHardening()
    }

    /// Called after the user has typed the commitment passage.
    func startUnlock(now: Date = Date()) {
        guard lockdownConfiguration.isEnabled, unlockProcess == nil else { return }
        storeUnlockProcess(UnlockProcess(startedAt: now))
        refreshLockdown(now: now)
    }

    /// Called after the user has typed a daily confirmation passage.
    func confirmUnlock(now: Date = Date()) {
        guard var process = unlockProcess else { return }
        guard case .confirmationDue = Lockdown.phase(
            of: process,
            configuration: lockdownConfiguration,
            at: now
        ) else {
            errorMessage = "This confirmation is not due yet, or its deadline has passed."
            refreshLockdown(now: now)
            return
        }
        process.confirmedAt.append(now)
        storeUnlockProcess(process)
        refreshLockdown(now: now)
    }

    /// Abandon an unlock in progress, or close an open edit window early.
    func cancelUnlock() {
        storeUnlockProcess(nil)
        refreshLockdown()
    }

    private func storeUnlockProcess(_ process: UnlockProcess?) {
        unlockProcess = process
        SharedConfiguration.saveUnlockProcess(process)
    }

    // MARK: - Per-rule lockdown

    func ruleLockdownConfiguration(for rule: BlockingRule) -> LockdownConfiguration {
        rule.lockdownPolicy.configuration(appDefault: lockdownConfiguration)
    }

    func ruleUnlockPhase(for id: UUID, now: Date = Date()) -> UnlockPhase {
        guard let rule = rules.first(where: { $0.id == id }) else { return .idle }
        return Lockdown.phase(
            of: ruleUnlockProcesses[id],
            configuration: ruleLockdownConfiguration(for: rule),
            at: now
        )
    }

    func isRuleEditingLocked(_ id: UUID, now: Date = Date()) -> Bool {
        guard let rule = rules.first(where: { $0.id == id }) else { return false }
        let configuration = ruleLockdownConfiguration(for: rule)
        guard configuration.isEnabled else { return false }
        if case .unlocked = Lockdown.phase(
            of: ruleUnlockProcesses[id],
            configuration: configuration,
            at: now
        ) { return false }
        return true
    }

    func refreshRuleLockdowns(now: Date = Date()) {
        let knownIDs = Set(rules.map(\.id))
        ruleUnlockProcesses = ruleUnlockProcesses.filter { knownIDs.contains($0.key) }
        var phases: [UUID: UnlockPhase] = [:]
        var cancelledNames: [String] = []

        for rule in rules {
            let phase = Lockdown.phase(
                of: ruleUnlockProcesses[rule.id],
                configuration: ruleLockdownConfiguration(for: rule),
                at: now
            )
            switch phase {
            case .cancelled:
                ruleUnlockProcesses[rule.id] = nil
                phases[rule.id] = .idle
                cancelledNames.append(rule.name)
            case .idle:
                ruleUnlockProcesses[rule.id] = nil
                phases[rule.id] = .idle
            default:
                phases[rule.id] = phase
            }
        }

        ruleUnlockPhases = phases
        saveRuleUnlockProcesses()
        if !cancelledNames.isEmpty {
            errorMessage = "Unlock cancelled after a missed confirmation: \(cancelledNames.joined(separator: ", "))."
        }
    }

    func startRuleUnlock(_ id: UUID, now: Date = Date()) {
        guard let rule = rules.first(where: { $0.id == id }),
              ruleLockdownConfiguration(for: rule).isEnabled,
              ruleUnlockProcesses[id] == nil
        else { return }
        ruleUnlockProcesses[id] = UnlockProcess(startedAt: now)
        saveRuleUnlockProcesses()
        refreshRuleLockdowns(now: now)
    }

    func confirmRuleUnlock(_ id: UUID, now: Date = Date()) {
        guard let rule = rules.first(where: { $0.id == id }),
              var process = ruleUnlockProcesses[id]
        else { return }
        guard case .confirmationDue = Lockdown.phase(
            of: process,
            configuration: ruleLockdownConfiguration(for: rule),
            at: now
        ) else {
            errorMessage = "This rule's confirmation is not due yet, or its deadline has passed."
            refreshRuleLockdowns(now: now)
            return
        }
        process.confirmedAt.append(now)
        ruleUnlockProcesses[id] = process
        saveRuleUnlockProcesses()
        refreshRuleLockdowns(now: now)
    }

    func cancelRuleUnlock(_ id: UUID) {
        ruleUnlockProcesses[id] = nil
        saveRuleUnlockProcesses()
        refreshRuleLockdowns()
    }

    private func saveRuleUnlockProcesses() {
        SharedConfiguration.saveRuleUnlockProcesses(ruleUnlockProcesses)
    }

    private func updateSystemHardening() {
        let hasRuleLockdown = rules.contains {
            ruleLockdownConfiguration(for: $0).isEnabled
        }
        EnforcementEngine.setLockdownSystemHardening(
            lockdownConfiguration.isEnabled || hasRuleLockdown
        )
    }

    // MARK: - Passage-gated additional time

    func activeTimeAllowance(for ruleID: UUID, now: Date = Date()) -> RuleTimeAllowance? {
        if let stored = SharedConfiguration.activeTimeAllowance(for: ruleID, at: now) {
            return stored
        }
        guard let allowance = ruleTimeAllowances[ruleID], allowance.isActive(at: now) else { return nil }
        return allowance
    }

    func timeAllowancePassageWordCount(for ruleID: UUID, now: Date = Date()) -> Int {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return 40 }
        let base = ruleLockdownConfiguration(for: rule).passageWordCount
        let granted = activeTimeAllowance(for: ruleID, now: now)?.incrementsGranted ?? 0
        return TimeAllowancePolicy.passageWordCount(base: base, incrementsAlreadyGranted: granted)
    }

    func nextTimeAllowanceIncrement(for ruleID: UUID, now: Date = Date()) -> Int {
        (activeTimeAllowance(for: ruleID, now: now)?.incrementsGranted ?? 0) + 1
    }

    func grantTimeAllowance(for ruleID: UUID, now: Date = Date()) {
        guard let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              rule.lockdownPolicy.allowsTimeExtensions
        else {
            errorMessage = "Additional time is not enabled for this rule."
            return
        }

        let existing = SharedConfiguration.activeTimeAllowance(for: ruleID, at: now)
            ?? activeTimeAllowance(for: ruleID, now: now)
        let granted = existing?.incrementsGranted ?? 0
        guard granted < rule.lockdownPolicy.maximumTimeExtensionHours else {
            errorMessage = "This rule has reached its configured maximum of \(rule.lockdownPolicy.maximumTimeExtensionHours) additional hour(s) for the current allowance session."
            return
        }
        if existing == nil,
           RuleScheduler.requiredActivityCount(for: rules) + 1 > RuleScheduler.maximumConcurrentActivities {
            errorMessage = "No Screen Time monitor slot is available for a one-hour allowance. Remove or combine a time block first."
            return
        }

        let baseDate = existing?.expiresAt ?? now
        let allowance = RuleTimeAllowance(
            ruleID: ruleID,
            expiresAt: baseDate.addingTimeInterval(TimeAllowancePolicy.hour),
            incrementsGranted: granted + 1,
            restoreUsageShield: (existing?.restoreUsageShield ?? false)
                || EnforcementEngine.usageShieldIsConfigured(ruleID: ruleID)
        )
        var storedAllowances = SharedConfiguration.loadRuleTimeAllowances()
        storedAllowances[ruleID] = allowance
        ruleTimeAllowances = storedAllowances
        SharedConfiguration.saveRuleTimeAllowances(storedAllowances)
        synchronize()
    }

    func refreshTimeAllowances(now: Date = Date()) {
        ruleTimeAllowances = SharedConfiguration.loadRuleTimeAllowances()
        let expired = ruleTimeAllowances.values.filter { !$0.isActive(at: now) }
        guard !expired.isEmpty else { return }
        for allowance in expired {
            ruleTimeAllowances[allowance.ruleID] = nil
            if allowance.restoreUsageShield,
               let rule = rules.first(where: { $0.id == allowance.ruleID && $0.isEnabled }) {
                EnforcementEngine.apply(
                    rule,
                    to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: rule.id).storeName)
                )
            }
        }
        SharedConfiguration.saveRuleTimeAllowances(ruleTimeAllowances)
    }

    private func removeTimeAllowance(_ ruleID: UUID) {
        var storedAllowances = SharedConfiguration.loadRuleTimeAllowances()
        guard let removed = storedAllowances.removeValue(forKey: ruleID) else { return }
        ruleTimeAllowances = storedAllowances
        SharedConfiguration.saveRuleTimeAllowances(storedAllowances)
        if removed.restoreUsageShield,
           let rule = rules.first(where: { $0.id == ruleID && $0.isEnabled }) {
            EnforcementEngine.apply(
                rule,
                to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: ruleID).storeName)
            )
        }
    }

    func refreshAuthorizationAndEnforcement() {
        refreshLockdown()
        refreshRuleLockdowns()
        refreshTimeAllowances()
        syncICloudPreferences()
        authorizationStatus = authorizationCenter.authorizationStatus
        guard isAuthorized else {
            antiUninstallEnabled = false
            return
        }

        if SharedConfiguration.antiUninstallEnabled {
            EnforcementEngine.setAntiUninstall(true)
            antiUninstallEnabled = true
        }
        updateSystemHardening()
        synchronize()
    }

    func synchronize() {
        guard isAuthorized else { return }
        let failures = scheduler.rebuildMonitoring(for: rules)
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    // MARK: - iCloud preferences

    /// Reconciles portable rule preferences. macOS cannot create or interpret
    /// FamilyControls tokens, so applying a cloud rule always keeps the iPhone's
    /// existing selectionData intact.
    func syncICloudPreferences() {
        do {
            cloudStore.synchronize()
            var document = try cloudStore.load()
            var pending: Set<UUID> = []
            var didChangeRules = false

            for tombstone in document.tombstones {
                guard let index = rules.firstIndex(where: { $0.id == tombstone.id }),
                      tombstone.modifiedAt > rules[index].preferenceModifiedAt
                else { continue }
                if isRuleEditingLocked(tombstone.id) {
                    pending.insert(tombstone.id)
                } else {
                    rules.remove(at: index)
                    ruleUnlockProcesses[tombstone.id] = nil
                    didChangeRules = true
                }
            }

            let localTombstones = CloudTombstonePersistence.load()
            for cloudRule in document.rules {
                if let deletion = localTombstones.first(where: { $0.id == cloudRule.id }),
                   deletion.modifiedAt >= cloudRule.modifiedAt { continue }

                guard let index = rules.firstIndex(where: { $0.id == cloudRule.id }) else {
                    rules.append(CloudRuleBridge.applying(cloudRule, to: nil))
                    didChangeRules = true
                    continue
                }
                guard cloudRule.modifiedAt > rules[index].preferenceModifiedAt else { continue }

                let proposed = CloudRuleBridge.applying(cloudRule, to: rules[index])
                let canApply = !isRuleEditingLocked(cloudRule.id)
                    || RuleRestrictionEvaluator.compare(
                        existing: rules[index],
                        proposed: proposed,
                        appDefaultLockdown: lockdownConfiguration
                    ) == .strictlyMoreRestrictive
                if canApply {
                    rules[index] = proposed
                    didChangeRules = true
                } else {
                    pending.insert(cloudRule.id)
                }
            }

            if didChangeRules {
                try SharedConfiguration.saveRules(rules)
                saveRuleUnlockProcesses()
                refreshRuleLockdowns()
                updateSystemHardening()
                synchronize()
            }

            rules.map(CloudRuleBridge.cloudPreference(from:)).forEach { document.merge(rule: $0) }
            localTombstones.forEach { document.merge(tombstone: $0) }
            try cloudStore.save(document)
            pendingCloudRuleIDs = pending
            cloudSyncStatus = pending.isEmpty
                ? "Synced"
                : "(pending.count) locked change\(pending.count == 1 ? "" : "s") pending"
        } catch {
            cloudSyncStatus = "Sync failed"
            errorMessage = "iCloud preference sync failed: \(error.localizedDescription)"
        }
    }

    private func publishICloudPreferences() {
        do {
            _ = try cloudStore.merge(
                rules: rules.map(CloudRuleBridge.cloudPreference(from:)),
                tombstones: CloudTombstonePersistence.load()
            )
            cloudSyncStatus = "Synced"
        } catch {
            cloudSyncStatus = "Sync failed"
            errorMessage = "Rules were saved on this iPhone, but iCloud sync failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persistAndSchedule() -> Bool {
        do {
            try SharedConfiguration.saveRules(rules)
        } catch {
            errorMessage = "Could not save rules: \(error.localizedDescription)"
            return false
        }
        refreshRuleLockdowns()
        updateSystemHardening()
        synchronize()
        publishICloudPreferences()
        return true
    }
}
