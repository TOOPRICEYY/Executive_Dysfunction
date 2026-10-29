import AppKit
import Foundation
import OSLog

@MainActor
final class MacAppModel: ObservableObject {
    @Published private(set) var browserBypassRecordingAvailable = false
    private var lastImportedBrowserBypasses: [BypassEvent] = []
    @Published private(set) var rules: [CloudRulePreference] = []
    @Published private(set) var activityGroups: [CloudActivityGroup] = []
    @Published private(set) var baseline = CloudBaseline()
    @Published private(set) var retreats: [CloudRetreat] = []
    @Published private(set) var timeWindowTemplates: [CloudTimeWindowTemplate] = []
    @Published private(set) var syncStatus = "Not synced"
    @Published var errorMessage: String?
    @Published private(set) var smokeTestStatus: String?
    /// What the filter says it is enforcing, next to what this app published.
    /// A mismatch is the symptom of a policy that never took effect.
    @Published private(set) var enforcementHealth: FilterEnforcementSummary.Health = .notReporting
    @Published private(set) var retreatUnlockPhases: [UUID: UnlockPhase] = [:]
    let enforcement = MacEnforcementController()

    private let store = ICloudPreferencesStore()
    private let lockdownCloudStore = ICloudLockdownStore()
    @Published private(set) var lockdownSyncStatus = "Lockdowns use all devices"
    private let desktopPolicyStore = DesktopPolicyFileStore()
    private let desktopRevisionKey = "desktop-enforcement-policy.revision"
    private let uiPreviewMode: Bool
    var isUIPreviewMode: Bool { uiPreviewMode }

