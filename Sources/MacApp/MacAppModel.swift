import Foundation

@MainActor
final class MacAppModel: ObservableObject {
    @Published private(set) var rules: [CloudRulePreference] = []
    @Published private(set) var syncStatus = "Not synced"
    @Published var errorMessage: String?
    /// What the filter says it is enforcing, next to what this app published.
    /// A mismatch is the symptom of a policy that never took effect.
    @Published private(set) var enforcementHealth: FilterEnforcementSummary.Health = .notReporting
    let enforcement = MacEnforcementController()

    private let store = ICloudPreferencesStore()
    private let desktopPolicyStore = DesktopPolicyFileStore()
    private let desktopRevisionKey = "desktop-enforcement-policy.revision"

    private var statusTimer: Timer?
    /// Sessions live in the published policy; this is the app's working copy.
    private var lockdownSessions: [DesktopLockdownSession] = []

    init() {
        refresh()
        refreshEnforcementHealth()
        // The filter heartbeats every 30s; poll often enough that a wedged or
        // stopped filter becomes visible quickly.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEnforcementHealth()
                // Keeps the uninstall countdown live, and lets a confirmation
                // window expire on screen rather than only on next launch.
                self?.enforcement.refreshRemovalState()
                self?.pruneExpiredSessions()
                self?.objectWillChange.send()
            }
        }
        // Publish the policy first so the re-asserted filter starts from the
        // current rules rather than from whatever it last retained.
        enforcement.reassert()
    }

    func refresh() {
        do {
            store.synchronize()
            rules = try store.load().rules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            syncStatus = "Synced"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func save(_ value: CloudRulePreference) {
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty { value.name = "Focus rule" }
        value.modifiedAt = Date()
        do {
            let document = try store.merge(rules: [value])
            rules = document.rules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            syncStatus = "Synced — awaiting iPhone enforcement"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ value: CloudRulePreference) {
        do {
            let document = try store.merge(tombstones: [.init(id: value.id, modifiedAt: Date())])
            rules = document.rules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            syncStatus = "Deletion proposed to iPhone"
            publishDesktopPolicy()
        } catch {
            syncStatus = "Sync failed"
            errorMessage = error.localizedDescription
        }
    }

    func installDesktopEnforcement() {
        publishDesktopPolicy()
        guard errorMessage == nil else { return }
        enforcement.install()
    }

    func beginDesktopEnforcementRemoval() {
        enforcement.beginRemoval()
    }

    func cancelDesktopEnforcementRemoval() {
        enforcement.cancelRemoval()
    }

    func completeDesktopEnforcementRemoval(passage: String) -> Bool {
        enforcement.completeRemoval(passage: passage)
    }

    func refreshEnforcementHealth() {
        let published = UInt64(max(0, UserDefaults.standard.integer(forKey: desktopRevisionKey)))
        enforcementHealth = FilterEnforcementSummary.health(
            published: published > 0 ? published : nil,
            status: FilterStatusStore.read()
        )
        // `behind` means the filter is enforcing an older policy than the one
        // this app published, so re-send it. Detecting the condition and then
        // waiting for the user to notice the banner is what let revision 199
        // stay in force for sixteen minutes. The controller throttles this.
        if case .behind = enforcementHealth {
            enforcement.redeliverPolicy()
        } else {
            enforcement.noteDeliveryUpToDate()
        }
    }

    // MARK: - Lockdown sessions

    /// Holds the named block lists on for `duration`, ignoring their schedules.
    func startLockdownSession(
        ruleIDs: Set<UUID>,
        duration: TimeInterval,
        lockdown: DesktopLockdownPolicy
    ) {
        guard !ruleIDs.isEmpty else { return }
        let session = DesktopLockdownSessionGate.makeSession(
            ruleIDs: ruleIDs,
            duration: duration,
            lockdown: lockdown
        )
        lockdownSessions.append(session)
        publishDesktopPolicy()
    }

    /// Ends a running session before its time. The passage is checked here, and
    /// the filter independently refuses to shorten a session unless the policy
    /// carries a live weakening authorization — so a policy published without
    /// this call does not end anything.
    @discardableResult
    func endLockdownSession(id: UUID, passage: String) -> Bool {
        guard let index = lockdownSessions.firstIndex(where: { $0.id == id }) else { return false }
        let session = lockdownSessions[index]
        guard DesktopLockdownSessionGate.passageMatches(passage, session: session) else { return false }
        lockdownSessions.remove(at: index)
        // The filter accepts a shortened session only inside an authorized
        // window, so open a brief one for this publish.
        publishDesktopPolicy(weakeningAuthorizationExpiresAt: Date().addingTimeInterval(120))
        return true
    }

    var activeLockdownSessions: [DesktopLockdownSession] {
        lockdownSessions.filter { $0.isActive(at: Date()) }
    }

    private func pruneExpiredSessions() {
        let now = Date()
        let survivors = lockdownSessions.filter { $0.endsAt > now }
        if survivors.count != lockdownSessions.count {
            lockdownSessions = survivors
            publishDesktopPolicy()
        }
    }

    private func publishDesktopPolicy(weakeningAuthorizationExpiresAt: Date? = nil) {
        let defaults = UserDefaults.standard
        let previous = UInt64(max(0, defaults.integer(forKey: desktopRevisionKey)))
        let revision = previous &+ 1
        let policy = DesktopEnforcementPolicy(
            cloudRules: rules,
            revision: revision,
            weakeningAuthorizationExpiresAt: weakeningAuthorizationExpiresAt,
            lockdownSessions: lockdownSessions.isEmpty ? nil : lockdownSessions
        )
        do {
            try desktopPolicyStore.publish(policy)
            defaults.set(Int(min(revision, UInt64(Int.max))), forKey: desktopRevisionKey)
            enforcement.updatePolicy(policy)
            refreshEnforcementHealth()
        } catch {
            errorMessage = "Desktop enforcement policy was not published: \(error.localizedDescription)"
        }
    }
}
