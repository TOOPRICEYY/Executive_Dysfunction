import Combine
@preconcurrency import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var rules: [BlockingRule]
    @Published private(set) var activityGroups: [CloudActivityGroup] = []
    @Published private(set) var baseline = CloudBaseline()
    @Published private(set) var retreats: [CloudRetreat] = []
    @Published private(set) var timeWindowTemplates: [CloudTimeWindowTemplate] = []
    @Published private(set) var authorizationStatus: AuthorizationStatus
    @Published private(set) var antiUninstallEnabled: Bool
    @Published private(set) var lockdownConfiguration: LockdownConfiguration
    @Published private(set) var unlockPhase: UnlockPhase = .idle
    @Published private(set) var ruleUnlockPhases: [UUID: UnlockPhase] = [:]
    @Published private(set) var retreatUnlockPhases: [UUID: UnlockPhase] = [:]
    @Published private(set) var cloudSyncStatus = "Not synced"
    @Published private(set) var pendingCloudRuleIDs: Set<UUID> = []
    @Published private(set) var ruleTimeAllowances: [UUID: RuleTimeAllowance]
    @Published private(set) var pendingTemporaryAccessRequest: PendingTemporaryAccessRequest?
    @Published var errorMessage: String?
    @Published var isRequestingAuthorization = false
    @Published private(set) var timedLockdowns = SharedConfiguration.loadTimedLockdowns()
    @Published private(set) var lockdownMonitoringFailures: Set<UUID> = []
    @Published private(set) var lockdownSyncStatus = "Lockdowns use all devices"
    private let lockdownCloudStore = ICloudLockdownStore()

    var activeTimedLockdowns: [TimedLockdownSession] { timedLockdowns.filter { $0.isActive(at: Date()) } }
    var lockdownExpirations: [UUID: Date] { TimedLockdownSession.expirations(timedLockdowns, at: Date()) }

    @discardableResult
    func startTimedLockdown(ruleIDs: Set<UUID>, hours: Int) -> Bool {
        guard isAuthorized, !ruleIDs.isEmpty, (1...168).contains(hours) else {
            errorMessage = "Connect Screen Time, select groups, and choose a duration between one hour and seven days."
            return false
        }
        let selected = rules.filter { ruleIDs.contains($0.id) }
        guard selected.count == ruleIDs.count else {
            errorMessage = "The selected groups changed. Reopen lockdown and choose them again."
            return false
        }
        guard selected.allSatisfy({ $0.enforcementMode == .fortressAllowList || $0.selectedItemCount > 0 || !$0.enforcedDomains.isEmpty }) else {
            errorMessage = "One of the selected groups has no apps or websites that this iOS device can block. Add its targets first."
            return false
        }
        let now = Date()
        let session = TimedLockdownSession(rules: selected, startedAt: now,
            endsAt: now.addingTimeInterval(Double(hours) * 3_600),
            earlyExitPassage: CommitmentPassage.generate(wordCount: 80))
        do {
            try scheduler.startLockdown(session)
            timedLockdowns = SharedConfiguration.loadTimedLockdowns()
            lockdownMonitoringFailures.remove(session.id)
            reconcileSharedLockdowns()
            return true
        } catch {
            errorMessage = "Lockdown was not started. Screen Time could not register its expiry: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func endTimedLockdown(_ session: TimedLockdownSession, passage: String) -> Bool {
        guard let saved = SharedConfiguration.loadTimedLockdowns().first(where: { $0.id == session.id }),
              CommitmentPassage.matches(passage, passage: saved.earlyExitPassage) else { return false }
        // A lockdown created on a Mac can require days/checkpoints. Receiving
        // it on iOS must not downgrade that policy to a single passage.
        let exitKey = "lockdown.ios-session-exits.v1"
        var exits = UserDefaults.standard.data(forKey: exitKey).flatMap {
            try? JSONDecoder().decode([UUID: UnlockProcess].self, from: $0)
        } ?? [:]
        let now = Date()
        let configuration = saved.exitConfiguration
        switch Lockdown.phase(of: exits[saved.id], configuration: configuration, at: now) {
        case .idle, .cancelled: exits[saved.id] = UnlockProcess(startedAt: now)
        case .confirmationDue: exits[saved.id]?.confirmedAt.append(now)
        case .waiting, .unlocked: break
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(exits), forKey: exitKey)
        if configuration.isEnabled {
            guard case .unlocked = Lockdown.phase(of: exits[saved.id], configuration: configuration, at: now) else {
                errorMessage = "Exit request recorded. The lockdown remains active until its saved delay and confirmation requirements are complete."
                return false
            }
        }
        do {
            try scheduler.endLockdown(saved)
            try lockdownCloudStore.recordAuthorizedCancellation(id: saved.id, endsAt: saved.endsAt)
            timedLockdowns = SharedConfiguration.loadTimedLockdowns()
            exits.removeValue(forKey: saved.id)
            UserDefaults.standard.set(try? JSONEncoder().encode(exits), forKey: exitKey)
            reconcileSharedLockdowns()
            return true
        } catch {
            errorMessage = "Lockdown could not be ended: \(error.localizedDescription)"
            return false
        }
    }

    private let authorizationCenter = AuthorizationCenter.shared
    private let scheduler = RuleScheduler()
    private let cloudStore = ICloudPreferencesStore()
    /// Readable across the module so diagnostics can report the exact graph the
    /// model is working from, rather than a re-derived approximation of it.
    private(set) var cloudDocument = CloudPreferencesDocument()
    private var unlockProcess: UnlockProcess?
    private var ruleUnlockProcesses: [UUID: UnlockProcess]
    private var retreatUnlockProcesses: [UUID: UnlockProcess]

    init() {
        rules = SharedConfiguration.loadRules()
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        antiUninstallEnabled = SharedConfiguration.antiUninstallEnabled
        lockdownConfiguration = SharedConfiguration.loadLockdownConfiguration()
        unlockProcess = SharedConfiguration.loadUnlockProcess()
        ruleUnlockProcesses = SharedConfiguration.loadRuleUnlockProcesses()
        retreatUnlockProcesses = SharedConfiguration.loadRetreatUnlockProcesses()
        ruleTimeAllowances = SharedConfiguration.loadRuleTimeAllowances()
        pendingTemporaryAccessRequest = ShieldTemporaryAccessCoordinator.loadPendingRequest()
        bootstrapPortableArchitecture()
        refreshLockdown()
        refreshRuleLockdowns()
        refreshRetreatLockdowns()
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

    var dashboardBlockingRules: [CloudRulePreference] {
        let normal = cloudDocument.dashboardBlockingRules()
        var known = Set(normal.map(\.id))
        return normal + activeTimedLockdowns.flatMap(\.rules).filter { known.insert($0.id).inserted }.map(CloudRuleBridge.cloudPreference)
    }

    var dashboardCalendarRules: [BlockStatusCalendarRule] {
        var intervals: [UUID: [DateInterval]] = [:]
        for session in activeTimedLockdowns {
            for rule in session.rules { intervals[rule.id, default: []].append(DateInterval(start: session.startedAt, end: session.endsAt)) }
        }
        return BlockStatusCalendarRule.applyingLockdowns(to: cloudDocument.dashboardCalendarRules(), rules: dashboardBlockingRules, intervals: intervals)
    }

    var activeRetreats: [CloudRetreat] {
        retreats.filter { $0.isActive(at: Date()) }
    }

    var completedRetreats: [CloudRetreat] {
        retreats.filter { $0.state == .completed || $0.state == .endedEarly }
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
                guard change != .requiresUnlock else {
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

    // MARK: - Retreat change policy

    func retreatChangePolicy(for id: UUID) -> CloudRetreatChangePolicy? {
        guard let retreat = retreats.first(where: { $0.id == id }) else { return nil }
        return CloudRetreatEarlyEndGate.policy(
            for: retreat,
            appDefault: retreatAppDefaultPolicy
        )
    }

    func retreatUnlockPhase(for id: UUID, now: Date = Date()) -> UnlockPhase {
        guard let policy = retreatChangePolicy(for: id) else { return .idle }
        return Lockdown.phase(
            of: retreatUnlockProcesses[id],
            configuration: lockdownConfiguration(for: policy),
            at: now
        )
    }

    func refreshRetreatLockdowns(now: Date = Date()) {
        let knownIDs = Set(retreats.filter { $0.state == .active }.map(\.id))
        retreatUnlockProcesses = retreatUnlockProcesses.filter { knownIDs.contains($0.key) }
        var phases: [UUID: UnlockPhase] = [:]
        var cancelledNames: [String] = []
        for retreat in retreats where retreat.state == .active {
            let phase = retreatUnlockPhase(for: retreat.id, now: now)
            switch phase {
            case .cancelled:
                retreatUnlockProcesses[retreat.id] = nil
                phases[retreat.id] = .idle
                cancelledNames.append(retreat.name)
            case .idle:
                retreatUnlockProcesses[retreat.id] = nil
                phases[retreat.id] = .idle
            default:
                phases[retreat.id] = phase
            }
        }
        retreatUnlockPhases = phases
        SharedConfiguration.saveRetreatUnlockProcesses(retreatUnlockProcesses)
        if !cancelledNames.isEmpty {
            errorMessage = "Retreat change cancelled after a missed confirmation: \(cancelledNames.joined(separator: ", "))."
        }
    }

    func startRetreatUnlock(_ id: UUID, now: Date = Date()) {
        guard let policy = retreatChangePolicy(for: id),
              policy.requiresAuthorization,
              retreatUnlockProcesses[id] == nil
        else { return }
        retreatUnlockProcesses[id] = UnlockProcess(startedAt: now)
        SharedConfiguration.saveRetreatUnlockProcesses(retreatUnlockProcesses)
        refreshRetreatLockdowns(now: now)
    }

    func confirmRetreatUnlock(_ id: UUID, now: Date = Date()) {
        guard let policy = retreatChangePolicy(for: id),
              var process = retreatUnlockProcesses[id]
        else { return }
        guard case .confirmationDue = Lockdown.phase(
            of: process,
            configuration: lockdownConfiguration(for: policy),
            at: now
        ) else {
            errorMessage = "This Retreat confirmation is not due yet, or its deadline has passed."
            refreshRetreatLockdowns(now: now)
            return
        }
        process.confirmedAt.append(now)
        retreatUnlockProcesses[id] = process
        SharedConfiguration.saveRetreatUnlockProcesses(retreatUnlockProcesses)
        refreshRetreatLockdowns(now: now)
    }

    func cancelRetreatUnlock(_ id: UUID) {
        retreatUnlockProcesses[id] = nil
        SharedConfiguration.saveRetreatUnlockProcesses(retreatUnlockProcesses)
        refreshRetreatLockdowns()
    }

    private var retreatAppDefaultPolicy: CloudRuleLockdownPreference {
        CloudRuleLockdownPreference(
            severity: lockdownConfiguration.isEnabled
                ? (lockdownConfiguration.repeatConfirmations ? "repeatedConfirmations" :
                    (lockdownConfiguration.unlockDelayDays > 0 ? "delayed" : "passageOnly"))
                : "none",
            unlockDelayDays: lockdownConfiguration.unlockDelayDays,
            passageWordCount: lockdownConfiguration.passageWordCount,
            confirmationWindowHours: lockdownConfiguration.confirmationWindowHours,
            editWindowHours: lockdownConfiguration.editWindowHours
        )
    }

    func temporaryAccessPolicyWarning(_ policy: CloudRuleLockdownPreference, inheritsBaseline: Bool) -> String? {
        let effective = CloudRuleLockdownPreference.restrictiveMaximum(
            inheritsBaseline ? [baseline.modificationPolicy, policy] : [policy],
            appDefault: retreatAppDefaultPolicy
        )
        return TemporaryAccessPolicyComparison.warning(changePolicy: effective, temporaryPolicy: effective)
    }

    private func lockdownConfiguration(for policy: CloudRetreatChangePolicy) -> LockdownConfiguration {
        var configuration = LockdownConfiguration()
        configuration.isEnabled = policy.requiresAuthorization
        configuration.unlockDelayDays = policy.unlockDelayDays
        configuration.repeatConfirmations = policy.repeatConfirmations
        configuration.passageWordCount = policy.passageWordCount
        configuration.confirmationWindowHours = policy.confirmationWindowHours
        configuration.editWindowHours = policy.editWindowHours
        return configuration
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
        guard TimedLockdownSession.expirations(timedLockdowns, at: now)[ruleID] == nil else { return nil }
        if let stored = SharedConfiguration.activeTimeAllowance(for: ruleID, at: now) {
            return stored
        }
        guard let allowance = ruleTimeAllowances[ruleID], allowance.isActive(at: now) else { return nil }
        return allowance
    }

    func timeAllowancePassageWordCount(for ruleID: UUID, now: Date = Date()) -> Int {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return 40 }
        let base = rule.lockdownPolicy.temporaryAccessPassageWordCount
            ?? ruleLockdownConfiguration(for: rule).passageWordCount
        let granted = activeTimeAllowance(for: ruleID, now: now)?.grantCount ?? 0
        let sessionWords = TimeAllowancePolicy.passageWordCount(base: base, incrementsAlreadyGranted: granted)
        if let days = rule.lockdownPolicy.temporaryAllowanceResetDays {
            return TemporaryAllowanceBackoff.wordCount(base: base,
                history: SharedConfiguration.allowanceBackoffHistory(for: ruleID), resetDays: days, at: now,
                sessionWordCount: sessionWords)
        }
        return sessionWords
    }

    func nextTimeAllowanceIncrement(for ruleID: UUID, now: Date = Date()) -> Int {
        (activeTimeAllowance(for: ruleID, now: now)?.grantCount ?? 0) + 1
    }

    @discardableResult
    func grantTimeAllowance(for ruleID: UUID, now: Date = Date()) -> Bool {
        grantTimeAllowance(for: ruleID, duration: .sixtyMinutes, now: now)
    }

    @discardableResult
    func grantTimeAllowance(
        for ruleID: UUID,
        duration: TemporaryAccessDuration,
        verifiedWordCount: Int? = nil,
        intent: BypassEvent.Intent? = nil,
        reflection: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard TimedLockdownSession.expirations(SharedConfiguration.loadTimedLockdowns(), at: now)[ruleID] == nil else {
            errorMessage = "This group is held by a lockdown. End the lockdown before requesting temporary access."
            return false
        }
        guard let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              rule.lockdownPolicy.allowsTimeExtensions
        else {
            errorMessage = "Additional time is not enabled for this rule."
            return false
        }

        if rule.lockdownPolicy.temporaryAllowanceResetDays != nil || rule.lockdownPolicy.temporaryAccessPassageWordCount != nil,
           verifiedWordCount != timeAllowancePassageWordCount(for: ruleID, now: now) {
            errorMessage = "The required passage changed. Reopen temporary access and type the new passage."
            return false
        }
        let existing = SharedConfiguration.activeTimeAllowance(for: ruleID, at: now)
            ?? activeTimeAllowance(for: ruleID, now: now)
        let minutesGranted = existing?.totalMinutesGranted ?? 0
        guard TimeAllowancePolicy.canGrant(
            duration,
            afterMinutes: minutesGranted,
            maximumHours: rule.lockdownPolicy.maximumTimeExtensionHours
        ) else {
            errorMessage = "This pause would exceed the rule's configured maximum of \(rule.lockdownPolicy.maximumTimeExtensionHours) additional hour(s) for the current allowance session."
            return false
        }
        if existing == nil,
           RuleScheduler.requiredActivityCount(for: rules) + 1 > RuleScheduler.maximumConcurrentActivities {
            errorMessage = "No Screen Time monitor slot is available for a temporary pause. Remove or combine a time block first."
            return false
        }

        let baseDate = existing?.expiresAt ?? now
        let allowance = RuleTimeAllowance(
            ruleID: ruleID,
            expiresAt: baseDate.addingTimeInterval(duration.seconds),
            totalMinutesGranted: minutesGranted + duration.minutes,
            grantCount: (existing?.grantCount ?? 0) + 1,
            restoreUsageShield: (existing?.restoreUsageShield ?? false)
                || EnforcementEngine.usageShieldIsConfigured(ruleID: ruleID)
        )
        var storedAllowances = SharedConfiguration.loadRuleTimeAllowances()
        storedAllowances[ruleID] = allowance
        ruleTimeAllowances = storedAllowances
        SharedConfiguration.saveRuleTimeAllowances(storedAllowances)
        synchronize()
        // Rebuilding may reject the expiry monitor and revoke this grant.
        guard SharedConfiguration.activeTimeAllowance(for: ruleID, at: now) != nil else { return false }
        if let days = rule.lockdownPolicy.temporaryAllowanceResetDays {
            SharedConfiguration.recordAllowanceBackoff(for: ruleID, resetDays: days, at: now)
        }
        BypassHistoryStore.record([BypassEvent(id: UUID(), groupID: ruleID, groupName: rule.name,
            grantedAt: now, expiresAt: allowance.expiresAt, grantedMinutes: duration.minutes, source: .app, intent: intent,
            reflection: reflection)],
            defaults: SharedConfiguration.bypassHistoryDefaults, at: now)
        return true
    }

    func availableTemporaryAccessDurations(
        for ruleID: UUID,
        now: Date = Date()
    ) -> [TemporaryAccessDuration] {
        guard let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              rule.lockdownPolicy.allowsTimeExtensions else { return [] }
        let minutesGranted = activeTimeAllowance(for: ruleID, now: now)?.totalMinutesGranted ?? 0
        return TemporaryAccessDuration.allCases.filter {
            TimeAllowancePolicy.canGrant(
                $0,
                afterMinutes: minutesGranted,
                maximumHours: rule.lockdownPolicy.maximumTimeExtensionHours
            )
        }
    }

    func refreshPendingTemporaryAccessRequest(now: Date = Date()) {
        pendingTemporaryAccessRequest = ShieldTemporaryAccessCoordinator.loadPendingRequest(now: now)
    }

    func clearPendingTemporaryAccessRequest(id: UUID) {
        ShieldTemporaryAccessCoordinator.clearPendingRequest(id: id)
        if pendingTemporaryAccessRequest?.id == id {
            pendingTemporaryAccessRequest = nil
        }
    }

    /// Revalidates the shield's device-local request before granting access. A
    /// stale sheet cannot target a different rule or consume a newer request.
    @discardableResult
    func grantPendingTemporaryAccess(
        requestID: UUID,
        for ruleID: UUID,
        duration selectedDuration: TemporaryAccessDuration? = nil,
        verifiedWordCount: Int? = nil,
        intent: BypassEvent.Intent? = nil,
        reflection: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let request = ShieldTemporaryAccessCoordinator.loadPendingRequest(now: now),
              request.id == requestID,
              request.eligibleRuleIDs.contains(ruleID),
              let duration = request.duration ?? selectedDuration
        else {
            errorMessage = "This temporary access request expired or no longer matches that rule."
            refreshPendingTemporaryAccessRequest(now: now)
            return false
        }
        guard rules.contains(where: { $0.id == ruleID }),
              ShieldTemporaryAccessCoordinator.currentlyEnforcedRuleIDs(in: rules).contains(ruleID),
              activeTimeAllowance(for: ruleID, now: now) == nil
        else {
            errorMessage = "That rule is no longer the active blocker for this request."
            clearPendingTemporaryAccessRequest(id: request.id)
            return false
        }
        guard grantTimeAllowance(for: ruleID, duration: duration, verifiedWordCount: verifiedWordCount,
                                 intent: intent, reflection: reflection, now: now) else { return false }
        clearPendingTemporaryAccessRequest(id: request.id)
        return true
    }

    func refreshTimeAllowances(now: Date = Date()) {
        ruleTimeAllowances = SharedConfiguration.loadRuleTimeAllowances()
        let expired = ruleTimeAllowances.values.filter { !$0.isActive(at: now) }
        guard !expired.isEmpty else { return }
        for allowance in expired {
            ruleTimeAllowances[allowance.ruleID] = nil
            if allowance.restoreUsageShield,
               let rule = rules.first(where: { $0.id == allowance.ruleID && $0.isEnabled && $0.usageLimitEnabled }) {
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
           let rule = rules.first(where: { $0.id == ruleID && $0.isEnabled && $0.usageLimitEnabled }) {
            EnforcementEngine.apply(
                rule,
                to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: ruleID).storeName)
            )
        }
    }

    func refreshAuthorizationAndEnforcement() {
        authorizationStatus = authorizationCenter.authorizationStatus
        refreshLockdown()
        refreshRuleLockdowns()
        refreshTimeAllowances()
        syncICloudPreferences()
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
        timedLockdowns = SharedConfiguration.loadTimedLockdowns()
        lockdownMonitoringFailures = scheduler.unmonitoredLockdowns(at: Date())
        // Groups that were switched off, and every group belonging to a Retreat
        // that has ended, keep shield stores the compiled rules no longer name.
        // Nothing else will ever lift those.
        scheduler.sweepUnenforcedShieldStores(document: cloudDocument)
        refreshTimeAllowances()
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    // MARK: - Portable activity architecture

    func localSelection(for activityGroupID: UUID) -> FamilyActivitySelection {
        ActivityGroupSelectionPersistence.selection(for: activityGroupID)
    }

    @discardableResult
    func saveActivityGroup(
        _ value: CloudActivityGroup,
        selection: FamilyActivitySelection
    ) -> Bool {
        let previousSelection = ActivityGroupSelectionPersistence.selection(for: value.id)
        var document = cloudDocument
        var group = value
        group.name = normalizedName(group.name, fallback: "Activity group")
        group.modifiedAt = Date()
        group.deviceLocalSelectionCount = selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
        if let index = document.activityGroups.firstIndex(where: { $0.id == group.id }) {
            document.activityGroups[index] = group
        } else {
            document.activityGroups.append(group)
        }
        ActivityGroupSelectionPersistence.save(selection, for: group.id)
        guard commitArchitectureDocument(document, status: "Activity Group saved") else {
            // The opaque FamilyControls tokens are part of the secured Activity
            // Group edit on this device. Keep them transactionally aligned with
            // the portable object graph when a lock rejects the change.
            ActivityGroupSelectionPersistence.save(previousSelection, for: group.id)
            return false
        }
        return true
    }

    @discardableResult
    func deleteActivityGroup(_ value: CloudActivityGroup) -> Bool {
        var document = cloudDocument
        document.deleteActivityGroup(id: value.id)
        guard commitArchitectureDocument(document, status: "Activity Group deleted") else {
            return false
        }
        ActivityGroupSelectionPersistence.remove(value.id)
        return true
    }

    /// Adds a ready-made Blocking Group (and any Activity Groups it needs).
    /// On iPhone the preset's websites apply immediately; apps and categories
    /// can be added to its Activity Groups with the Screen Time picker.
    @discardableResult
    func installPreset(_ preset: HoldfastPresets.BlockingPreset) -> Bool {
        var document = cloudDocument
        HoldfastPresets.install(preset, into: &document)
        return commitArchitectureDocument(document, status: "\(preset.name) added")
    }

    @discardableResult
    func saveBlockingGroup(_ value: CloudBlockingGroup) -> Bool {
        var document = cloudDocument
        var group = value
        group.name = normalizedName(group.name, fallback: "Blocking group")
        group.modifiedAt = Date()
        group.activityGroupIDs = Array(Set(group.activityGroupIDs))
        guard group.targets != nil || !group.activityGroupIDs.isEmpty else {
            errorMessage = "Add this Blocking Group's apps or websites before saving."
            return false
        }
        let isNew = !document.baseline.blockingGroups.contains { $0.id == group.id }
        if let index = document.baseline.blockingGroups.firstIndex(where: { $0.id == group.id }) {
            document.baseline.blockingGroups[index] = group
        } else {
            document.baseline.blockingGroups.append(group)
        }
        document.baseline.modifiedAt = group.modifiedAt
        return commitArchitectureDocument(
            document,
            status: "Blocking Group saved",
            allowingDisabledAdditionID: isNew && !group.isEnabled ? group.id : nil
        )
    }

    func selectionForBlockingGroup(_ group: CloudBlockingGroup) -> FamilyActivitySelection {
        if let direct = BlockingGroupSelectionPersistence.selection(for: group.id) { return direct }
        if let source = group.sourceBlockingGroupID,
           let direct = BlockingGroupSelectionPersistence.selection(for: source) { return direct }
        var combined = FamilyActivitySelection()
        for id in group.activityGroupIDs {
            let selection = ActivityGroupSelectionPersistence.selection(for: id)
            combined.applicationTokens.formUnion(selection.applicationTokens)
            combined.categoryTokens.formUnion(selection.categoryTokens)
            combined.webDomainTokens.formUnion(selection.webDomainTokens)
        }
        return combined
    }

    func saveBlockingGroup(_ value: CloudBlockingGroup, selection: FamilyActivitySelection) -> Bool {
        let previous = BlockingGroupSelectionPersistence.data(for: value.id)
        var group = value
        if group.targets == nil { group = group.owningTargets(from: activityGroups, containerPolicy: baseline.modificationPolicy) }
        group.targets?.deviceLocalSelectionCount = selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
        BlockingGroupSelectionPersistence.save(selection, for: group.id)
        guard saveBlockingGroup(group) else {
            BlockingGroupSelectionPersistence.restore(previous, for: group.id)
            return false
        }
        return true
    }

    func setBlockingGroupEnabled(_ id: UUID, enabled: Bool) {
        guard let index = baseline.blockingGroups.firstIndex(where: { $0.id == id }) else { return }
        var group = baseline.blockingGroups[index]
        group.isEnabled = enabled
        _ = saveBlockingGroup(group)
    }

    @discardableResult
    func deleteBlockingGroup(_ value: CloudBlockingGroup) -> Bool {
        var document = cloudDocument
        document.baseline.blockingGroups.removeAll { $0.id == value.id }
        document.baseline.modifiedAt = Date()
        return commitArchitectureDocument(document, status: "Blocking Group deleted")
    }

    @discardableResult
    func saveRetreat(
        id: UUID? = nil,
        name: String,
        goal: String,
        plannedStart: Date,
        plannedEnd: Date,
        sourceBlockingGroups: [CloudBlockingGroup],
        modificationPolicy: CloudRuleLockdownPreference,
        startImmediately: Bool
    ) -> Bool {
        var document = cloudDocument
        guard !sourceBlockingGroups.isEmpty else {
            errorMessage = "A Retreat must contain at least one Blocking Group."
            return false
        }
        let now = Date()
        var retreat: CloudRetreat
        if let id, let index = document.retreats.firstIndex(where: { $0.id == id }) {
            retreat = document.retreats[index]
            let retreatGroups = CloudRetreatGroupVersioning.versionedGroups(
                from: sourceBlockingGroups,
                replacing: retreat.currentVersion?.blockingGroups ?? [],
                at: now
            )
            retreat.name = normalizedName(name, fallback: "Retreat")
            retreat.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            retreat.plannedStart = plannedStart
            retreat.plannedEnd = max(plannedStart.addingTimeInterval(60), plannedEnd)
            retreat.appendVersion(
                blockingGroups: retreatGroups,
                modificationPolicy: modificationPolicy,
                at: now
            )
            if startImmediately { retreat.start(at: now) }
            document.retreats[index] = retreat
        } else {
            let retreatGroups = CloudRetreatGroupVersioning.versionedGroups(
                from: sourceBlockingGroups,
                replacing: [],
                at: now
            )
            retreat = CloudRetreat(
                name: normalizedName(name, fallback: "Retreat"),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                plannedStart: plannedStart,
                    plannedEnd: max(plannedStart.addingTimeInterval(60), plannedEnd),
                    state: .draft,
                    modificationPolicy: modificationPolicy
            )
            retreat.appendVersion(
                blockingGroups: retreatGroups,
                modificationPolicy: modificationPolicy,
                at: now
            )
            if startImmediately { retreat.start(at: now) }
            document.retreats.append(retreat)
        }
        return commitArchitectureDocument(
            document,
            status: startImmediately
                ? (retreat.state == .scheduled ? "Retreat scheduled" : "Retreat active")
                : (retreat.state == .draft ? "Retreat draft saved" : "Retreat changes saved")
        )
    }

    @discardableResult
    func finishRetreat(_ id: UUID, early: Bool = true, now: Date = Date()) -> Bool {
        var document = cloudDocument
        guard let index = document.retreats.firstIndex(where: { $0.id == id }) else { return false }
        let retreat = document.retreats[index]
        let policy = CloudRetreatEarlyEndGate.policy(for: retreat, appDefault: retreatAppDefaultPolicy)
        let authorizationIsUnlocked: Bool
        if case .unlocked = retreatUnlockPhase(for: id, now: now) {
            authorizationIsUnlocked = true
        } else {
            authorizationIsUnlocked = false
        }
        if early, !CloudRetreatEarlyEndGate.canEndEarly(
            retreat,
            authorizationIsUnlocked: authorizationIsUnlocked,
            appDefault: retreatAppDefaultPolicy
        ) {
            errorMessage = "Complete this Retreat’s change policy before ending it early."
            return false
        }
        document.retreats[index].finish(early: early, at: now)
        let committed = commitArchitectureDocument(
            document,
            status: "Retreat ended",
            authorizedEarlyEndRetreatID: early && policy.requiresAuthorization ? id : nil
        )
        if committed {
            retreatUnlockProcesses[id] = nil
            SharedConfiguration.saveRetreatUnlockProcesses(retreatUnlockProcesses)
            refreshRetreatLockdowns(now: now)
        }
        return committed
    }

    func recreateRetreat(_ source: CloudRetreat) {
        var copy = source
        copy.id = UUID()
        copy.name = "\(source.name) — New"
        copy.state = .draft
        copy.plannedStart = Date()
        let priorDuration = max(60, source.plannedEnd.timeIntervalSince(source.plannedStart))
        copy.plannedEnd = copy.plannedStart.addingTimeInterval(priorDuration)
        copy.modifiedAt = Date()
        copy.runs = []
        copy.versions = source.currentVersion.map { version in
            [CloudRetreatVersion(
                number: 1,
                createdAt: Date(),
                blockingGroups: version.blockingGroups,
                modificationPolicy: version.modificationPolicy
            )]
        } ?? []
        copy.currentVersionNumber = copy.versions.isEmpty ? 0 : 1
        var document = cloudDocument
        document.retreats.append(copy)
        _ = commitArchitectureDocument(document, status: "Retreat recreated as draft")
    }

    private func bootstrapPortableArchitecture() {
        var document = (try? cloudStore.load()) ?? CloudPreferencesDocument()
        if document.activityGroups.isEmpty,
           document.baseline.blockingGroups.isEmpty,
           !rules.isEmpty {
            rules.map(CloudRuleBridge.cloudPreference(from:)).forEach { document.merge(rule: $0) }
        }
        document.migrateLegacyRulesIfNeeded()
        for rule in rules {
            ActivityGroupSelectionPersistence.seedLegacySelection(rule.selectionData, for: rule.id)
        }
        applyArchitectureDocument(document)
    }

    @discardableResult
    private func commitArchitectureDocument(
        _ source: CloudPreferencesDocument,
        status: String,
        allowingDisabledAdditionID: UUID? = nil,
        authorizedEarlyEndRetreatID: UUID? = nil
    ) -> Bool {
        let isSafeDisabledAddition = allowingDisabledAdditionID.map {
            isOnlyDisabledBlockingGroupAddition(source, id: $0)
        } ?? false
        let comparisonDate = Date()
        var document = source
        document.reconcileRetreatLifecycles(at: comparisonDate)
        document.rebuildLegacyRuleProjection(at: comparisonDate)
        let proposedRules = localRuleProjection(from: document, at: comparisonDate)
        let acceptedRules: [BlockingRule]
        if let authorizedEarlyEndRetreatID,
           isOnlyAuthorizedEarlyRetreatEnd(source, id: authorizedEarlyEndRetreatID) {
            acceptedRules = proposedRules
        } else if architectureChangeIsAllowed(
            proposedRules,
            proposedDocument: document,
            at: comparisonDate
        ) {
            acceptedRules = preservingUnchangedLockedProjections(
                proposedRules,
                proposedDocument: document,
                at: comparisonDate
            )
        } else if isSafeDisabledAddition,
                  let additionID = allowingDisabledAdditionID,
                  let addedRule = proposedRules.first(where: { $0.id == additionID && !$0.isEnabled }) {
            // A disabled group cannot alter current enforcement. Preserve every
            // existing local projection byte-for-byte if rebuilding legacy
            // projections would otherwise make this additive draft look like a
            // weakening of an unrelated locked group.
            acceptedRules = rules.filter { $0.id != additionID } + [addedRule]
        } else {
            errorMessage = architectureChangeRejectionMessage(proposedRules, proposedDocument: document, at: comparisonDate)
            return false
        }
        do {
            try cloudStore.save(document)
            applyArchitectureDocument(document, projectedRules: acceptedRules)
            try SharedConfiguration.saveRules(rules)
            refreshRuleLockdowns()
            updateSystemHardening()
            synchronize()
            cloudSyncStatus = status
            return true
        } catch {
            cloudSyncStatus = "Sync failed"
            errorMessage = "Could not save the Blocking Groups: \(error.localizedDescription)"
            return false
        }
    }

    private func isOnlyAuthorizedEarlyRetreatEnd(
        _ proposed: CloudPreferencesDocument,
        id: UUID
    ) -> Bool {
        guard let proposedRetreat = proposed.retreats.first(where: { $0.id == id }),
              proposedRetreat.state == .endedEarly,
              let existingIndex = cloudDocument.retreats.firstIndex(where: { $0.id == id }),
              cloudDocument.retreats[existingIndex].state == .active
        else { return false }
        var expected = cloudDocument
        expected.retreats[existingIndex].finish(early: true, at: proposedRetreat.modifiedAt)
        return proposed == expected
    }

    private func isOnlyDisabledBlockingGroupAddition(
        _ proposed: CloudPreferencesDocument,
        id: UUID
    ) -> Bool {
        guard !cloudDocument.baseline.blockingGroups.contains(where: { $0.id == id }),
              let addition = proposed.baseline.blockingGroups.first(where: { $0.id == id }),
              !addition.isEnabled,
              proposed.activityGroups == cloudDocument.activityGroups,
              proposed.retreats == cloudDocument.retreats,
              proposed.timeWindowTemplates == cloudDocument.timeWindowTemplates,
              proposed.activityGroupTombstones == cloudDocument.activityGroupTombstones,
              proposed.tombstones == cloudDocument.tombstones,
              proposed.baseline.id == cloudDocument.baseline.id,
              proposed.baseline.modificationPolicy == cloudDocument.baseline.modificationPolicy
        else { return false }

        return proposed.baseline.blockingGroups.filter { $0.id != id }
            == cloudDocument.baseline.blockingGroups
    }

    private func applyArchitectureDocument(
        _ source: CloudPreferencesDocument,
        projectedRules: [BlockingRule]? = nil
    ) {
        var document = source
        document.migrateLegacyRulesIfNeeded()
        document.migrateBlockingGroupOwnership()
        captureOwnedSelections(in: document)
        document.reconcileRetreatLifecycles()
        document.rebuildLegacyRuleProjection()
        cloudDocument = document
        activityGroups = document.activityGroups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        baseline = document.baseline
        retreats = document.retreats.sorted { $0.modifiedAt > $1.modifiedAt }
        timeWindowTemplates = document.timeWindowTemplates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        rules = projectedRules ?? localRuleProjection(from: document)
    }

    private func captureOwnedSelections(in document: CloudPreferencesDocument) {
        let groups = document.baseline.blockingGroups + document.retreats.flatMap { retreat in
            retreat.versions.flatMap(\.blockingGroups)
        }
        for group in groups where group.targets != nil && BlockingGroupSelectionPersistence.data(for: group.id) == nil {
            let sourceAvailable = group.sourceBlockingGroupID.flatMap { BlockingGroupSelectionPersistence.data(for: $0) } != nil
            guard sourceAvailable || group.activityGroupIDs.contains(where: { ActivityGroupSelectionPersistence.hasSelection(for: $0) }) else { continue }
            BlockingGroupSelectionPersistence.save(selectionForBlockingGroup(group), for: group.id)
        }
    }

    private func localRuleProjection(
        from document: CloudPreferencesDocument,
        at date: Date = Date()
    ) -> [BlockingRule] {
        let existingByID = Dictionary(
            rules.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.preferenceModifiedAt >= candidate.preferenceModifiedAt ? current : candidate
            }
        )
        var blockingByID = Dictionary(
            document.baseline.blockingGroups.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.modifiedAt >= candidate.modifiedAt ? current : candidate
            }
        )
        for retreat in document.retreats where retreat.isActive(at: date) {
            for group in retreat.currentVersion?.blockingGroups ?? [] {
                blockingByID[group.id] = group
            }
        }

        return document.compiledRules(at: date).map { cloud in
            var rule = CloudRuleBridge.applying(cloud, to: existingByID[cloud.id])
            if let group = blockingByID[cloud.id] {
                rule.selection = selectionForBlockingGroup(group)
            }
            return rule
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func architectureChangeIsAllowed(
        _ proposedRules: [BlockingRule],
        proposedDocument: CloudPreferencesDocument,
        at date: Date
    ) -> Bool {
        guard Set(proposedRules.map(\.id)).count == proposedRules.count else {
            return false
        }
        let proposedByID = Dictionary(uniqueKeysWithValues: proposedRules.map { ($0.id, $0) })
        for existing in rules where isRuleEditingLocked(existing.id) {
            guard let proposed = proposedByID[existing.id] else { return false }
            if !RuleRestrictionEvaluator.requiresArchitectureUnlock(
                existing: existing,
                proposed: proposed,
                portableDefinitionUnchanged: portableRuleDefinitionIsUnchanged(existing.id, proposedDocument: proposedDocument, at: date),
                portableTargetsSameOrStricter: portableTargetsAreSameOrStricter(existing.id, proposedDocument: proposedDocument, at: date),
                appDefaultLockdown: lockdownConfiguration
            ) { continue }
            return false
        }
        return true
    }

    /// Recompiling an unrelated architectural object can normalize legacy
    /// metadata even when the locked portable definition is unchanged. Keep
    /// the exact accepted rule bytes in that case instead of silently rewriting
    /// a locked group while admitting an additive Retreat.
    private func preservingUnchangedLockedProjections(
        _ proposedRules: [BlockingRule],
        proposedDocument: CloudPreferencesDocument,
        at date: Date
    ) -> [BlockingRule] {
        let existingByID = Dictionary(
            rules.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.preferenceModifiedAt >= candidate.preferenceModifiedAt ? current : candidate
            }
        )
        return proposedRules.map { proposed in
            guard let existing = existingByID[proposed.id],
                  isRuleEditingLocked(existing.id),
                  proposed != existing,
                  RuleRestrictionEvaluator.compare(
                    existing: existing,
                    proposed: proposed,
                    appDefaultLockdown: lockdownConfiguration
                  ) == .equivalent,
                  portableRuleDefinitionIsUnchanged(
                    existing.id,
                    proposedDocument: proposedDocument,
                    at: date
                  )
            else { return proposed }
            return existing
        }
    }

    private func portableRuleDefinitionIsUnchanged(
        _ id: UUID,
        proposedDocument: CloudPreferencesDocument,
        at date: Date
    ) -> Bool {
        let existing = cloudDocument.compiledRules(at: date).first { $0.id == id }
        let proposed = proposedDocument.compiledRules(at: date).first { $0.id == id }
        return existing != nil && existing == proposed
    }

    private func portableTargetsAreSameOrStricter(_ id: UUID, proposedDocument: CloudPreferencesDocument, at date: Date) -> Bool {
        CloudPortableTargetRestriction.canReplace(
            cloudDocument.compiledRules(at: date).first { $0.id == id },
            with: proposedDocument.compiledRules(at: date).first { $0.id == id }
        )
    }

    private func architectureChangeRejectionMessage(_ proposedRules: [BlockingRule], proposedDocument: CloudPreferencesDocument, at date: Date) -> String {
        guard Set(proposedRules.map(\.id)).count == proposedRules.count else {
            return "The proposed configuration contains duplicate Blocking Group identifiers and was rejected without changing enforcement. Sync again or recreate the duplicated group."
        }
        let proposedByID = Dictionary(uniqueKeysWithValues: proposedRules.map { ($0.id, $0) })
        var affected: [String] = []

        for existing in rules where isRuleEditingLocked(existing.id) {
            guard let proposed = proposedByID[existing.id] else {
                affected.append("“\(existing.name)”\n• The entire Blocking Group would be removed.")
                continue
            }
            guard RuleRestrictionEvaluator.requiresArchitectureUnlock(
                existing: existing,
                proposed: proposed,
                portableDefinitionUnchanged: portableRuleDefinitionIsUnchanged(existing.id, proposedDocument: proposedDocument, at: date),
                portableTargetsSameOrStricter: portableTargetsAreSameOrStricter(existing.id, proposedDocument: proposedDocument, at: date),
                appDefaultLockdown: lockdownConfiguration
            ) else { continue }
            let reasons = RuleRestrictionEvaluator.unlockRequirementReasons(
                existing: existing,
                proposed: proposed,
                appDefaultLockdown: lockdownConfiguration
            )
            var displayedReasons = reasons.prefix(6).map { "• \($0)" }
            if reasons.count > displayedReasons.count {
                displayedReasons.append("• \(reasons.count - displayedReasons.count) additional protected dimensions would change.")
            }
            let detail = displayedReasons.joined(separator: "\n")
            affected.append("“\(existing.name)”\n\(detail)")
        }

        guard !affected.isEmpty else {
            return "This change would modify a locked Blocking Group without making every affected protection stricter. Complete its unlock process first."
        }
        let heading = affected.count == 1
            ? "The following locked Blocking Group change requires an unlock:"
            : "The following locked Blocking Group changes require an unlock:"
        let instruction = affected.count == 1
            ? "Complete the affected group’s unlock process, then retry during its editing window."
            : "Complete each affected group’s unlock process, then retry during its editing window."
        return heading + "\n\n"
            + affected.joined(separator: "\n\n")
            + "\n\n" + instruction
    }

    private func normalizedName(_ value: String, fallback: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    // MARK: - iCloud preferences

    /// Reconciles the portable object graph. Family Controls tokens are restored
    /// from device-local Activity Group storage after the cloud document is
    /// accepted; they are never written into iCloud.
    func syncICloudPreferences() {
        // Independent of whether an unrelated, weakening rule edit is pending.
        defer { reconcileSharedLockdowns() }
        do {
            cloudStore.synchronize()
            var document = try cloudStore.load()
            document.migrateLegacyRulesIfNeeded()
            document.reconcileRetreatLifecycles()
            document.rebuildLegacyRuleProjection()
            let comparisonDate = Date()
            let proposedRules = localRuleProjection(from: document, at: comparisonDate)
            guard architectureChangeIsAllowed(
                proposedRules,
                proposedDocument: document,
                at: comparisonDate
            ) else {
                let proposedByID = Dictionary(
                    proposedRules.map { ($0.id, $0) },
                    uniquingKeysWith: { current, candidate in
                        current.preferenceModifiedAt >= candidate.preferenceModifiedAt ? current : candidate
                    }
                )
                pendingCloudRuleIDs = Set(rules.filter {
                    guard isRuleEditingLocked($0.id) else { return false }
                    guard let proposed = proposedByID[$0.id] else { return true }
                    return RuleRestrictionEvaluator.requiresArchitectureUnlock(
                        existing: $0, proposed: proposed,
                        portableDefinitionUnchanged: portableRuleDefinitionIsUnchanged($0.id, proposedDocument: document, at: comparisonDate),
                        portableTargetsSameOrStricter: portableTargetsAreSameOrStricter($0.id, proposedDocument: document, at: comparisonDate),
                        appDefaultLockdown: lockdownConfiguration
                    )
                }.map(\.id))
                cloudSyncStatus = "Locked architecture change pending"
                return
            }
            let acceptedRules = preservingUnchangedLockedProjections(
                proposedRules,
                proposedDocument: document,
                at: comparisonDate
            )
            applyArchitectureDocument(document, projectedRules: acceptedRules)
            try SharedConfiguration.saveRules(rules)
            saveRuleUnlockProcesses()
            refreshRuleLockdowns()
            updateSystemHardening()
            pendingCloudRuleIDs = []
            cloudSyncStatus = "Synced"
        } catch {
            cloudSyncStatus = "Sync failed"
            errorMessage = "iCloud preference sync failed: \(error.localizedDescription)"
        }
    }

    private func publishICloudPreferences() {
        do {
            try cloudStore.save(cloudDocument)
            cloudSyncStatus = "Synced"
        } catch {
            cloudSyncStatus = "Sync failed"
            errorMessage = "Rules were saved on this iPhone, but iCloud sync failed: \(error.localizedDescription)"
        }
    }

    private func reconcileSharedLockdowns() {
        do {
            var local = SharedConfiguration.loadTimedLockdowns()
            let portable = local.map { session in
                CloudLockdownSession(id: session.id, rules: session.rules.map { rule in
                    var portable = CloudRuleBridge.cloudPreference(from: rule)
                    // Mac app targets are portable but absent from BlockingRule.
                    portable.macApplicationIdentifiers = cloudDocument.compiledRules().first { $0.id == rule.id }?.macApplicationIdentifiers ?? []
                    return portable
                }, startedAt: session.startedAt, endsAt: session.endsAt,
                   exitPolicy: session.sharedExitPolicy ?? CloudLockdownExitPolicy(),
                   earlyExitPassage: session.earlyExitPassage)
            }
            let replica = try lockdownCloudStore.reconcile(localSessions: portable)
            for session in local where replica.cancellations[session.id] != nil {
                try scheduler.endLockdown(session)
            }
            local.removeAll { replica.cancellations[$0.id] != nil }
            let known = Set(local.map(\.id))
            for shared in replica.active(at: Date()) where !known.contains(shared.id) {
                let snapshots = shared.rules.map { portable in
                    var localRule = CloudRuleBridge.applying(portable, to: rules.first { $0.id == portable.id })
                    if !rules.contains(where: { $0.id == portable.id }) {
                        localRule.selection = BlockingGroupSelectionPersistence.selection(for: portable.id) ?? FamilyActivitySelection()
                    }
                    return localRule
                }
                local.append(TimedLockdownSession(id: shared.id, rules: snapshots, startedAt: shared.startedAt,
                    endsAt: shared.endsAt, earlyExitPassage: shared.earlyExitPassage, sharedExitPolicy: shared.exitPolicy))
            }
            try SharedConfiguration.saveTimedLockdowns(local)
            timedLockdowns = local
            synchronize()
            let missingTargets = activeTimedLockdowns.contains { session in session.rules.contains { snapshot in
                let current = rules.first { $0.id == snapshot.id }
                return snapshot.enforcementMode != .fortressAllowList && snapshot.selectedItemCount == 0 && snapshot.enforcedDomains.isEmpty
                    && current?.enforcementMode != .fortressAllowList && (current?.selectedItemCount ?? 0) == 0 && (current?.enforcedDomains.isEmpty ?? true)
            } }
            lockdownSyncStatus = !isAuthorized ? "Shared lockdowns received. Connect Screen Time to enforce them on this device." :
                !lockdownMonitoringFailures.isEmpty ? "Shared lockdowns received; some could not register with Screen Time. Reopen Holdfast to retry." :
                missingTargets ? "Shared with all devices. Some groups have no iOS targets; select their apps or websites here." :
                "All devices · iCloud delivery may be delayed. Open Holdfast on each iPhone or iPad to reconcile precisely."
            if let pending = lockdownCloudStore.pendingMessage { lockdownSyncStatus = pending }
        } catch {
            lockdownSyncStatus = "Lockdown sync pending: \(error.localizedDescription)"
            // A damaged cloud record must not stop accepted local rules and
            // existing lockdowns from reconciling with Screen Time.
            synchronize()
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