    private var statusTimer: Timer?
    /// Sessions live in the published policy; this is the app's working copy.
    @Published private var lockdownSessions: [DesktopLockdownSession] = []
    private var retreatUnlockProcesses: [UUID: UnlockProcess] = [:]
    private var ruleEditUnlocks: [UUID: DesktopRuleEditUnlock] = [:]
    /// Guards against republishing identical content, which restarts the
    /// provider for no benefit. See `publishDesktopPolicy`.
    private var lastPublishedPolicy: DesktopEnforcementPolicy?
    private let diagnosticsLogger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "filter-health"
    )
    private var lastStatusReadSignature: String?
    private var lastHealthSignature: String?
    private var notReportingSince: Date?
    private var applyingSince: Date?
    private var applyingSessionID: String?
    private var smokeTestDeadlineTask: Task<Void, Never>?
    private static let smokeTestActiveKey = "desktop-enforcement.smoke-test.active"
    private static let smokeTestDeadlineKey = "desktop-enforcement.smoke-test.deadline"
    private static let smokeTestIdentifierKey = "desktop-enforcement.smoke-test.identifier"
    private let smokeTestLogger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "filter-smoke-test"
    )
    private let blockingDisableLogger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "blocking-disable"
    )

    var baselineRules: [CloudRulePreference] {
        var document = CloudPreferencesDocument(
            activityGroups: activityGroups,
            baseline: baseline
        )
        document.rebuildLegacyRuleProjection()
        return document.rules.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var dashboardActiveRules: [CloudRulePreference] {
        let document = CloudPreferencesDocument(
            activityGroups: activityGroups,
            baseline: baseline,
            retreats: retreats
        )
        let normal = document.dashboardBlockingRules()
        let existing = Set(normal.map(\.id))
        return normal + lockdownDisplayRules.filter { !existing.contains($0.id) }
    }

    var dashboardCalendarRules: [BlockStatusCalendarRule] {
        let document = CloudPreferencesDocument(
            activityGroups: activityGroups,
            baseline: baseline,
            retreats: retreats
        )
        return BlockStatusCalendarRule.applyingLockdowns(to: document.dashboardCalendarRules(), rules: rules + lockdownDisplayRules.filter { held in !rules.contains { $0.id == held.id } }, intervals: lockdownIntervals)
    }

    init(uiPreviewMode: Bool = false) {
        self.uiPreviewMode = uiPreviewMode
        if uiPreviewMode {
            rules = Self.uiPreviewRules
            var preview = CloudPreferencesDocument(rules: rules)
            preview.migrateLegacyRulesIfNeeded()
            apply(preview)
            syncStatus = "UI preview — enforcement untouched"
            return
        }
        DesktopDiagnosticTrace.record(
            component: "app",
            event: "app_launch",
            fields: DesktopDiagnosticTrace.runtimeEvidence()
        )
        // Establish the authenticated on-disk policy as the launch baseline
        // before iCloud refresh can publish or the controller can reassert.
        // This prevents an unchanged launch from inventing a revision and
        // overlapping preference saves with system-extension activation.
        if let persistedPolicy = try? desktopPolicyStore.loadVerified() {
            lastPublishedPolicy = persistedPolicy
            lockdownSessions = persistedPolicy.lockdownSessions ?? []
            enforcement.seedLatestPolicyForLaunch(persistedPolicy)
            let storedRevision = UInt64(max(0, UserDefaults.standard.integer(forKey: desktopRevisionKey)))
            if persistedPolicy.revision > storedRevision {
                UserDefaults.standard.set(
                    Int(min(persistedPolicy.revision, UInt64(Int.max))),
                    forKey: desktopRevisionKey
                )
            }
        }
        MacLockLedger.migrateLegacyState()
        TamperJournal.shared.install(storage: MacLockLedger.shared, origin: "mac-app")
        ClockTamperGuard.shared.install(defaults: MacLockLedger.shared)
        enforcement.startExternalToggleMonitoring()
        retreatUnlockProcesses = loadRetreatUnlockProcesses()
        if let data = retreatUnlockDefaults.data(forKey: "lockdown.mac-rule-edits.v1") {
            ruleEditUnlocks = (try? JSONDecoder().decode([UUID: DesktopRuleEditUnlock].self, from: data)) ?? [:]
        }
        refresh()
        refreshRetreatLockdowns()
        refreshEnforcementHealth()
        // The filter heartbeats every 5s; poll at the same cadence so a wedged or
        // stopped filter becomes visible quickly.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEnforcementHealth()
                // Keeps the uninstall countdown live, and lets a confirmation
                // window expire on screen rather than only on next launch.
                self?.enforcement.refreshRemovalState()
                self?.pruneExpiredSessions()
                self?.pruneExpiredTemporaryPauses()
                self?.refreshRetreatLockdowns()
                self?.objectWillChange.send()
            }
        }
        applyLaunchEnforcementMode()
    }

    private static var uiPreviewRules: [CloudRulePreference] {
        [
            CloudRulePreference(
                name: "Social Feeds",
                windows: [CloudTimeWindow(weekdays: [2, 3, 4, 5, 6], startMinutes: 18 * 60, endMinutes: 22 * 60)],
                domains: [
                    CloudDomainPreference(domain: "twitter.com", category: "social", source: "preview"),
                    CloudDomainPreference(domain: "instagram.com", category: "social", source: "preview")
                ],
                websiteCategories: ["social"]
            ),
            CloudRulePreference(
                name: "News",
                windows: [CloudTimeWindow(weekdays: [7, 1], startMinutes: 16 * 60, endMinutes: 20 * 60)],
                dailyUsageLimitMinutes: 20,
                domains: [CloudDomainPreference(domain: "news.ycombinator.com", category: "news", source: "preview")],
                websiteCategories: ["news"]
            ),
            CloudRulePreference(
                name: "Video",
                windows: [CloudTimeWindow(weekdays: [1], startMinutes: 18 * 60, endMinutes: 23 * 60)],
                dailyUsageLimitMinutes: 60,
                domains: [CloudDomainPreference(domain: "youtube.com", category: "video", source: "preview")],
                websiteCategories: ["video"]
            )
        ]
    }

    private func applyLaunchEnforcementMode(now: Date = Date()) {
        let request: MacFilterSmokeTestRequest?
        do {
            request = try MacFilterSmokeTestRequest.parse(now: now)
        } catch {
            smokeTestLogger.fault(
                "smoke_test_rejected reason=invalid-request description=\(error.localizedDescription, privacy: .public) action=disable"
            )
            errorMessage = "Connectivity smoke test refused: \(error.localizedDescription)"
            clearSmokeTestRecoveryMarker()
            enforcement.disableBlockingImmediately()
            return
        }

        if let request {
            guard !enforcement.activationSafetyRequiresRestart else {
                smokeTestLogger.fault(
                    "smoke_test_rejected id=\(request.identifier.uuidString, privacy: .public) reason=activation-safety-interlock action=remain-disabled"
                )
                errorMessage = "Connectivity smoke test refused because this boot already had a Network Extension startup failure. Run Reset Enforcement Without Restart before any guarded retry."
                clearSmokeTestRecoveryMarker()
                enforcement.disableBlockingImmediately()
                return
            }
            guard enforcement.isBlockingDisabled else {
                smokeTestLogger.fault(
                    "smoke_test_rejected id=\(request.identifier.uuidString, privacy: .public) reason=filter-not-paused action=disable"
                )
                errorMessage = "Connectivity smoke test refused because filtering was not paused first."
                enforcement.disableBlockingForSafety(trigger: "smoke-test-started-with-filter-active")
                return
            }
            beginBoundedSmokeTest(request, now: now)
            return
        }

        let defaults = UserDefaults.standard
        switch MacFilterSmokeTestRecoveryDisposition.resolve(
            arguments: CommandLine.arguments,
            hasActiveMarker: defaults.bool(forKey: Self.smokeTestActiveKey)
        ) {
        case .forcedHealthyDisable:
            clearSmokeTestRecoveryMarker()
            enforcement.disableBlockingImmediately(trigger: "smoke-test-cooperative-deadline")
        case .forcedUnsafeDisable:
            clearSmokeTestRecoveryMarker()
            enforcement.disableBlockingForSafety(trigger: "smoke-test-connectivity-outage")
        case .abandonedRun:
            let identifier = defaults.string(forKey: Self.smokeTestIdentifierKey) ?? "unknown"
            smokeTestLogger.fault(
                "smoke_test_recovery id=\(identifier, privacy: .public) reason=launch-with-active-marker action=disable"
            )
            clearSmokeTestRecoveryMarker()
            enforcement.disableBlockingForSafety(trigger: "abandoned-smoke-test")
        case .none:
            if CommandLine.arguments.contains("--reset-enforcement-safely") {
                enforcement.resetEnforcementWithoutRestart()
            } else if enforcement.isBlockingDisabled {
                enforcement.disableBlockingImmediately()
            } else {
                enforcement.reassert()
            }
        }
    }

    private func beginBoundedSmokeTest(_ request: MacFilterSmokeTestRequest, now: Date) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.smokeTestActiveKey)
        defaults.set(request.deadline.timeIntervalSince1970, forKey: Self.smokeTestDeadlineKey)
        defaults.set(request.identifier.uuidString, forKey: Self.smokeTestIdentifierKey)

        let remainingMilliseconds = max(0, Int(request.deadline.timeIntervalSince(now) * 1_000))
        smokeTestStatus = "Connectivity smoke test active. Hard disable in \(remainingMilliseconds / 1_000)s."
        smokeTestLogger.notice(
            "smoke_test_started id=\(request.identifier.uuidString, privacy: .public) hard_deadline_ms=\(Int(request.deadline.timeIntervalSince1970 * 1_000), privacy: .public) remaining_ms=\(remainingMilliseconds, privacy: .public) independent_watchdog_required=true"
        )
        enforcement.install()

        smokeTestDeadlineTask?.cancel()
        smokeTestDeadlineTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, request.deadline.timeIntervalSinceNow) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.smokeTestLogger.fault(
                "smoke_test_internal_deadline_reached id=\(request.identifier.uuidString, privacy: .public) action=disable"
            )
            self.smokeTestStatus = "Smoke-test deadline reached; disabling filtering…"
            self.enforcement.disableBlockingForSafety(trigger: "smoke-test-hard-deadline")
            self.clearSmokeTestRecoveryMarker()
        }
    }

    private func clearSmokeTestRecoveryMarker() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.smokeTestActiveKey)
        defaults.removeObject(forKey: Self.smokeTestDeadlineKey)
        defaults.removeObject(forKey: Self.smokeTestIdentifierKey)
    }

    func refresh() {
        guard !uiPreviewMode else { return }
        defer { reconcileSharedLockdowns() }
        do {
            store.synchronize()
            apply(try store.load())
            syncStatus = "Synced"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func save(_ value: CloudRulePreference) {
        guard !uiPreviewMode else { return }
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty { value.name = "Focus rule" }
        value.modifiedAt = Date()
        do {
            let document = try store.merge(rules: [value])
            apply(document)
            syncStatus = "Synced — awaiting iPhone enforcement"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ value: CloudRulePreference) {
        guard !uiPreviewMode else { return }
        do {
            let document = try store.merge(tombstones: [.init(id: value.id, modifiedAt: Date())])
            apply(document)
            syncStatus = "Deletion proposed to iPhone"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func saveActivityGroup(_ value: CloudActivityGroup) {
        guard !uiPreviewMode else { return }
        do {
            var document = try store.load()
            var group = value
            group.modifiedAt = Date()
            group.name = normalizedName(group.name, fallback: "Activity group")
            if let index = document.activityGroups.firstIndex(where: { $0.id == group.id }) {
                document.activityGroups[index] = group
            } else {
                document.activityGroups.append(group)
            }
            document.rebuildLegacyRuleProjection()
            try store.save(document)
            apply(document)
            syncStatus = "Activity Group saved"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    /// Adds a ready-made Blocking Group (and any Activity Groups it needs).
    /// Purely additive, so it never needs an unlock.
    func installPreset(_ preset: HoldfastPresets.BlockingPreset) {
        guard !uiPreviewMode else { return }
        do {
            var document = try store.load()
            HoldfastPresets.install(preset, into: &document)
            try store.save(document)
            apply(document)
            syncStatus = "\(preset.name) added"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveBlockingGroup(_ value: CloudBlockingGroup) -> Bool {
        guard !uiPreviewMode else { return false }
        do {
            var document = try store.load()
            var group = value
            group.modifiedAt = Date()
            group.name = normalizedName(group.name, fallback: "Blocking group")
            group.activityGroupIDs = Array(Set(group.activityGroupIDs))
            guard group.targets != nil || !group.activityGroupIDs.isEmpty else {
                errorMessage = "Add this Blocking Group's apps or websites before saving."
                return false
            }
            if let index = document.baseline.blockingGroups.firstIndex(where: { $0.id == group.id }) {
                document.baseline.blockingGroups[index] = group
            } else {
                document.baseline.blockingGroups.append(group)
            }
            document.baseline.modifiedAt = group.modifiedAt
            document.rebuildLegacyRuleProjection()
            let candidate = DesktopEnforcementPolicy(blockProfile: DesktopBlockProfile(cloudRules: document.rules), revision: 1,
                lockdownSessions: lockdownSessions.isEmpty ? nil : lockdownSessions)
            var authorization: Date?
            if let existing = lastPublishedPolicy,
               case .unlocked = ruleEditPhase(group.id),
               DesktopRuleEditUnlock.canAuthorize(ruleID: group.id, existing: existing, proposed: candidate) {
                authorization = Date().addingTimeInterval(120)
            }
            if let existing = lastPublishedPolicy,
               !DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: candidate) {
                guard authorization != nil else {
                    errorMessage = "Unlock this Blocking Group for changes first. Other locked groups must be unlocked separately."
                    return false
                }
            }
            try store.save(document)
            apply(document)
            syncStatus = "Blocking Group saved"
            return publishDesktopPolicy(
                weakeningAuthorizationExpiresAt: authorization,
                authorizedRuleIDs: authorization == nil ? [] : [group.id]
            )
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteBlockingGroup(_ group: CloudBlockingGroup) -> Bool {
        guard !uiPreviewMode else { return false }
        do {
            let previous = try store.load()
            var document = previous
            guard document.baseline.blockingGroups.contains(where: { $0.id == group.id }) else { return false }
            document.baseline.blockingGroups.removeAll { $0.id == group.id }
            document.baseline.modifiedAt = Date()
            document.rebuildLegacyRuleProjection()
            let candidate = DesktopEnforcementPolicy(blockProfile: DesktopBlockProfile(cloudRules: document.rules), revision: 1,
                lockdownSessions: lockdownSessions.isEmpty ? nil : lockdownSessions)
            var authorization: Date?
            if let existing = lastPublishedPolicy, !DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: candidate) {
                guard case .unlocked = ruleEditPhase(group.id),
                      DesktopRuleEditUnlock.canAuthorize(ruleID: group.id, existing: existing, proposed: candidate) else {
                    errorMessage = "Unlock this Blocking Group before deleting it."
                    return false
                }
                authorization = Date().addingTimeInterval(120)
            }
            try store.save(document); apply(document)
            guard publishDesktopPolicy(weakeningAuthorizationExpiresAt: authorization,
                authorizedRuleIDs: authorization == nil ? [] : [group.id]) else {
                try store.save(previous); apply(previous)
                return false
            }
            syncStatus = "Blocking Group deleted"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func ruleEditPolicy(_ id: UUID) -> DesktopLockdownPolicy? {
        // Use the durable published policy, not the in-progress editor draft.
        lastPublishedPolicy?.rules.first(where: { $0.id == id })?.lockdown ?? desktopRule(for: id)?.lockdown
    }

    func ruleEditPhase(_ id: UUID, now: Date = ClockTamperGuard.shared.conservativeNow()) -> UnlockPhase {
        guard let policy = ruleEditPolicy(id) else { return .idle }
        return ruleEditUnlocks[id]?.phase(for: policy, at: now) ?? .idle
    }

    func submitRuleEditPassage(_ id: UUID, typed: String, expectedPolicy: DesktopLockdownPolicy, now: Date = ClockTamperGuard.shared.conservativeNow()) -> Bool {
        guard !uiPreviewMode, ruleEditPolicy(id) == expectedPolicy else { return false }
        let config = DesktopRuleEditUnlock.configuration(expectedPolicy)
        guard DesktopRemovalGate.passageMatches(typed, requiredPassage: DesktopRemovalGate.passage(wordCount: config.passageWordCount, seed: id)) else { return false }
        switch ruleEditPhase(id, now: now) {
        case .idle, .cancelled:
            ruleEditUnlocks[id] = DesktopRuleEditUnlock(policy: expectedPolicy, process: UnlockProcess(startedAt: now))
        case .confirmationDue:
            ruleEditUnlocks[id]?.process.confirmedAt.append(now)
        default: return false
        }
        persistRuleEditUnlocks()
        return true
    }

    func cancelRuleEditUnlock(_ id: UUID) {
        ruleEditUnlocks[id] = nil
        persistRuleEditUnlocks()
    }

    private func persistRuleEditUnlocks() {
        if let data = try? JSONEncoder().encode(ruleEditUnlocks) {
            retreatUnlockDefaults.set(data, forKey: "lockdown.mac-rule-edits.v1")
        }
        objectWillChange.send()
    }

    func deleteActivityGroup(_ value: CloudActivityGroup) {
        guard !uiPreviewMode else { return }
        do {
            var document = try store.load()
            document.deleteActivityGroup(id: value.id)
            try store.save(document)
            apply(document)
            syncStatus = "Activity Group deleted"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func saveRetreat(
        id: UUID? = nil,
        name: String,
        goal: String,
        plannedStart: Date,
        plannedEnd: Date,
        sourceBlockingGroups: [CloudBlockingGroup],
        modificationPolicy: CloudRuleLockdownPreference,
        startImmediately: Bool
    ) {
        guard !uiPreviewMode else { return }
        do {
            var document = try store.load()
            let copyDate = Date()

            var retreat: CloudRetreat
            if let id, let index = document.retreats.firstIndex(where: { $0.id == id }) {
                retreat = document.retreats[index]
                let retreatGroups = CloudRetreatGroupVersioning.versionedGroups(
                    from: sourceBlockingGroups,
                    replacing: retreat.currentVersion?.blockingGroups ?? [],
                    at: copyDate
                )
                retreat.name = normalizedName(name, fallback: "Retreat")
                retreat.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                retreat.plannedStart = plannedStart
                retreat.plannedEnd = max(plannedStart.addingTimeInterval(60), plannedEnd)
                retreat.appendVersion(
                    blockingGroups: retreatGroups,
                    modificationPolicy: modificationPolicy
                )
                if startImmediately { retreat.start() }
                document.retreats[index] = retreat
            } else {
                let retreatGroups = CloudRetreatGroupVersioning.versionedGroups(
                    from: sourceBlockingGroups,
                    replacing: [],
                    at: copyDate
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
                    modificationPolicy: modificationPolicy
                )
                if startImmediately {
                    retreat.start()
                }
                document.retreats.append(retreat)
            }
            document.rebuildLegacyRuleProjection()
            try store.save(document)
            apply(document)
            syncStatus = startImmediately
                ? (retreat.state == .scheduled ? "Retreat scheduled" : "Retreat active")
                : "Retreat draft saved"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func finishRetreat(_ id: UUID, early: Bool = true, now: Date = Date()) -> Bool {
        guard !uiPreviewMode else { return false }
        do {
            let original = try store.load()
            var document = original
            guard let index = document.retreats.firstIndex(where: { $0.id == id }) else { return false }
            let retreat = document.retreats[index]
            let policy = CloudRetreatEarlyEndGate.policy(
                for: retreat,
                appDefault: retreatAppDefaultPolicy
            )
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
            document.rebuildLegacyRuleProjection()
            try store.save(document)
            apply(document)
            let published = publishDesktopPolicy(
                weakeningAuthorizationExpiresAt: early && policy.requiresAuthorization
                    ? now.addingTimeInterval(120)
                    : nil,
                // Ending passed this Mac's Retreat gate, so its groups may go.
                authorizedRuleIDs: Set(retreat.versions.flatMap { $0.blockingGroups.map(\.id) })
            )
            guard published else {
                try? store.save(original)
                apply(original)
                syncStatus = "Retreat end rejected"
                return false
            }
            retreatUnlockProcesses[id] = nil
            saveRetreatUnlockProcesses()
            refreshRetreatLockdowns(now: now)
            syncStatus = "Retreat ended through change policy"
            return true
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Retreat change policy

    func retreatChangePolicy(for id: UUID) -> CloudRetreatChangePolicy? {
        guard let retreat = retreats.first(where: { $0.id == id }) else { return nil }
        return CloudRetreatEarlyEndGate.policy(for: retreat, appDefault: retreatAppDefaultPolicy)
    }

    func retreatUnlockPhase(for id: UUID, now: Date = ClockTamperGuard.shared.conservativeNow()) -> UnlockPhase {
        guard let policy = retreatChangePolicy(for: id) else { return .idle }
        return Lockdown.phase(
            of: retreatUnlockProcesses[id],
            configuration: lockdownConfiguration(for: policy),
            at: now
        )
    }

    func refreshRetreatLockdowns(now: Date = ClockTamperGuard.shared.conservativeNow()) {
        let knownIDs = Set(retreats.filter { $0.state == .active }.map(\.id))
        retreatUnlockProcesses = retreatUnlockProcesses.filter { knownIDs.contains($0.key) }
        var phases: [UUID: UnlockPhase] = [:]
        for retreat in retreats where retreat.state == .active {
            let phase = retreatUnlockPhase(for: retreat.id, now: now)
            switch phase {
            case .cancelled, .idle:
                retreatUnlockProcesses[retreat.id] = nil
                phases[retreat.id] = .idle
            default:
                phases[retreat.id] = phase
            }
        }
        retreatUnlockPhases = phases
        saveRetreatUnlockProcesses()
    }

    func startRetreatUnlock(_ id: UUID, now: Date = ClockTamperGuard.shared.conservativeNow()) {
        guard let policy = retreatChangePolicy(for: id),
              policy.requiresAuthorization,
              retreatUnlockProcesses[id] == nil
        else { return }
        retreatUnlockProcesses[id] = UnlockProcess(startedAt: now)
        saveRetreatUnlockProcesses()
        refreshRetreatLockdowns(now: now)
    }

    func confirmRetreatUnlock(_ id: UUID, now: Date = ClockTamperGuard.shared.conservativeNow()) {
        guard let policy = retreatChangePolicy(for: id),
              var process = retreatUnlockProcesses[id],
              case .confirmationDue = Lockdown.phase(
                of: process,
                configuration: lockdownConfiguration(for: policy),
                at: now
              )
        else {
            errorMessage = "This Retreat confirmation is not due yet, or its deadline has passed."
            refreshRetreatLockdowns(now: now)
            return
        }
        process.confirmedAt.append(now)
        retreatUnlockProcesses[id] = process
        saveRetreatUnlockProcesses()
        refreshRetreatLockdowns(now: now)
    }

    func cancelRetreatUnlock(_ id: UUID) {
        retreatUnlockProcesses[id] = nil
        saveRetreatUnlockProcesses()
        refreshRetreatLockdowns()
    }

    private var retreatAppDefaultPolicy: CloudRuleLockdownPreference {
        CloudRuleLockdownPreference(severity: "delayed")
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

    /// Unlock progress lives in the protected ledger, not the app-group plist,
    /// so it cannot be backdated by editing a preferences file.
    private var retreatUnlockDefaults: any KeyValueLedger {
        MacLockLedger.shared
    }

    private var retreatUnlockKey: String { "lockdown.retreat-unlocks.v1" }

    private func loadRetreatUnlockProcesses() -> [UUID: UnlockProcess] {
        guard let data = retreatUnlockDefaults.data(forKey: retreatUnlockKey),
              let value = try? JSONDecoder().decode([UUID: UnlockProcess].self, from: data)
        else { return [:] }
        return value
    }

    private func saveRetreatUnlockProcesses() {
        if retreatUnlockProcesses.isEmpty {
            retreatUnlockDefaults.removeObject(forKey: retreatUnlockKey)
        } else {
            retreatUnlockDefaults.set(
                try? JSONEncoder().encode(retreatUnlockProcesses),
                forKey: retreatUnlockKey
            )
        }
    }

    private func apply(_ source: CloudPreferencesDocument) {
        var document = source
        document.migrateLegacyRulesIfNeeded()
        document.migrateBlockingGroupOwnership()
        document.rebuildLegacyRuleProjection()
        activityGroups = document.activityGroups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        baseline = document.baseline
        retreats = document.retreats.sorted { $0.modifiedAt > $1.modifiedAt }
        timeWindowTemplates = document.timeWindowTemplates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        rules = document.rules.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func normalizedName(_ value: String, fallback: String) -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    func installDesktopEnforcement() {
        guard !uiPreviewMode else { return }
        publishDesktopPolicy()
        guard errorMessage == nil else { return }
        enforcement.install()
    }

    func disableDesktopBlockingImmediately() {
        guard !uiPreviewMode else { return }
        enforcement.disableBlockingForSafety(trigger: "manual-emergency-disable")
    }

    func resetDesktopEnforcementWithoutRestart() {
        guard !uiPreviewMode else { return }
        enforcement.resetEnforcementWithoutRestart()
    }

    func openNetworkExtensionSettings() {
        guard !uiPreviewMode else { return }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )
    }

    /// Creates the offline challenge for settings and diagnostic-error recovery.
    /// Low-level uncertain preference writes and bounded smoke-test cleanup
    /// retain their independent safety removal path.
    func makeDesktopBlockingDisableChallenge(
        now: Date = Date(),
        id: UUID = UUID()
    ) -> DesktopBlockingDisableChallenge {
        let policy = lastPublishedPolicy ?? .empty
        let challenge = DesktopBlockingDisableGate.makeChallenge(for: policy, at: now, id: id)
        let wordCount = challenge.requiredPassage.split(separator: " ").count
        let expiresMilliseconds = Int(challenge.expiresAt.timeIntervalSince1970 * 1_000)
        blockingDisableLogger.notice(
            "blocking_disable_challenge_issued id=\(challenge.id.uuidString, privacy: .public) revision=\(challenge.policyRevision, privacy: .public) words=\(wordCount, privacy: .public) expires_ms=\(expiresMilliseconds, privacy: .public)"
        )
        return challenge
    }

    @discardableResult
    func disableDesktopBlocking(
        challenge: DesktopBlockingDisableChallenge,
        passage: String,
        now: Date = Date()
    ) -> DesktopBlockingDisableGate.Validation {
        guard !uiPreviewMode else { return .policyChanged }
        let currentPolicy = lastPublishedPolicy ?? .empty
        let validation = DesktopBlockingDisableGate.validate(
            typedPassage: passage,
            challenge: challenge,
            currentPolicy: currentPolicy,
            at: now
        )
        guard validation == .authorized else {
            blockingDisableLogger.error(
                "blocking_disable_challenge_rejected id=\(challenge.id.uuidString, privacy: .public) reason=\(validation.rawValue, privacy: .public) challenge_revision=\(challenge.policyRevision, privacy: .public) current_revision=\(currentPolicy.revision, privacy: .public)"
            )
            return validation
        }

        blockingDisableLogger.notice(
            "blocking_disable_challenge_accepted id=\(challenge.id.uuidString, privacy: .public) revision=\(challenge.policyRevision, privacy: .public) action=disable"
        )
        // Kept as the always-available fallback, but never silent: each use is
        // counted in bypass history with whether the filter was misbehaving.
        let recoveryWarningLive = enforcement.recoveryWarning != nil || enforcement.deliveryError != nil
        BypassHistoryStore.record(
            [BypassEvent.emergencyDisable(at: now, recoveryWarningLive: recoveryWarningLive)],
            defaults: .standard,
            at: now
        )
        DesktopDiagnosticTrace.record(
            component: "enforcement",
            event: "emergency_disable_recorded",
            fields: ["recovery_warning_live": recoveryWarningLive]
        )
        TamperJournal.shared.record(
            .emergencyDisable,
            detail: recoveryWarningLive ? "filter warning was live" : "filter was healthy",
            at: now
        )
        mirrorTamperJournal()
        enforcement.disableBlockingImmediately()
        return .authorized
    }

    func beginDesktopEnforcementRemoval() {
        guard !uiPreviewMode else { return }
        enforcement.beginRemoval()
        TamperJournal.shared.record(.removalRequested)
        mirrorTamperJournal()
    }

    func cancelDesktopEnforcementRemoval() {
        guard !uiPreviewMode else { return }
        enforcement.cancelRemoval()
    }

    func completeDesktopEnforcementRemoval(passage: String) -> Bool {
        guard !uiPreviewMode else { return false }
        return enforcement.completeRemoval(passage: passage)
    }

    @discardableResult
    func removeDesktopNetworkExtension(
        passage: String
    ) -> DesktopNetworkExtensionRemovalGate.Validation {
        guard !uiPreviewMode else { return .passageMismatch }
        return enforcement.removeNetworkExtension(passage: passage)
    }

    // MARK: - Temporary pauses

    var temporaryAllowanceExpirations: [UUID: Date] {
        let now = Date()
        var values = MacTemporaryPauseStore.activeExpirations(at: now, defaults: MacLockLedger.shared)
        if let status = FilterStatusStore.readResult().status,
           abs(status.updatedAt.timeIntervalSince(now)) < 20 {
            values.merge((status.temporaryAllowanceExpirations ?? [:]).filter { $0.value > now }, uniquingKeysWith: max)
        }
        return values.filter { lockdownExpirations[$0.key] == nil }
    }

    /// The pause currently in force for a Blocking Group, if any.
    func temporaryPause(for ruleID: UUID, at now: Date = Date()) -> RuleTimeAllowance? {
        guard !lockdownSessions.contains(where: { $0.isActive(at: now) && $0.ruleIDs.contains(ruleID) }) else { return nil }
        return MacTemporaryPauseStore.active(for: ruleID, at: now, defaults: MacLockLedger.shared)
    }

    func availablePauseDurations(
        for ruleID: UUID,
        at now: Date = Date()
    ) -> [TemporaryAccessDuration] {
        guard let rule = desktopRule(for: ruleID) else { return [] }
        return MacTemporaryPauseStore.availableDurations(for: rule, at: now, defaults: MacLockLedger.shared)
    }

    func pausePassageWordCount(for ruleID: UUID, at now: Date = Date()) -> Int {
        guard let rule = desktopRule(for: ruleID) else { return 0 }
        return MacTemporaryPauseStore.passageWordCount(for: rule, at: now, defaults: MacLockLedger.shared)
    }

    func allowsTemporaryPause(for ruleID: UUID) -> Bool {
        lockdownExpirations[ruleID] == nil && (desktopRule(for: ruleID)?.lockdown.allowsTimeExtensions ?? false)
    }

    func pausePassageExplanation(for ruleID: UUID) -> String {
        TemporaryAllowanceBackoff.description(resetDays: desktopRule(for: ruleID)?.lockdown.temporaryAllowanceResetDays)
    }

    func maximumPauseHours(for ruleID: UUID) -> Int {
        desktopRule(for: ruleID)?.lockdown.maximumTimeExtensionHours ?? 0
    }

    /// Records a pause and republishes, so the filter stops enforcing the rule
    /// until the pause expires. Enforcement resumes on its own: the expiry is
    /// carried in the published policy rather than depending on this app.
    @discardableResult
    func grantTemporaryPause(
        for ruleID: UUID,
        duration: TemporaryAccessDuration,
        verifiedWordCount: Int? = nil,
        intent: BypassEvent.Intent? = nil,
        reflection: String? = nil,
        at now: Date = Date()
    ) -> Bool {
        guard !uiPreviewMode else { return false }
        guard !lockdownSessions.contains(where: { $0.isActive(at: now) && $0.ruleIDs.contains(ruleID) }) else {
            errorMessage = "This group is held by a lockdown. End the lockdown before requesting temporary access."
            return false
        }
        guard let rule = desktopRule(for: ruleID) else {
            errorMessage = "This Blocking Group is no longer part of the published policy."
            return false
        }
        if rule.lockdown.temporaryAllowanceResetDays != nil || rule.lockdown.temporaryAccessPassageWordCount != nil,
           verifiedWordCount != pausePassageWordCount(for: ruleID, at: now) {
            errorMessage = "The required passage changed. Reopen temporary access and type the new passage."
            return false
        }
        let previousPauses = MacTemporaryPauseStore.load(defaults: MacLockLedger.shared)
        let previousBackoff = MacLockLedger.shared.data(forKey: TemporaryAllowanceBackoff.defaultsKey)
        switch MacTemporaryPauseStore.grant(duration, for: rule, at: now, defaults: MacLockLedger.shared) {
        case let .success(allowance):
            guard publishDesktopPolicy() else {
                MacTemporaryPauseStore.save(previousPauses, defaults: MacLockLedger.shared)
                MacLockLedger.shared.set(previousBackoff, forKey: TemporaryAllowanceBackoff.defaultsKey)
                return false
            }
            BypassHistoryStore.record([BypassEvent(id: UUID(), groupID: ruleID, groupName: rule.name,
                grantedAt: now, expiresAt: allowance.expiresAt, grantedMinutes: duration.minutes, source: .app, intent: intent,
                reflection: reflection)],
                defaults: .standard, at: now)
            DesktopDiagnosticTrace.record(
                component: "policy",
                event: "temporary_pause_granted",
                fields: ["duration_minutes": duration.minutes]
            )
            objectWillChange.send()
            return true
        case let .failure(error):
            errorMessage = error.message
            return false
        }
    }

    @discardableResult
    func cancelTemporaryPause(for ruleID: UUID) -> Bool {
        guard !uiPreviewMode else { return false }
        guard MacTemporaryPauseStore.cancel(ruleID: ruleID, defaults: MacLockLedger.shared) else { return false }
        DesktopDiagnosticTrace.record(component: "policy", event: "temporary_pause_cancelled")
        publishDesktopPolicy()
        objectWillChange.send()
        return true
    }

    /// Drops records that have run out and republishes, so the session maximum
    /// resets and the policy stops carrying a spent pause.
    private func pruneExpiredTemporaryPauses(at now: Date = Date()) {
        guard !uiPreviewMode else { return }
        guard MacTemporaryPauseStore.pruneExpired(at: now, defaults: MacLockLedger.shared) > 0 else { return }
        publishDesktopPolicy()
    }

    private func desktopRule(for ruleID: UUID) -> DesktopEnforcementRule? {
        DesktopBlockProfile(cloudRules: rules).rules.first { $0.id == ruleID }
    }

    /// A full interpretable snapshot of this Mac's state, including what the
    /// filter itself reports rather than only what this app believes.
    func makeDiagnosticReport(
        redaction: HoldfastDiagnosticRedaction,
        now: Date = Date()
    ) -> HoldfastDiagnosticReport {
        MacDiagnosticsReport.build(
            document: CloudPreferencesDocument(
                rules: rules,
                activityGroups: activityGroups,
                baseline: baseline,
                retreats: retreats,
                timeWindowTemplates: timeWindowTemplates
            ),
            syncStatus: syncStatus,
            enforcementStatus: enforcement.status,
            enforcementHealth: enforcementHealth,
            filterStatus: FilterStatusStore.readResult().status,
            publishedRevision: UInt64(max(0, UserDefaults.standard.integer(forKey: desktopRevisionKey))),
            isBlockingDisabled: enforcement.isBlockingDisabled,
            removalState: enforcement.removalState,
            deliveryError: enforcement.deliveryError,
            recoveryWarning: enforcement.recoveryWarning,
            activationSafetyRequiresRestart: enforcement.activationSafetyRequiresRestart,
            activationSafetyReason: enforcement.activationSafetyReason,
            retreatUnlockPhases: retreatUnlockPhases,
            traceEvents: MacDiagnosticsReport.recentTraceEvents(),
            redaction: redaction,
            now: now
        )
    }

    /// Writes the report beside a readable rendering of itself. The text file is
    /// what a person opens; the JSON is what a diff or a script reads.
    func writeDiagnosticReport(
        _ report: HoldfastDiagnosticReport,
        to directory: URL
    ) throws -> [URL] {
        let textURL = directory.appendingPathComponent("\(report.suggestedFileName).txt")
        let jsonURL = directory.appendingPathComponent("\(report.suggestedFileName).json")
        try Data(report.renderedText().utf8).write(to: textURL, options: .atomic)
        try report.jsonData().write(to: jsonURL, options: .atomic)
        return [textURL, jsonURL]
    }

    private var tamperJournalMirrored = false

    /// Locked rules whose weakening arrived without this Mac's unlock and is
    /// waiting out the rule's delay. Shown so a held change is never silent.
    @Published private(set) var heldWeakenings: [RemoteWeakeningHold.HeldWeakening] = []
    private static let weakeningHoldsKey = "desktop-enforcement.weakening-holds.v1"

    private func loadWeakeningHolds() -> [UUID: Date] {
        MacLockLedger.shared.data(forKey: Self.weakeningHoldsKey)
            .flatMap { try? JSONDecoder().decode([UUID: Date].self, from: $0) } ?? [:]
    }

    private func saveWeakeningHolds(_ holds: [UUID: Date]) {
        guard holds != loadWeakeningHolds() else { return }
        if holds.isEmpty {
            MacLockLedger.shared.removeObject(forKey: Self.weakeningHoldsKey)
        } else {
            MacLockLedger.shared.set(try? JSONEncoder().encode(holds), forKey: Self.weakeningHoldsKey)
        }
    }

    /// Rules whose weakening is legitimate without a hold: ones this Mac has
    /// unlocked, and groups of a Retreat that reached its planned end.
    private func weakeningHoldExemptions(now: Date = Date()) -> Set<UUID> {
        var exempt = Set<UUID>()
        for id in lastPublishedPolicy?.rules.map(\.id) ?? [] {
            if case .unlocked = ruleEditPhase(id) { exempt.insert(id) }
        }
        for retreat in retreats where retreat.plannedEnd <= now {
            for version in retreat.versions {
                exempt.formUnion(version.blockingGroups.map(\.id))
            }
        }
        return exempt
    }

    /// Mirrors newly recorded app-side events (emergency disable, removal
    /// request) without waiting for the next health poll.
    private func mirrorTamperJournal() {
        TamperJournalCloudMirror.publish(TamperJournal.shared.events())
    }

    func refreshEnforcementHealth() {
        let now = Date()
        let published = UInt64(max(0, UserDefaults.standard.integer(forKey: desktopRevisionKey)))
        let readResult = FilterStatusStore.readResult()
        let supportsBypassHistory = readResult.status?.browserBypassEvents != nil
        if browserBypassRecordingAvailable != supportsBypassHistory {
            browserBypassRecordingAvailable = supportsBypassHistory
        }
        if let events = readResult.status?.browserBypassEvents, events != lastImportedBrowserBypasses,
           BypassHistoryStore.record(events, defaults: .standard) {
            lastImportedBrowserBypasses = events
        }
        // Fold the filter's own tamper observations into the journal, then keep
        // the iCloud copy current so the iPhone (and an accountability
        // partner) can see them.
        let filterTamperEvents = readResult.status?.tamperEvents ?? []
        if TamperJournal.shared.merge(filterTamperEvents) || !tamperJournalMirrored {
            tamperJournalMirrored = true
            TamperJournalCloudMirror.publish(TamperJournal.shared.events())
        }
        logStatusReadTransition(readResult)
        let filterStatus = readResult.status
        enforcementHealth = FilterEnforcementSummary.health(
            published: published > 0 ? published : nil,
            status: filterStatus
        )
        logHealthTransition(
            enforcementHealth,
            published: published > 0 ? published : nil,
            status: filterStatus
        )
        // `behind` means the filter is enforcing an older policy than the one
        // this app published, so re-send it. Detecting the condition and then
        // waiting for the user to notice the banner is what let revision 199
        // stay in force for sixteen minutes. The controller throttles this.
        // Missing/delayed telemetry is not proof of an outage: macOS can suspend
        // an idle provider. Warn without mutating preferences; the user can
        // deliberately recover via the offline passage if browsing is affected.
        switch enforcementHealth {
        case .behind:
            notReportingSince = nil
            applyingSince = nil
            applyingSessionID = nil
            enforcement.redeliverPolicy()
        case .stale:
            notReportingSince = nil
            applyingSince = nil
            applyingSessionID = nil
            let staleAction = MacFilterStartupWatchdog.staleHeartbeatAction(
                isBlockingDisabled: enforcement.isBlockingDisabled,
                startupTransitionInProgress: enforcement.isProviderStartupTransitionInProgress
            )
            diagnosticsLogger.notice(
                "filter_health_recovery state=stale action=\(staleAction.rawValue, privacy: .public) reason=idle-provider-suspension-possible transition=\(self.enforcement.isProviderStartupTransitionInProgress, privacy: .public) blockingDisabled=\(self.enforcement.isBlockingDisabled, privacy: .public)"
            )
        case .notReporting:
            applyingSince = nil
            applyingSessionID = nil
            if enforcement.isProviderStartupTransitionInProgress {
                notReportingSince = nil
                diagnosticsLogger.notice(
                    "filter_health_recovery state=not-reporting action=defer-to-startup-watchdog transition=true"
                )
                break
            }
            if notReportingSince == nil { notReportingSince = now }
            guard !enforcement.isBlockingDisabled,
                  let notReportingSince,
                  now.timeIntervalSince(notReportingSince)
                    >= MacFilterStartupWatchdog.readinessDeadline else { break }
            enforcement.reportRecoveryWarning(
                trigger: "provider-not-reporting",
                message: "Filter status is unavailable. Blocking has not been paused. If browsing is affected, disable all web blocks with the confirmation passage."
            )
        case .applying:
            // A fresh provider explicitly reports this while it is releasing
            // inherited rules and establishing complete retry guards. Restarting
            // it here would prolong the same handoff we are waiting to finish,
            // but a provider may also remain wedged in this state forever.
            notReportingSince = nil
            if enforcement.isProviderStartupTransitionInProgress {
                diagnosticsLogger.notice(
                    "filter_health_recovery state=applying action=defer-to-startup-watchdog transition=true"
                )
                break
            }
            let sessionID = filterStatus?.diagnostics?.sessionID ?? "unknown"
            if applyingSessionID != sessionID {
                applyingSessionID = sessionID
                applyingSince = now
            }
            guard !enforcement.isBlockingDisabled,
                  let applyingSince,
                  now.timeIntervalSince(applyingSince)
                    >= MacFilterStartupWatchdog.readinessDeadline else { break }
            enforcement.reportRecoveryWarning(
                trigger: "provider-applying-timeout",
                message: "The filter is still applying its rules. If browsing is affected, disable all web blocks with the confirmation passage."
            )
        case .idle, .enforcing, .limited:
            notReportingSince = nil
            applyingSince = nil
            applyingSessionID = nil
            enforcement.noteDeliveryUpToDate()
            enforcement.clearRecoveryWarning(trigger: "provider-not-reporting")
            enforcement.clearRecoveryWarning(trigger: "provider-applying-timeout")
        }
        if filterStatus?.diagnostics?.dropPressureWarningActive == true {
            enforcement.reportRecoveryWarning(
                trigger: "unidentified-drop-pressure",
                message: "The filter detected unusually frequent unidentified connection blocks. Review diagnostics, or disable all web blocks with the confirmation passage if browsing is affected."
            )
        } else {
            enforcement.clearRecoveryWarning(trigger: "unidentified-drop-pressure")
        }
    }

    private func logStatusReadTransition(_ result: FilterStatusReadResult) {
        let category: String
        switch result {
        case .available: category = "available"
        case .missing: category = "missing"
        case .unreadable: category = "unreadable"
        case .corrupt: category = "corrupt"
        case .unsupportedDiagnosticsSchema: category = "unsupported-diagnostics-schema"
        }
        let signature: String
        switch result {
        case let .available(status):
            signature = [
                category,
                String(status.revision),
                status.diagnostics?.sessionID ?? "legacy",
                status.diagnostics?.providerBuild ?? "unknown",
                String(status.diagnostics?.failOpenActive ?? false)
            ].joined(separator: "|")
        case .missing, .corrupt:
            signature = category
        case let .unreadable(domain, code):
            signature = "\(category)|\(domain)|\(code)"
        case let .unsupportedDiagnosticsSchema(status, schema):
            signature = "\(category)|\(status.revision)|\(schema)"
        }
        guard signature != lastStatusReadSignature else { return }
        lastStatusReadSignature = signature

        switch result {
        case let .available(status):
            let session = status.diagnostics?.sessionID ?? "legacy"
            let build = status.diagnostics?.providerBuild ?? "unknown"
            let heartbeat = status.diagnostics?.heartbeatSequence ?? 0
            let settingsReady = status.macFilterSettings?.isReady ?? false
            let coveredRetryDomains = status.macFilterSettings?.coveredRetryGuardDomainCount ?? 0
            let requiredRetryDomains = status.macFilterSettings?.requiredRetryGuardDomainCount ?? 0
            let correlatedAddresses = status.macFilterSettings?.correlatedAddressCount ?? 0
            diagnosticsLogger.notice(
                "filter_status_read state=available revision=\(status.revision, privacy: .public) session=\(session, privacy: .public) build=\(build, privacy: .public) heartbeat=\(heartbeat, privacy: .public) settings_ready=\(settingsReady, privacy: .public) required_retry_domains=\(requiredRetryDomains, privacy: .public) covered_retry_domains=\(coveredRetryDomains, privacy: .public) correlated_addresses=\(correlatedAddresses, privacy: .public)"
            )
        case .missing:
            diagnosticsLogger.notice("filter_status_read state=missing")
        case let .unreadable(domain, code):
            diagnosticsLogger.error(
                "filter_status_read state=unreadable error_domain=\(domain, privacy: .public) error_code=\(code, privacy: .public)"
            )
        case .corrupt:
            diagnosticsLogger.error("filter_status_read state=corrupt")
        case let .unsupportedDiagnosticsSchema(status, schema):
            diagnosticsLogger.error(
                "filter_status_read state=unsupported_diagnostics_schema schema=\(schema, privacy: .public) revision=\(status.revision, privacy: .public)"
            )
        }
    }

    private func logHealthTransition(
        _ health: FilterEnforcementSummary.Health,
        published: UInt64?,
        status: FilterEnforcementStatus?
    ) {
        let category: String = switch health {
        case .notReporting: "not-reporting"
        case .stale: "stale"
        case .behind: "behind"
        case .applying: "applying"
        case .limited: "limited-retry-coverage"
        case .idle: "idle"
        case .enforcing: "enforcing"
        }
        let publishedRevision = published ?? 0
        let enforcedRevision = status?.revision ?? 0
        let session = status?.diagnostics?.sessionID ?? "missing"
        let build = status?.diagnostics?.providerBuild ?? "unknown"
        let heartbeat = status?.diagnostics?.heartbeatSequence ?? 0
        let isFailOpen = status?.diagnostics?.failOpenActive ?? false
        let signature = [
            category,
            String(publishedRevision),
            String(enforcedRevision),
            session,
            build,
            String(isFailOpen)
        ].joined(separator: "|")
        guard signature != lastHealthSignature else { return }
        lastHealthSignature = signature
        diagnosticsLogger.notice(
            "filter_health_changed state=\(category, privacy: .public) published_revision=\(publishedRevision, privacy: .public) enforced_revision=\(enforcedRevision, privacy: .public) session=\(session, privacy: .public) build=\(build, privacy: .public) heartbeat=\(heartbeat, privacy: .public) fail_open=\(isFailOpen, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "filter-health",
            event: "health_changed",
            fields: [
                "state": category,
                "published_revision": publishedRevision,
                "enforced_revision": enforcedRevision,
                "provider_session": session,
                "provider_build": build,
                "heartbeat": heartbeat,
                "fail_open": isFailOpen,
                "blocking_disabled": enforcement.isBlockingDisabled,
                "startup_transition": enforcement.isProviderStartupTransitionInProgress
            ]
        )
    }

    // MARK: - Lockdown sessions

    /// Holds the named block lists on for `duration`, ignoring their schedules.
    func startLockdownSession(
        ruleIDs: Set<UUID>,
        duration: TimeInterval,
        lockdown: DesktopLockdownPolicy
    ) {
        guard !uiPreviewMode else { return }
        guard !ruleIDs.isEmpty, ruleIDs.isSubset(of: Set(rules.map(\.id))), duration.isFinite, duration > 0 else { return }
        var session = DesktopLockdownSessionGate.makeSession(
            ruleIDs: ruleIDs,
            duration: duration,
            lockdown: lockdown
        )
        session.ruleSnapshots = DesktopBlockProfile(cloudRules: rules).rules.filter { ruleIDs.contains($0.id) }
        guard session.ruleSnapshots?.allSatisfy({ $0.enforcementMode == .fortressAllowList || !$0.domains.isEmpty || !$0.macApplicationIdentifiers.isEmpty }) == true else {
            errorMessage = "One of the selected groups has no websites or Mac applications this device can filter. Add its targets first."
            return
        }
        lockdownSessions.append(session)
        if !publishDesktopPolicy() { lockdownSessions.removeAll { $0.id == session.id } }
        else { reconcileSharedLockdowns() }
    }

    /// Ends a running session before its time. The passage is checked here, and
    /// the filter independently refuses to shorten a session unless the policy
    /// carries a signed, session-specific authorization — so a policy published without
    /// this call does not end anything.
    @discardableResult
    func endLockdownSession(id: UUID, passage: String) -> Bool {
        guard !uiPreviewMode else { return false }
        guard let index = lockdownSessions.firstIndex(where: { $0.id == id }) else { return false }
        let session = lockdownSessions[index]
        guard DesktopLockdownSessionGate.passageMatches(passage, session: session) else { return false }
        let exitKey = MacLockLedger.sessionExitsKey
        let defaults: any KeyValueLedger = MacLockLedger.shared
        var exits = defaults.data(forKey: exitKey).flatMap {
            try? JSONDecoder().decode([UUID: DesktopRuleEditUnlock].self, from: $0)
        } ?? [:]
        let now = ClockTamperGuard.shared.conservativeNow()
        let phase = exits[id]?.phase(for: session.lockdown, at: now) ?? .idle
        switch phase {
        case .idle, .cancelled:
            exits[id] = DesktopRuleEditUnlock(policy: session.lockdown, process: UnlockProcess(startedAt: now))
        case .confirmationDue:
            exits[id]?.process.confirmedAt.append(now)
        case .waiting, .unlocked:
            break
        }
        if session.lockdown.severity != "none",
           let exit = exits[id], case .unlocked = exit.phase(for: session.lockdown, at: now) {
            // All saved waiting/checkpoint requirements have been met.
        } else if session.lockdown.severity != "none" {
            defaults.set(try? JSONEncoder().encode(exits), forKey: exitKey)
            errorMessage = "Exit request recorded. The lockdown remains active until its saved delay and confirmation requirements are complete."
            return false
        }
        lockdownSessions.remove(at: index)
        // Authorize this session only, through its original deadline.
        if !publishDesktopPolicy(cancelledLockdownEnds: [id: session.endsAt]) {
            lockdownSessions.insert(session, at: index)
            return false
        }
        exits.removeValue(forKey: id)
        defaults.set(try? JSONEncoder().encode(exits), forKey: exitKey)
        do {
            try lockdownCloudStore.recordAuthorizedCancellation(id: id, endsAt: session.endsAt)
            reconcileSharedLockdowns()
        } catch {
            lockdownSyncStatus = "Cancellation sync failed: \(error.localizedDescription)"
            errorMessage = lockdownSyncStatus
        }
        return true
    }

    private func reconcileSharedLockdowns() {
        do {
            let replica = try lockdownCloudStore.reconcile(localSessions: lockdownSessions.map { $0.cloudSession(currentRules: rules) })
            let previous = lockdownSessions
            let cancelled = Set(replica.cancellations.keys)
            lockdownSessions.removeAll { cancelled.contains($0.id) }
            let known = Set(lockdownSessions.map(\.id))
            lockdownSessions += replica.active(at: Date()).filter { !known.contains($0.id) }.map(DesktopLockdownSession.fromCloud)
            let accepted = publishDesktopPolicy(cancelledLockdownEnds: replica.cancellations.mapValues(\.endsAt))
            if !accepted { lockdownSessions = previous }
            let currentTargets = DesktopBlockProfile(cloudRules: rules).rules
            let missingTargets = activeLockdownSessions.contains { session in
                session.ruleSnapshots?.contains { snapshot in
                    let current = currentTargets.first { $0.id == snapshot.id }
                    return snapshot.enforcementMode != .fortressAllowList && snapshot.domains.isEmpty && snapshot.macApplicationIdentifiers.isEmpty
                        && current?.enforcementMode != .fortressAllowList && (current?.domains.isEmpty ?? true) && (current?.macApplicationIdentifiers.isEmpty ?? true)
                } == true
            }
            lockdownSyncStatus = !accepted ? "Shared lockdown received; local policy could not be updated." :
                missingTargets ? "Shared with all devices. Some selected groups have no Mac targets; add them to enforce those groups here." :
                "All devices · iCloud delivery may be delayed. Web enforcement must be enabled on each Mac."
            if let pending = lockdownCloudStore.pendingMessage { lockdownSyncStatus = pending }
        } catch {
            lockdownSyncStatus = "Lockdown sync pending: \(error.localizedDescription)"
        }
    }

    var activeLockdownSessions: [DesktopLockdownSession] {
        lockdownSessions.filter { $0.isActive(at: Date()) }
    }

    var lockdownIntervals: [UUID: [DateInterval]] {
        var result: [UUID: [DateInterval]] = [:]
        for session in activeLockdownSessions {
            for id in session.ruleIDs { result[id, default: []].append(DateInterval(start: session.startedAt, end: session.endsAt)) }
        }
        return result
    }

    var lockdownExpirations: [UUID: Date] {
        lockdownIntervals.compactMapValues { $0.map(\.end).max() }
    }

    private var lockdownDisplayRules: [CloudRulePreference] {
        var known: Set<UUID> = []
        return activeLockdownSessions.flatMap { session in
            session.ruleIDs.compactMap { id -> CloudRulePreference? in
                guard known.insert(id).inserted else { return nil }
                if let current = rules.first(where: { $0.id == id }) { return current }
                guard let snapshot = session.ruleSnapshots?.first(where: { $0.id == id }) else { return nil }
                return CloudRulePreference(id: id, name: snapshot.name, isEnabled: false,
                    enforcementMode: snapshot.enforcementMode.rawValue, windows: [],
                    domains: snapshot.domains.sorted().map { CloudDomainPreference(domain: $0, category: "other", source: "lockdown") },
                    macApplicationIdentifiers: snapshot.macApplicationIdentifiers)
            }
        }
    }

    private func pruneExpiredSessions() {
        let now = Date()
        let survivors = lockdownSessions.filter { $0.endsAt > now }
        if survivors.count != lockdownSessions.count {
            lockdownSessions = survivors
            publishDesktopPolicy()
        }
    }

    /// Publishes only when the policy actually says something new.
    ///
    /// This used to bump the revision on every call, and `refresh()` is called
    /// on every iCloud key-value change as well as at launch. Because each
    /// publish saves the filter configuration and restarts the provider, an
    /// idle machine repeatedly paid a measured startup interruption — revision
    /// 226 to 239 with no rule edits. Unchanged content must not produce a new
    /// revision.
    @discardableResult
    private func publishDesktopPolicy(
        weakeningAuthorizationExpiresAt: Date? = nil,
        cancelledLockdownEnds: [UUID: Date] = [:],
        authorizedRuleIDs: Set<UUID> = []
    ) -> Bool {
        let defaults = UserDefaults.standard
        let previous = UInt64(max(0, defaults.integer(forKey: desktopRevisionKey)))
        // `rules` already contains the additive Baseline + active Retreat
        // projection. Normalize that complete profile once before either
        // policy object is created.
        // A pause is part of the published content, so granting or expiring one
        // produces a new revision and the filter picks it up like any other
        // policy change.
        var blockProfile = DesktopBlockProfile(
            cloudRules: rules,
            temporaryPauses: MacTemporaryPauseStore.activeExpirations(at: Date(), defaults: MacLockLedger.shared)
        )
        // Give Retreat groups their planned interval, and include Retreats that
        // start soon, so the filter starts and ends them on time by itself.
        let schedule = CloudPreferencesDocument(
            activityGroups: activityGroups,
            baseline: baseline,
            retreats: retreats
        ).scheduledRetreatRules()
        if !schedule.isEmpty {
            let baselineIDs = Set(baseline.blockingGroups.map(\.id))
            var byID = Dictionary(
                blockProfile.rules.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            for entry in schedule where !baselineIDs.contains(entry.rule.id) {
                if let index = byID[entry.rule.id] {
                    blockProfile.rules[index].activeFrom = entry.start
                    blockProfile.rules[index].activeUntil = entry.end
                } else if var upcoming = DesktopBlockProfile(cloudRules: [entry.rule]).rules.first {
                    upcoming.activeFrom = entry.start
                    upcoming.activeUntil = entry.end
                    byID[upcoming.id] = blockProfile.rules.count
                    blockProfile.rules.append(upcoming)
                }
            }
        }
        // A weakening that did not pass this Mac's lock (synced from another
        // device, or an Activity Group edit) waits out the rule's own delay.
        // Only the groups this Mac just authorized are exempt; a local unlock
        // of one group must not release a held change to another.
        if let enforced = lastPublishedPolicy {
            let hold = RemoteWeakeningHold.apply(
                previous: enforced.rules,
                proposed: blockProfile.rules,
                exempt: weakeningHoldExemptions().union(authorizedRuleIDs),
                holds: loadWeakeningHolds(),
                now: ClockTamperGuard.shared.conservativeNow()
            )
            blockProfile.rules = hold.rules
            saveWeakeningHolds(hold.holds)
            if heldWeakenings != hold.held { heldWeakenings = hold.held }
        }
        // Keep the narrow authorization through the original deadline, so a
        // sleeping provider cannot miss a short-lived cancellation publish.
        var cancellation = lastPublishedPolicy?.lockdownCancellationAuthorization
        if let value = cancellation, value.expiresAt <= Date() { cancellation = nil }
        let unexpired = cancelledLockdownEnds.filter { $0.value > Date() }
        if let end = unexpired.values.max() {
            cancellation = DesktopLockdownCancellationAuthorization(
                sessionIDs: (cancellation?.sessionIDs ?? []).union(unexpired.keys),
                expiresAt: max(cancellation?.expiresAt ?? end, end))
        }
        var candidate = DesktopEnforcementPolicy(
            blockProfile: blockProfile,
            revision: previous,
            weakeningAuthorizationExpiresAt: weakeningAuthorizationExpiresAt,
            lockdownSessions: lockdownSessions.isEmpty ? nil : lockdownSessions
        )
        candidate.lockdownCancellationAuthorization = cancellation
        if let lastPublishedPolicy, candidate.hasSameContent(as: lastPublishedPolicy) {
            refreshEnforcementHealth()
            return true
        }

        let revision = previous &+ 1
        var policy = DesktopEnforcementPolicy(
            blockProfile: blockProfile,
            revision: revision,
            weakeningAuthorizationExpiresAt: weakeningAuthorizationExpiresAt,
            lockdownSessions: lockdownSessions.isEmpty ? nil : lockdownSessions
        )
        do {
            policy.lockdownCancellationAuthorization = cancellation
            try desktopPolicyStore.publish(policy)
            // Do not suppress a retry after a transient file/keychain failure.
            // A policy counts as published only after its durable write succeeds.
            lastPublishedPolicy = policy
            defaults.set(Int(min(revision, UInt64(Int.max))), forKey: desktopRevisionKey)
            DesktopDiagnosticTrace.record(
                component: "policy",
                event: "policy_published",
                fields: [
                    "revision": revision,
                    "rule_count": policy.rules.count,
                    "lockdown_session_count": policy.lockdownSessions?.count ?? 0,
                    "weakening_authorized": weakeningAuthorizationExpiresAt != nil
                ]
            )
            enforcement.updatePolicy(policy)
            refreshEnforcementHealth()
            return true
        } catch {
            let nsError = error as NSError
            DesktopDiagnosticTrace.record(
                component: "policy",
                event: "policy_publish_failed",
                fields: [
                    "revision": revision,
                    "error_domain": nsError.domain,
                    "error_code": nsError.code
                ]
            )
            errorMessage = "Desktop enforcement policy was not published: \(error.localizedDescription)"
            return false
        }
    }
}
