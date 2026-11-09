import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UIKit

/// Builds the iPhone's diagnostic report.
///
/// The questions this has to answer are all of the form "the block is on when it
/// should be off, or off when it should be on". Screen Time gives no way to ask
/// it what it is currently enforcing, so the report reconstructs the answer from
/// the three things that actually decide it: which windows the document
/// produces, which of those hold a live Device Activity monitor, and which
/// shield stores currently hold a restriction. Where those three disagree is
/// where the bug is.
enum IOSDiagnosticsReport {
    struct WindowState {
        var group: CloudBlockingGroup
        var window: CloudTimeWindow
        var timeWindow: TimeWindow
        var hasMonitor: Bool
        var isActiveNow: Bool
        var isShielded: Bool
        var nextTransition: Date?
        var activityName: String
    }

    @MainActor
    static func build(
        document: CloudPreferencesDocument,
        rules: [BlockingRule],
        authorizationStatus: AuthorizationStatus,
        cloudSyncStatus: String,
        pendingCloudRuleIDs: Set<UUID>,
        lockdownConfiguration: LockdownConfiguration,
        unlockPhase: UnlockPhase,
        ruleUnlockPhases: [UUID: UnlockPhase],
        retreatUnlockPhases: [UUID: UnlockPhase],
        redaction: HoldfastDiagnosticRedaction,
        now: Date = Date()
    ) -> HoldfastDiagnosticReport {
        let redactor = HoldfastDiagnosticRedactor(redaction)
        let registered = registeredActivityNames()
        let states = windowStates(document: document, registered: registered, now: now)
        let ledger = SharedConfiguration.shieldedWindowStoreNames

        var sections: [HoldfastDiagnosticSection] = [
            deviceSection(),
            screenTimeSection(
                authorizationStatus: authorizationStatus,
                cloudSyncStatus: cloudSyncStatus,
                pendingCloudRuleIDs: pendingCloudRuleIDs,
                registered: registered,
                states: states
            )
        ]
        sections.append(contentsOf: HoldfastDiagnosticDocumentSections.sections(
            document: document,
            redactor: redactor,
            now: now
        ))
        sections.append(enforcementSection(states: states, redactor: redactor, now: now))
        sections.append(monitorSection(registered: registered, states: states, redactor: redactor))
        let reachable = reachableShieldStates(document: document, now: now)
        sections.append(reachableStoreSection(reachable: reachable, redactor: redactor))
        sections.append(shieldLedgerSection(ledger: ledger, states: states))
        sections.append(allowanceSection(redactor: redactor, now: now))
        let timedLockdowns = SharedConfiguration.loadTimedLockdowns()
        sections.append(HoldfastDiagnosticSection(
            title: "Timed enforcement lockdowns",
            rows: [HoldfastDiagnosticRow("active sessions", timedLockdowns.filter { $0.isActive(at: now) }.count)],
            tables: [HoldfastDiagnosticTable(title: "Session snapshots", columns: ["session", "groups", "exact end", "monitor end", "registered", "snapshot shields"],
                rows: timedLockdowns.map { session in
                    [redactor.identifier(session.id), String(session.rules.count), session.endsAt.ISO8601Format(),
                     session.monitoringInterval.end.ISO8601Format(),
                     registered.contains(MonitorDescriptor.lockdown(sessionID: session.id).activityName.rawValue) ? "yes" : "NO",
                     String(session.rules.filter { EnforcementEngine.shieldIsConfigured(storeNamed: session.storeName(for: $0.id)) }.count)]
                })]
        ))
        sections.append(lockdownSection(
            configuration: lockdownConfiguration,
            unlockPhase: unlockPhase,
            ruleUnlockPhases: ruleUnlockPhases,
            retreatUnlockPhases: retreatUnlockPhases,
            redactor: redactor
        ))
        sections.append(compiledRulesSection(rules: rules, redactor: redactor))

        var warnings = HoldfastDiagnosticDocumentSections.warnings(
            document: document,
            redactor: redactor,
            now: now
        )
        warnings.append(contentsOf: enforcementWarnings(
            states: states,
            registered: registered,
            ledger: ledger,
            authorizationStatus: authorizationStatus,
            document: document
        ))
        warnings.append(contentsOf: unenforcedStoreWarnings(reachable: reachable, states: states))

        return HoldfastDiagnosticReport(
            generatedAt: now,
            platform: "ios",
            redaction: redaction,
            warnings: warnings,
            sections: sections
        )
    }

