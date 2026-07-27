import DeviceActivity
import Foundation
import ManagedSettings

struct RuleScheduler {
    static let maximumConcurrentActivities = 20
    private let center = DeviceActivityCenter()

    static func requiredActivityCount(for rules: [BlockingRule]) -> Int {
        let enabled = rules.filter(\.isEnabled)
        let windowCount = enabled.reduce(0) { $0 + $1.windows.count }
        let allowanceCount = SharedConfiguration.loadRuleTimeAllowances().values.filter { allowance in
            allowance.isActive(at: Date()) && enabled.contains(where: { $0.id == allowance.ruleID })
        }.count
        return windowCount + (enabled.contains(where: \.usageLimitEnabled) ? 1 : 0) + allowanceCount
    }

    func rebuildMonitoring(for rules: [BlockingRule]) -> [String] {
        let existing = center.activities.filter { $0.rawValue.hasPrefix(SharedConfiguration.managedActivityPrefix) }
        center.stopMonitoring(existing)
        existing.forEach { activity in
            EnforcementEngine.clear(storeNamed: ManagedSettingsStore.Name(activity.rawValue))
        }

        var errors: [String] = []
        let enabledRules = rules.filter(\.isEnabled)
        let usageRules = enabledRules.filter(\.usageLimitEnabled)
        let allowances = SharedConfiguration.loadRuleTimeAllowances().values.filter { allowance in
            allowance.isActive(at: Date()) && enabledRules.contains(where: { $0.id == allowance.ruleID })
        }
        let windowJobs = enabledRules.flatMap { rule in
            rule.windows.map { (rule: rule, window: $0) }
        }
        let reservedForUsage = usageRules.isEmpty ? 0 : 1
        let reservedForAllowances = allowances.count
        let otherActivityCount = center.activities.count
        let available = max(0, Self.maximumConcurrentActivities - otherActivityCount)
        let availableWindows = max(0, available - reservedForUsage - reservedForAllowances)

        for job in windowJobs.prefix(availableWindows) {
            let descriptor = MonitorDescriptor.window(
                ruleID: job.rule.id,
                windowID: job.window.id
            )
            do {
                try center.startMonitoring(
                    descriptor.activityName,
                    during: schedule(for: job.window)
                )
            } catch {
                errors.append(monitoringError(for: job.rule.name, error: error))
            }
        }

        let skippedWindows = max(0, windowJobs.count - availableWindows)
        if skippedWindows > 0 {
            errors.append(
                "Screen Time allows at most \(Self.maximumConcurrentActivities) concurrent monitors. "
                + "The consolidated configuration needs \(Self.requiredActivityCount(for: rules)); "
                + "\(skippedWindows) time block(s) could not be scheduled. Remove or combine time blocks."
            )
        }

        if !usageRules.isEmpty, available > 0 {
            do {
                try startUsageMonitor(for: usageRules)
            } catch {
                errors.append(monitoringError(for: "Daily usage limits", error: error))
            }
        } else if !usageRules.isEmpty {
            errors.append("Daily usage limits could not be scheduled because all Screen Time monitor slots are in use.")
        }


        for allowance in allowances {
            let descriptor = MonitorDescriptor.allowance(ruleID: allowance.ruleID)
            do {
                try center.startMonitoring(
                    descriptor.activityName,
                    during: allowanceSchedule(until: allowance.expiresAt)
                )
            } catch {
                let name = enabledRules.first(where: { $0.id == allowance.ruleID })?.name ?? "Time allowance"
                errors.append(monitoringError(for: name, error: error))
            }
        }

        // Clear threshold shields from both the new shared monitor and legacy
        // one-monitor-per-rule builds before today's events are registered.
        for rule in rules {
            if !rule.usageLimitEnabled || !rule.isEnabled {
                EnforcementEngine.clear(storeNamed: MonitorDescriptor.usage(ruleID: rule.id).storeName)
            }
        }

        for allowance in allowances {
            if let rule = enabledRules.first(where: { $0.id == allowance.ruleID }) {
                EnforcementEngine.suspend(rule)
            }
        }

        reconcileScheduledWindows(rules: rules)
        return errors
    }

    func reconcileScheduledWindows(rules: [BlockingRule], now: Date = Date()) {
        for rule in rules {
            for window in rule.windows {
                let descriptor = MonitorDescriptor.window(
                    ruleID: rule.id,
                    windowID: window.id
                )
                let store = ManagedSettingsStore(named: descriptor.storeName)
                if rule.isEnabled
                    && SharedConfiguration.activeTimeAllowance(for: rule.id, at: now) == nil
                    && window.isActive(at: now) {
                    EnforcementEngine.apply(rule, to: store)
                } else {
                    store.clearAllSettings()
                }
            }
        }
    }

    private func schedule(for window: TimeWindow) -> DeviceActivitySchedule {
        var start = DateComponents()
        start.hour = window.startMinutes / 60
        start.minute = window.startMinutes % 60

        var end = DateComponents()
        end.hour = window.endMinutes / 60
        end.minute = window.endMinutes % 60

        return DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
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
