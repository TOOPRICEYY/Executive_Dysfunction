import Foundation
import ManagedSettings

/// Device-local snapshots include opaque Screen Time tokens, which cannot be
/// copied between devices. No schedule or temporary allowance can release them.
struct TimedLockdownSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var rules: [BlockingRule]
    var startedAt: Date
    var endsAt: Date
    var earlyExitPassage: String
    /// Nil reads legacy local sessions as their original 80-word passage gate.
    var sharedExitPolicy: CloudLockdownExitPolicy? = nil

    var exitConfiguration: LockdownConfiguration {
        let policy = sharedExitPolicy ?? CloudLockdownExitPolicy()
        var config = LockdownConfiguration()
        config.isEnabled = policy.severity != "none"
        config.unlockDelayDays = policy.severity == "passageOnly" ? 0 : max(0, policy.unlockDelayDays)
        config.repeatConfirmations = policy.severity == "repeatedConfirmations"
        config.passageWordCount = policy.passageWordCount
        config.confirmationWindowHours = max(1, policy.confirmationWindowHours)
        config.editWindowHours = max(1, policy.editWindowHours)
        return config
    }

    func isActive(at date: Date) -> Bool { startedAt <= date && date < endsAt }

    /// Screen Time owns the coarse wake-up; app foreground reconciliation owns
    /// the exact deadline. Round outward, never release earlier than promised.
    var monitoringInterval: DateInterval {
        let quantum: TimeInterval = 15 * 60
        let start = floor(startedAt.timeIntervalSince1970 / quantum) * quantum
        let end = max(start + quantum, ceil(endsAt.timeIntervalSince1970 / quantum) * quantum)
        return DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func storeName(for ruleID: UUID) -> ManagedSettingsStore.Name {
        ManagedSettingsStore.Name("ed.l.\(id.uuidString).\(ruleID.uuidString)")
    }

    func reconcile(at now: Date = Date()) {
        let current = SharedConfiguration.loadRules()
        for rule in rules {
            let store = ManagedSettingsStore(named: storeName(for: rule.id))
            let updatedStore = ManagedSettingsStore(named: ManagedSettingsStore.Name(storeName(for: rule.id).rawValue + ".current"))
            if isActive(at: now) {
                EnforcementEngine.apply(rule, to: store, ignoringTemporaryAllowance: true)
                if let updated = current.first(where: { $0.id == rule.id }) {
                    EnforcementEngine.apply(updated, to: updatedStore, ignoringTemporaryAllowance: true)
                } else { updatedStore.clearAllSettings() }
            } else {
                store.clearAllSettings()
                updatedStore.clearAllSettings()
            }
        }
    }

    func clear() {
        for rule in rules {
            EnforcementEngine.clear(storeNamed: storeName(for: rule.id))
            EnforcementEngine.clear(storeNamed: ManagedSettingsStore.Name(storeName(for: rule.id).rawValue + ".current"))
        }
    }

    static func expirations(_ sessions: [Self], at now: Date) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for session in sessions where session.isActive(at: now) {
            for rule in session.rules { result[rule.id] = max(result[rule.id] ?? session.endsAt, session.endsAt) }
        }
        return result
    }
}