    // MARK: - State reconstruction

    static func registeredActivityNames() -> [String] {
        DeviceActivityCenter().activities
            .map(\.rawValue)
            .sorted()
    }

    static func windowStates(
        document: CloudPreferencesDocument,
        registered: [String],
        now: Date
    ) -> [WindowState] {
        let registeredSet = Set(registered)
        return HoldfastDiagnosticDocumentSections.derivedWindows(document: document).map { entry in
            let descriptor = MonitorDescriptor.window(ruleID: entry.group.id, windowID: entry.window.id)
            let timeWindow = TimeWindow(
                id: entry.window.id,
                weekdays: Set(entry.window.weekdays.filter { 1...7 ~= $0 }),
                startMinutes: max(0, min(1_439, entry.window.startMinutes)),
                endMinutes: max(0, min(1_440, entry.window.endMinutes))
            )
            let activityName = descriptor.activityName.rawValue
            return WindowState(
                group: entry.group,
                window: entry.window,
                timeWindow: timeWindow,
                hasMonitor: registeredSet.contains(activityName),
                isActiveNow: timeWindow.isActive(at: now),
                isShielded: EnforcementEngine.shieldIsConfigured(storeNamed: descriptor.storeName),
                nextTransition: timeWindow.nextTransition(after: now),
                activityName: activityName
            )
        }
    }

    struct ReachableStoreState {
        var identity: HoldfastEnforcementIdentities.WindowIdentity
        var isShielded: Bool
        var activityName: String
    }

    /// Every window store the document can name, including the ones no live rule
    /// mentions: groups that are switched off, and groups belonging to Retreats
    /// that have ended. A shield in one of those has nothing left to lift it.
    static func reachableShieldStates(
        document: CloudPreferencesDocument,
        now: Date
    ) -> [ReachableStoreState] {
        HoldfastEnforcementIdentities.allWindowIdentities(document: document, now: now)
            .filter { !$0.isCurrentlyEnforceable }
            .map { identity in
                let descriptor = MonitorDescriptor.window(
                    ruleID: identity.groupID,
                    windowID: identity.windowID
                )
                return ReachableStoreState(
                    identity: identity,
                    isShielded: EnforcementEngine.shieldIsConfigured(storeNamed: descriptor.storeName),
                    activityName: descriptor.activityName.rawValue
                )
            }
            .sorted { $0.activityName < $1.activityName }
    }

