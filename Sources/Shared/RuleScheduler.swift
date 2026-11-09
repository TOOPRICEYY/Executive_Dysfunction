import DeviceActivity
import Foundation
import ManagedSettings

struct RuleScheduler {
    static let maximumConcurrentActivities = 20
    private let center = DeviceActivityCenter()

    func unmonitoredLockdowns(at now: Date) -> Set<UUID> {
        let registered = Set(center.activities)
        return Set(SharedConfiguration.loadTimedLockdowns().filter {
            $0.isActive(at: now) && !registered.contains(MonitorDescriptor.lockdown(sessionID: $0.id).activityName)
        }.map(\.id))
    }

    /// Register an independent expiry before applying any shields. The OS can
    /// reject capacity/intervals, so never report a commitment as active first.
    func startLockdown(_ session: TimedLockdownSession) throws {
        var sessions = SharedConfiguration.loadTimedLockdowns()
        guard Self.estimatedStoreCount(rules: SharedConfiguration.loadRules(),
                                      sessions: sessions + [session], at: Date()) <= 50 else {
            throw NSError(domain: "Holdfast.Lockdown", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screen Time's 50-store budget would be exceeded. Select fewer groups or combine time blocks before starting lockdown."
            ])
        }
        sessions.append(session)
        try SharedConfiguration.saveTimedLockdowns(sessions)
        do {
            try center.startMonitoring(
                MonitorDescriptor.lockdown(sessionID: session.id).activityName,
                during: lockdownSchedule(session)
            )
            session.reconcile()
        } catch {
            session.clear()
            try? SharedConfiguration.saveTimedLockdowns(sessions.filter { $0.id != session.id })
            throw error
        }
    }

    /// Include saved schedule stores as well as both immutable and current
    /// target stores, so a large selection cannot silently exhaust Screen Time.
    static func estimatedStoreCount(rules: [BlockingRule], sessions: [TimedLockdownSession], at now: Date) -> Int {
        1 + rules.reduce(0) { $0 + $1.windows.count + ($1.usageLimitEnabled ? 1 : 0) }
            + sessions.filter { $0.isActive(at: now) }.reduce(0) { $0 + $1.rules.count * 2 }
    }

    func endLockdown(_ session: TimedLockdownSession) throws {
        try SharedConfiguration.saveTimedLockdowns(SharedConfiguration.loadTimedLockdowns().filter { $0.id != session.id })
        center.stopMonitoring([MonitorDescriptor.lockdown(sessionID: session.id).activityName])
        session.clear()
    }

    private func lockdownSchedule(_ session: TimedLockdownSession) -> DeviceActivitySchedule {
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return DeviceActivitySchedule(
            intervalStart: Calendar.current.dateComponents(components, from: session.monitoringInterval.start),
            intervalEnd: Calendar.current.dateComponents(components, from: session.monitoringInterval.end),
            repeats: false
        )
    }

    static func requiredActivityCount(for rules: [BlockingRule]) -> Int {
        let enabled = rules.filter(\.isEnabled)
        let enabledIDs = Set(enabled.map(\.id))
        let now = Date()
        let windowCount = enabled.reduce(0) { $0 + $1.windows.count }
        let allowanceCount = SharedConfiguration.loadRuleTimeAllowances().values.filter { allowance in
            allowance.isActive(at: now) && enabledIDs.contains(allowance.ruleID)
        }.count
        return windowCount + (enabled.contains(where: \.usageLimitEnabled) ? 1 : 0) + allowanceCount
            + SharedConfiguration.loadTimedLockdowns().filter { $0.isActive(at: now) }.count
    }

    func rebuildMonitoring(for rules: [BlockingRule]) -> [String] {
        var errors: [String] = []
        let now = Date()
        let sessions = SharedConfiguration.loadTimedLockdowns()
        var preserved: Set<DeviceActivityName> = []
        let registeredLockdowns = Set(center.activities)
        var admittedSessions = sessions.filter {
            $0.isActive(at: now) && registeredLockdowns.contains(MonitorDescriptor.lockdown(sessionID: $0.id).activityName)
        }
        for session in sessions {
            let name = MonitorDescriptor.lockdown(sessionID: session.id).activityName
            if session.isActive(at: now) {
                do {
                    if !registeredLockdowns.contains(name) {
                        // An oversized incoming session must not clear smaller
                        // lockdowns that this device is already enforcing.
                        guard Self.estimatedStoreCount(rules: rules, sessions: admittedSessions + [session], at: now) <= 50 else {
                            throw NSError(domain: "Holdfast.Lockdown", code: 2, userInfo: [NSLocalizedDescriptionKey:
                                "A shared lockdown exceeds this device's Screen Time store budget. Existing monitored lockdowns remain active."])
                        }
                        try center.startMonitoring(name, during: lockdownSchedule(session))
                        admittedSessions.append(session)
                    }
                    preserved.insert(name)
                    session.reconcile(at: now)
                } catch {
                    // An unmonitored shield must not trap the device past its
                    // promised end. Keep the persisted intent for a later retry.
                    session.clear()
                    errors.append("Lockdown could not be restored: \(error.localizedDescription)")
                }
            } else {
                session.clear()
            }
        }
        try? SharedConfiguration.saveTimedLockdowns(sessions.filter { $0.endsAt > now })
        let registeredActivities = center.activities
        let existing = registeredActivities.filter {
            $0.rawValue.hasPrefix(SharedConfiguration.managedActivityPrefix) && !preserved.contains($0)
        }
        let occupiedActivityCount = registeredActivities.count - existing.count
        center.stopMonitoring(existing)
        existing.forEach { activity in
            EnforcementEngine.clear(storeNamed: ManagedSettingsStore.Name(activity.rawValue))
        }

        let enabledRules = rules.filter(\.isEnabled)
        let enabledRuleIDs = Set(enabledRules.map(\.id))
        let usageRules = enabledRules.filter(\.usageLimitEnabled)
        var storedAllowances = SharedConfiguration.loadRuleTimeAllowances()
        let allowances = storedAllowances.values.filter { allowance in
            allowance.isActive(at: now) && enabledRuleIDs.contains(allowance.ruleID)
        }.sorted {
            $0.expiresAt == $1.expiresAt
                ? $0.ruleID.uuidString < $1.ruleID.uuidString
                : $0.expiresAt < $1.expiresAt
        }
        let windowJobs = enabledRules.flatMap { rule in
            rule.windows.map { (rule: rule, window: $0) }
        }
        let capacity = ActivityMonitorCapacityPlan(
            maximumActivities: Self.maximumConcurrentActivities,
            occupiedActivities: occupiedActivityCount,
            allowanceCount: allowances.count,
            needsUsageActivity: !usageRules.isEmpty,
            windowCount: windowJobs.count
        )
        let scheduledAllowances = Array(allowances.prefix(capacity.scheduledAllowanceCount))
        let unscheduledAllowances = Array(allowances.dropFirst(capacity.scheduledAllowanceCount))

        if !unscheduledAllowances.isEmpty {
            for allowance in unscheduledAllowances {
                storedAllowances.removeValue(forKey: allowance.ruleID)
            }
            SharedConfiguration.saveRuleTimeAllowances(storedAllowances)
            for allowance in unscheduledAllowances where allowance.restoreUsageShield {
                if let rule = enabledRules.first(where: { $0.id == allowance.ruleID && $0.usageLimitEnabled }) {
                    EnforcementEngine.apply(
                        rule,
                        to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: rule.id).storeName)
                    )
                }
            }
            errors.append(
                "\(unscheduledAllowances.count) temporary pause(s) were cancelled because Screen Time could not reserve an expiry monitor. Protection was restored immediately."
            )
        }

        var monitoredWindowIDs: Set<UUID> = []
        for job in windowJobs.prefix(capacity.scheduledWindowCount) {
            let descriptor = MonitorDescriptor.window(
                ruleID: job.rule.id,
                windowID: job.window.id
            )
            do {
                try center.startMonitoring(
                    descriptor.activityName,
                    during: schedule(for: job.window)
                )
                monitoredWindowIDs.insert(job.window.id)
            } catch {
                errors.append(monitoringError(for: job.rule.name, error: error))
            }
        }

        if capacity.skippedWindowCount > 0 {
            errors.append(
                "Screen Time allows at most \(Self.maximumConcurrentActivities) concurrent monitors. "
                + "The consolidated configuration needs \(windowJobs.count + allowances.count + (usageRules.isEmpty ? 0 : 1)); "
                + "\(capacity.skippedWindowCount) time block(s) could not be scheduled. Remove or combine time blocks."
            )
        }

        if capacity.schedulesUsage {
            do {
                try startUsageMonitor(for: usageRules)
            } catch {
                errors.append(monitoringError(for: "Daily usage limits", error: error))
            }
        } else if !usageRules.isEmpty {
            errors.append("Daily usage limits could not be scheduled because all Screen Time monitor slots are in use.")
        }


        let admittedAllowances = Self.registerAllowances(
            scheduledAllowances,
            startMonitoring: { allowance in
                let descriptor = MonitorDescriptor.allowance(ruleID: allowance.ruleID)
                try center.startMonitoring(
                    descriptor.activityName,
                    during: allowanceSchedule(until: allowance.expiresAt)
                )
            },
            cancel: { allowance, error in
                // Capacity is only an estimate; Screen Time can still reject
                // a short interval or fail at runtime. Do not suspend a rule
                // unless its expiry callback has actually been registered.
                var current = SharedConfiguration.loadRuleTimeAllowances()
                current.removeValue(forKey: allowance.ruleID)
                SharedConfiguration.saveRuleTimeAllowances(current)
                if allowance.restoreUsageShield,
                   let rule = enabledRules.first(where: { $0.id == allowance.ruleID && $0.usageLimitEnabled }) {
                    EnforcementEngine.apply(rule, to: ManagedSettingsStore(
                        named: MonitorDescriptor.usage(ruleID: rule.id).storeName
                    ))
                }
                let name = enabledRules.first(where: { $0.id == allowance.ruleID })?.name ?? "Time allowance"
                errors.append(monitoringError(for: name, error: error))
                errors.append("The temporary pause for \(name) was cancelled because its expiry could not be scheduled.")
            }
        )

        // Clear threshold shields from both the new shared monitor and legacy
        // one-monitor-per-rule builds before today's events are registered.
        for rule in rules {
            if !rule.usageLimitEnabled || !rule.isEnabled {
                EnforcementEngine.clear(storeNamed: MonitorDescriptor.usage(ruleID: rule.id).storeName)
            }
        }

        for allowance in admittedAllowances {
            if let rule = enabledRules.first(where: { $0.id == allowance.ruleID }) {
                EnforcementEngine.suspend(rule)
            }
        }

        reconcileScheduledWindows(rules: rules, monitoredWindowIDs: monitoredWindowIDs)
        return errors
    }

    /// Registration, not the capacity estimate, authorizes suspension. The
    /// callbacks make OS registration failures reproducible without Screen Time.
    static func registerAllowances(
        _ allowances: [RuleTimeAllowance],
        startMonitoring: (RuleTimeAllowance) throws -> Void,
        cancel: (RuleTimeAllowance, Error) -> Void
    ) -> [RuleTimeAllowance] {
        allowances.filter { allowance in
            do {
                try startMonitoring(allowance)
                return true
            } catch {
                cancel(allowance, error)
                return false
            }
        }
    }

    func reconcileScheduledWindows(
        rules: [BlockingRule],
        monitoredWindowIDs: Set<UUID>,
        now: Date = Date()
    ) {
        var shielded: Set<String> = []
        for rule in rules {
            let isSuspended = SharedConfiguration.activeTimeAllowance(for: rule.id, at: now) != nil
            for window in rule.windows {
                let descriptor = MonitorDescriptor.window(
                    ruleID: rule.id,
                    windowID: window.id
                )
                let store = ManagedSettingsStore(named: descriptor.storeName)
                if Self.shouldShieldWindow(
                    rule: rule,
                    window: window,
                    hasMonitor: monitoredWindowIDs.contains(window.id),
                    isSuspended: isSuspended,
                    now: now
                ) {
                    EnforcementEngine.apply(rule, to: store)
                    shielded.insert(descriptor.activityName.rawValue)
                } else {
                    store.clearAllSettings()
                }
            }
        }

        // Shields written under an earlier configuration keep their store even
        // after the window that justified them is gone, and no monitor remains
        // to lift them. Without this the block simply never releases.
        for orphan in SharedConfiguration.shieldedWindowStoreNames.subtracting(shielded) {
            EnforcementEngine.clear(storeNamed: ManagedSettingsStore.Name(orphan))
        }
        SharedConfiguration.shieldedWindowStoreNames = shielded
    }

    /// A time block is only shielded when Screen Time actually accepted a
    /// monitor for it. `intervalDidEnd` on that monitor is the only thing that
    /// lifts the shield, so shielding a window that exceeded the monitor budget
    /// would hold the block past its end time until the app was next opened --
    /// a block that outstays its schedule is worse than one that never starts.
    static func shouldShieldWindow(
        rule: BlockingRule,
        window: TimeWindow,
        hasMonitor: Bool,
        isSuspended: Bool,
        now: Date
    ) -> Bool {
        rule.isEnabled
            && hasMonitor
            && !isSuspended
            && window.isActive(at: now)
    }

    private func schedule(for window: TimeWindow) -> DeviceActivitySchedule {
        let start = Self.deviceActivityBoundary(
            minutes: window.startMinutes,
            isEnd: false
        )
        let end = Self.deviceActivityBoundary(
            minutes: window.endMinutes,
            isEnd: true
        )

        return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
    }

    /// Cloud schedules use 1440 to represent the portable end-of-day boundary.
    /// `DateComponents(hour: 24)` is not a valid DeviceActivity boundary and
    /// causes Screen Time to reject an otherwise valid all-day blocking group.
    /// Preserve the model boundary while mapping it to the final representable
    /// instant of the local day for the iOS monitoring API.
    static func deviceActivityBoundary(minutes: Int, isEnd: Bool) -> DateComponents {
        if isEnd, minutes >= 1_440 {
            return DateComponents(hour: 23, minute: 59, second: 59)
        }
        let normalized = max(0, min(1_439, minutes))
        return DateComponents(
            hour: normalized / 60,
            minute: normalized % 60,
            second: 0
        )
    }

    private func allowanceSchedule(until endDate: Date) -> DeviceActivitySchedule {
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let start = calendar.dateComponents(components, from: Date())
        let end = calendar.dateComponents(components, from: endDate)
        return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
    }

    private func startUsageMonitor(for rules: [BlockingRule]) throws {
        var start = DateComponents()
        start.hour = 0
        start.minute = 0
        var end = DateComponents()
        end.hour = 23
        end.minute = 59

        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for rule in rules {
            let selection = rule.selection
            events[.executiveDysfunctionThreshold(ruleID: rule.id)] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: max(1, rule.dailyUsageLimitMinutes)),
                includesPastActivity: true
            )
        }
        try center.startMonitoring(
            MonitorDescriptor.usageBatch.activityName,
            during: schedule,
            events: events
        )
    }

    private func monitoringError(for label: String, error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("excessive") {
            return "\(label): Screen Time's monitor limit was reached. Remove or combine time blocks, then sync again."
        }
        return "\(label): \(description)"
    }
}
