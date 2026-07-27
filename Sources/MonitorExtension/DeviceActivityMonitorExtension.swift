import DeviceActivity
import Foundation
import ManagedSettings

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard let descriptor = MonitorDescriptor.parse(activity) else { return }
        switch descriptor {
        case let .window(ruleID, windowID):
            guard let rule = enabledRule(id: ruleID),
                  let window = rule.windows.first(where: { $0.id == windowID }),
                  window.isActive(at: Date())
            else { return }
            EnforcementEngine.apply(rule, to: ManagedSettingsStore(named: descriptor.storeName))
        case let .allowance(ruleID):
            guard let rule = enabledRule(id: ruleID) else { return }
            EnforcementEngine.suspend(rule)
        case .usage, .usageBatch:
            break
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard let descriptor = MonitorDescriptor.parse(activity) else { return }
        switch descriptor {
        case .window, .usage:
            EnforcementEngine.clear(storeNamed: descriptor.storeName)
        case let .allowance(ruleID):
            endAllowance(ruleID: ruleID)
        case .usageBatch:
            for rule in SharedConfiguration.loadRules() {
                EnforcementEngine.clear(storeNamed: MonitorDescriptor.usage(ruleID: rule.id).storeName)
            }
        }
    }

    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let descriptor = MonitorDescriptor.parse(activity) else { return }
        let ruleID = event.executiveDysfunctionRuleID ?? descriptor.ruleID
        guard let ruleID,
              let rule = enabledRule(id: ruleID),
              rule.usageLimitEnabled
        else { return }
        if SharedConfiguration.activeTimeAllowance(for: ruleID) != nil {
            SharedConfiguration.markUsageShieldForRestore(ruleID: ruleID)
            EnforcementEngine.clear(storeNamed: MonitorDescriptor.usage(ruleID: ruleID).storeName)
            return
        }
        EnforcementEngine.apply(
            rule,
            to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: ruleID).storeName)
        )
    }

    private func enabledRule(id: UUID) -> BlockingRule? {
        SharedConfiguration.loadRules().first { $0.id == id && $0.isEnabled }
    }

    private func endAllowance(ruleID: UUID) {
        var allowances = SharedConfiguration.loadRuleTimeAllowances()
        guard let allowance = allowances.removeValue(forKey: ruleID) else { return }
        SharedConfiguration.saveRuleTimeAllowances(allowances)
        guard let rule = enabledRule(id: ruleID) else { return }

        for window in rule.windows where window.isActive(at: Date()) {
            let descriptor = MonitorDescriptor.window(ruleID: ruleID, windowID: window.id)
            EnforcementEngine.apply(rule, to: ManagedSettingsStore(named: descriptor.storeName))
        }
        if allowance.restoreUsageShield {
            EnforcementEngine.apply(
                rule,
                to: ManagedSettingsStore(named: MonitorDescriptor.usage(ruleID: ruleID).storeName)
            )
        }
    }
}