    static func unenforcedStoreWarnings(
        reachable: [ReachableStoreState],
        states: [WindowState]
    ) -> [HoldfastDiagnosticWarning] {
        var warnings: [HoldfastDiagnosticWarning] = []
        let stuck = reachable.filter(\.isShielded)

        if !stuck.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.shield-outside-live-schedule",
                severity: .critical,
                message: "\(stuck.count) shield store(s) are applied for a time block no live rule enforces -- a disabled Blocking Group, or a group from a Retreat that has ended. "
                    + "Nothing monitors these, so the block stays on indefinitely.",
                hint: "Syncing now clears them. If a block persists afterwards it belongs to an identity this app can no longer name, and only Reset Screen Time Restrictions will clear it."
            ))
        }

        // The case that matters most is a block the user can see that the app
        // cannot account for. Saying "everything is clear" would be misleading.
        if states.allSatisfy({ !$0.isShielded }), stuck.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.no-shield-accounted-for",
                severity: .note,
                message: "This app is holding no Screen Time shield at all. Every store it can name is clear.",
                hint: "If something is still blocked, it is not coming from this app's current configuration: either a restriction left under an identity the app can no longer name, or Apple's own Screen Time limits in Settings. Reset Screen Time Restrictions clears the former."
            ))
        }

        return warnings
    }

    // MARK: - Findings

    /// The three-way comparison. Each of these is a specific, previously
    /// observed failure mode rather than a generic consistency check.
    static func enforcementWarnings(
        states: [WindowState],
        registered: [String],
        ledger: Set<String>,
        authorizationStatus: AuthorizationStatus,
        document: CloudPreferencesDocument
    ) -> [HoldfastDiagnosticWarning] {
        var warnings: [HoldfastDiagnosticWarning] = []

        let unreleasable = states.filter { $0.isShielded && !$0.hasMonitor }
        if !unreleasable.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.shield-without-monitor",
                severity: .critical,
                message: "\(unreleasable.count) time block(s) are shielded with no Device Activity monitor registered. "
                    + "A shield is only lifted by its monitor's interval end, so these blocks cannot release on schedule.",
                hint: "This is the signature of a block that stays on past its end time. Check whether the schedule exceeded the monitor budget."
            ))
        }

        let outstaying = states.filter { $0.isShielded && !$0.isActiveNow }
        if !outstaying.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.shield-outside-window",
                severity: .critical,
                message: "\(outstaying.count) time block(s) are shielded right now but are outside their scheduled hours.",
                hint: "The block is currently being enforced when it should not be. Compare each row's \"active\" and \"shielded\" columns in Enforcement."
            ))
        }

        let missing = states.filter { $0.isActiveNow && $0.hasMonitor && !$0.isShielded }
        if !missing.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.window-not-shielded",
                severity: .warning,
                message: "\(missing.count) time block(s) are inside their scheduled hours with a monitor registered, but hold no shield.",
                hint: "Expected if a temporary allowance is active for that rule; otherwise the block is not being enforced."
            ))
        }

        let unmonitored = states.filter { !$0.hasMonitor }
        if !unmonitored.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.window-without-monitor",
                severity: .warning,
                message: "\(unmonitored.count) of \(states.count) time block(s) have no Device Activity monitor.",
                hint: "Screen Time allows \(RuleScheduler.maximumConcurrentActivities) concurrent monitors. Blocks beyond that budget are not enforced at all."
            ))
        }

        let knownActivities = Set(states.map(\.activityName))
        let staleWindowMonitors = registered.filter { name in
            guard let descriptor = MonitorDescriptor.parse(DeviceActivityName(name)),
                  case .window = descriptor
            else { return false }
            return !knownActivities.contains(name)
        }
        if !staleWindowMonitors.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.stale-monitor",
                severity: .warning,
                message: "\(staleWindowMonitors.count) registered monitor(s) refer to a time block this document no longer produces.",
                hint: "A monitor that outlives its window keeps firing against a rule that no longer exists. It clears on the next sync."
            ))
        }

        let orphanedLedgerEntries = ledger.subtracting(knownActivities)
        if !orphanedLedgerEntries.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.orphaned-shield-store",
                severity: .warning,
                message: "\(orphanedLedgerEntries.count) shield store(s) were written for a time block that no longer exists.",
                hint: "These are swept on the next sync. If the count keeps growing, window identities are changing when they should be stable."
            ))
        }

        if !isAuthorized(authorizationStatus),
           document.baseline.blockingGroups.contains(where: \.isEnabled) {
            warnings.append(HoldfastDiagnosticWarning(
                code: "authorization.not-approved",
                severity: .critical,
                message: "Blocking Groups are enabled but Screen Time authorization is \"\(describe(authorizationStatus))\". Nothing is enforced on this device.",
                hint: "Grant Screen Time access in the app's protection settings."
            ))
        }

        return warnings
    }

    // MARK: - Sections

    @MainActor
    private static func deviceSection() -> HoldfastDiagnosticSection {
        let bundle = Bundle.main
        let device = UIDevice.current
        return HoldfastDiagnosticSection(
            title: "Device",
            rows: [
                HoldfastDiagnosticRow("app version", bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                HoldfastDiagnosticRow("app build", bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                HoldfastDiagnosticRow("bundle id", bundle.bundleIdentifier ?? "unknown"),
                HoldfastDiagnosticRow("system", "\(device.systemName) \(device.systemVersion)"),
                HoldfastDiagnosticRow("model", device.model),
                HoldfastDiagnosticRow("locale", Locale.current.identifier),
                HoldfastDiagnosticRow("time zone", TimeZone.current.identifier),
                HoldfastDiagnosticRow("uses 24h time", Locale.current.hourCycle == .zeroToTwentyThree || Locale.current.hourCycle == .oneToTwentyFour),
                HoldfastDiagnosticRow("app group reachable", FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: SharedConfiguration.appGroupIdentifier
                ) != nil)
            ]
        )
    }

    private static func screenTimeSection(
        authorizationStatus: AuthorizationStatus,
        cloudSyncStatus: String,
        pendingCloudRuleIDs: Set<UUID>,
        registered: [String],
        states: [WindowState]
    ) -> HoldfastDiagnosticSection {
        let capacity = ActivityMonitorCapacityPlan(
            maximumActivities: RuleScheduler.maximumConcurrentActivities,
            occupiedActivities: 0,
            allowanceCount: SharedConfiguration.loadRuleTimeAllowances().count,
            needsUsageActivity: true,
            windowCount: states.count
        )
        return HoldfastDiagnosticSection(
            title: "Screen Time",
            explanation: "iOS caps concurrent Device Activity monitors. Everything past that budget is unenforceable, "
                + "so the budget is the first thing to check when a schedule behaves inconsistently.",
            rows: [
                HoldfastDiagnosticRow("authorization", describe(authorizationStatus)),
                HoldfastDiagnosticRow("anti-uninstall", SharedConfiguration.antiUninstallEnabled),
                HoldfastDiagnosticRow("icloud sync", cloudSyncStatus),
                HoldfastDiagnosticRow("pending cloud rules", pendingCloudRuleIDs.count),
                HoldfastDiagnosticRow("monitor budget", RuleScheduler.maximumConcurrentActivities),
                HoldfastDiagnosticRow("monitors registered", registered.count),
                HoldfastDiagnosticRow("time blocks needing a monitor", states.count),
                HoldfastDiagnosticRow("time blocks with a monitor", states.filter(\.hasMonitor).count),
                HoldfastDiagnosticRow("time blocks over budget", capacity.skippedWindowCount)
            ]
        )
    }

    private static func enforcementSection(
        states: [WindowState],
        redactor: HoldfastDiagnosticRedactor,
        now: Date
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Time block enforcement",
            columns: ["window", "group", "name", "weekdays", "start", "end", "monitor", "active", "shielded", "next change"],
            rows: states.map { state in
                [
                    redactor.identifier(state.window.id),
                    redactor.identifier(state.group.id),
                    redactor.userContent(state.group.name),
                    HoldfastDiagnosticReport.formatWeekdays(state.window.weekdays),
                    HoldfastDiagnosticReport.formatMinutes(state.window.startMinutes),
                    HoldfastDiagnosticReport.formatMinutes(state.window.endMinutes),
                    state.hasMonitor ? "yes" : "NO",
                    state.isActiveNow ? "yes" : "no",
                    state.isShielded ? "yes" : "no",
                    state.nextTransition.map(HoldfastDiagnosticReport.format) ?? "—"
                ]
            },
            emptyMessage: "No enabled time blocks."
        )
        return HoldfastDiagnosticSection(
            title: "Enforcement",
            explanation: "The decisive table. \"active\" is what the schedule says, \"shielded\" is what is actually applied, "
                + "and \"monitor\" is whether anything exists to change it. Shielded without a monitor is a block that cannot release; "
                + "shielded without active is a block currently outstaying its schedule.",
            rows: [
                HoldfastDiagnosticRow("evaluated at", now),
                HoldfastDiagnosticRow("blocks active now", states.filter(\.isActiveNow).count),
                HoldfastDiagnosticRow("blocks shielded now", states.filter(\.isShielded).count)
            ],
            tables: [table]
        )
    }

    private static func monitorSection(
        registered: [String],
        states: [WindowState],
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let known = Set(states.map(\.activityName))
        let table = HoldfastDiagnosticTable(
            title: "Registered Device Activity monitors",
            columns: ["activity", "kind", "recognised"],
            rows: registered.map { name in
                let descriptor = MonitorDescriptor.parse(DeviceActivityName(name))
                let kind: String
                switch descriptor {
                case .lockdown: kind = "timed lockdown"
                case .window: kind = "time block"
                case .usage: kind = "usage (legacy)"
                case .usageBatch: kind = "usage (shared)"
                case .allowance: kind = "allowance expiry"
                case nil: kind = "unrecognised"
                }
                let recognised: String
                if case .window = descriptor {
                    recognised = known.contains(name) ? "yes" : "STALE"
                } else {
                    recognised = descriptor == nil ? "no" : "yes"
                }
                return [name, kind, recognised]
            },
            emptyMessage: "No monitors are registered."
        )
        return HoldfastDiagnosticSection(
            title: "Monitors",
            explanation: "Read straight from DeviceActivityCenter, so this is what iOS holds rather than what the app believes.",
            tables: [table]
        )
    }

    private static func reachableStoreSection(
        reachable: [ReachableStoreState],
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Stores outside the live schedule",
            columns: ["group", "window", "shielded"],
            rows: reachable.map { state in
                [
                    redactor.identifier(state.identity.groupID),
                    redactor.identifier(state.identity.windowID),
                    state.isShielded ? "YES" : "no"
                ]
            },
            emptyMessage: "The document names no time block outside the live schedule."
        )
        return HoldfastDiagnosticSection(
            title: "Dormant stores",
            explanation: "Identities the document still names but no live rule enforces: disabled Blocking Groups, and groups from Retreats that have ended. "
                + "A shield here has no monitor to lift it, so it would block indefinitely.",
            rows: [
                HoldfastDiagnosticRow("dormant identities", reachable.count),
                HoldfastDiagnosticRow("shielded", reachable.filter(\.isShielded).count)
            ],
            tables: [table]
        )
    }

    private static func shieldLedgerSection(
        ledger: Set<String>,
        states: [WindowState]
    ) -> HoldfastDiagnosticSection {
        let known = Set(states.map(\.activityName))
        let table = HoldfastDiagnosticTable(
            title: "Shield stores last written",
            columns: ["store", "still current"],
            rows: ledger.sorted().map { [$0, known.contains($0) ? "yes" : "ORPHAN"] },
            emptyMessage: "No shield store has been written."
        )
        return HoldfastDiagnosticSection(
            title: "Shield ledger",
            explanation: "ManagedSettings cannot be enumerated, so the app records every store it shields. "
                + "An orphan is a store whose window is gone and whose monitor can no longer lift it.",
            tables: [table]
        )
    }

    private static func allowanceSection(
        redactor: HoldfastDiagnosticRedactor,
        now: Date
    ) -> HoldfastDiagnosticSection {
        let allowances = SharedConfiguration.loadRuleTimeAllowances()
        let table = HoldfastDiagnosticTable(
            title: "Temporary allowances",
            columns: ["rule", "expires", "active", "grants", "minutes", "restores usage shield"],
            rows: allowances.values
                .sorted { $0.expiresAt < $1.expiresAt }
                .map { allowance in
                    [
                        redactor.identifier(allowance.ruleID),
                        HoldfastDiagnosticReport.format(allowance.expiresAt),
                        allowance.isActive(at: now) ? "yes" : "no",
                        String(allowance.grantCount),
                        String(allowance.totalMinutesGranted),
                        allowance.restoreUsageShield ? "yes" : "no"
                    ]
                },
            emptyMessage: "No temporary allowance is stored."
        )
        return HoldfastDiagnosticSection(
            title: "Temporary access",
            explanation: "An active allowance suppresses that rule's shields until it expires, which is a legitimate reason for a block to be off.",
            tables: [table]
        )
    }

    private static func lockdownSection(
        configuration: LockdownConfiguration,
        unlockPhase: UnlockPhase,
        ruleUnlockPhases: [UUID: UnlockPhase],
        retreatUnlockPhases: [UUID: UnlockPhase],
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Per-object unlock phases",
            columns: ["kind", "id", "phase"],
            rows: ruleUnlockPhases.sorted { $0.key.uuidString < $1.key.uuidString }
                .map { ["rule", redactor.identifier($0.key), describe($0.value)] }
                + retreatUnlockPhases.sorted { $0.key.uuidString < $1.key.uuidString }
                .map { ["retreat", redactor.identifier($0.key), describe($0.value)] },
            emptyMessage: "No unlock process is in progress."
        )
        return HoldfastDiagnosticSection(
            title: "Lockdown",
            rows: [
                HoldfastDiagnosticRow("app-wide lockdown", configuration.isEnabled),
                HoldfastDiagnosticRow("repeat confirmations", configuration.repeatConfirmations),
                HoldfastDiagnosticRow("passage words", configuration.passageWordCount),
                HoldfastDiagnosticRow("confirmation window hours", configuration.confirmationWindowHours),
                HoldfastDiagnosticRow("unlock delay days", configuration.unlockDelayDays),
                HoldfastDiagnosticRow("edit window hours", configuration.editWindowHours),
                HoldfastDiagnosticRow("app-wide phase", describe(unlockPhase))
            ],
            tables: [table]
        )
    }

    private static func compiledRulesSection(
        rules: [BlockingRule],
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Compiled rules",
            columns: ["id", "name", "on", "mode", "windows", "usage limit", "domains", "picker"],
            rows: rules.map { rule in
                [
                    redactor.identifier(rule.id),
                    redactor.userContent(rule.name),
                    rule.isEnabled ? "yes" : "no",
                    rule.enforcementMode.rawValue,
                    String(rule.windows.count),
                    rule.usageLimitEnabled ? "\(rule.dailyUsageLimitMinutes)m" : "—",
                    String(rule.enforcedDomains.count),
                    String(
                        rule.selection.applicationTokens.count
                            + rule.selection.categoryTokens.count
                            + rule.selection.webDomainTokens.count
                    )
                ]
            },
            emptyMessage: "No compiled rules."
        )
        return HoldfastDiagnosticSection(
            title: "Compiled rules",
            explanation: "What the object graph compiles to, and what Screen Time is actually handed. "
                + "\"picker\" is the count of opaque tokens resolved on this device; zero means nothing to shield.",
            tables: [table]
        )
    }

    // MARK: - Descriptions

    static func describe(_ status: AuthorizationStatus) -> String {
        // iOS 26.4 added an EU-only mode that grants data access alongside
        // approval. It has to read as authorized, not as an unknown state.
        if #available(iOS 26.4, *), status == .approvedWithDataAccess {
            return "approved with data access"
        }
        switch status {
        case .notDetermined: return "not requested"
        case .denied: return "denied"
        case .approved: return "approved"
        default: return "unknown"
        }
    }

    static func isAuthorized(_ status: AuthorizationStatus) -> Bool {
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return status == .approved
    }

    static func describe(_ phase: UnlockPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .cancelled: "cancelled"
        case let .waiting(unlocksAt, _): "waiting until \(HoldfastDiagnosticReport.format(unlocksAt))"
        case let .confirmationDue(_, deadline, checkpoint, total):
            "checkpoint \(checkpoint)/\(total) due by \(HoldfastDiagnosticReport.format(deadline))"
        case let .unlocked(editWindowEndsAt):
            "unlocked until \(HoldfastDiagnosticReport.format(editWindowEndsAt))"
        }
    }
}
