import FamilyControls
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            RulesHomeView()
                .tabItem { Label("Rules", systemImage: "shield.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .alert("Action needed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

private struct RulesHomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingRule: BlockingRule?
    @State private var requestingTimeRule: BlockingRule?
    private let allowanceRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                rulesSection
            }
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Rule", systemImage: "plus") {
                        editingRule = BlockingRule()
                    }
                }
            }
            .sheet(item: $editingRule) { rule in
                NavigationStack {
                    RuleEditorView(initialRule: rule) { saved in
                        model.save(saved)
                    }
                }
            }
            .sheet(item: $requestingTimeRule) { rule in
                PassageEntryView(
                    title: "One More Hour",
                    explanation: allowanceExplanation(for: rule),
                    wordCount: model.timeAllowancePassageWordCount(for: rule.id)
                ) {
                    model.grantTimeAllowance(for: rule.id)
                }
            }
            .onAppear { model.refreshTimeAllowances() }
            .onReceive(allowanceRefreshTimer) { _ in model.refreshTimeAllowances() }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Screen Time", value: model.authorizationDescription)
            LabeledContent("Protection", value: protectionStatus)
            LabeledContent("iCloud", value: model.cloudSyncStatus)
            if !model.pendingCloudRuleIDs.isEmpty {
                Label("Locked iCloud changes are pending", systemImage: "exclamationmark.icloud.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var protectionStatus: String {
        guard model.isAuthorized else { return "Needs Screen Time access" }
        let enabledCount = model.rules.filter(\.isEnabled).count
        if enabledCount == 0 { return "No enabled rules" }
        return "\(enabledCount) rule\(enabledCount == 1 ? "" : "s") enabled"
    }

    private var rulesSection: some View {
        Section {
            if model.rules.isEmpty {
                ContentUnavailableView(
                    "No Rules",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Add a recurring time block, usage limit, or Fortress allow-list.")
                )
            }

            ForEach(model.rules) { rule in
                Button {
                    editingRule = rule
                } label: {
                    RuleRow(
                        rule: rule,
                        isEditingLocked: model.isRuleEditingLocked(rule.id),
                        allowance: model.activeTimeAllowance(for: rule.id)
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    if !rule.isEnabled || !model.isRuleEditingLocked(rule.id) {
                        Button(rule.isEnabled ? "Disable" : "Enable") {
                            model.setRuleEnabled(rule.id, enabled: !rule.isEnabled)
                        }
                        .tint(rule.isEnabled ? .orange : .green)
                    }
                }
                .deleteDisabled(model.isRuleEditingLocked(rule.id))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canRequestMoreTime(for: rule) {
                        Button("More Time", systemImage: "hourglass.badge.plus") {
                            requestingTimeRule = rule
                        }
                        .tint(.blue)
                    }
                }
            }
            .onDelete(perform: model.deleteRules)
        } header: {
            Text("Rules")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Locked rules accept strictly stronger changes immediately; neutral, mixed, or weaker changes require that rule's unlock process.")
                Text("Screen Time monitors: \(RuleScheduler.requiredActivityCount(for: model.rules)) of \(RuleScheduler.maximumConcurrentActivities).")
            }
        }
    }

    private func canRequestMoreTime(for rule: BlockingRule) -> Bool {
        rule.isEnabled
            && rule.lockdownPolicy.allowsTimeExtensions
            && model.nextTimeAllowanceIncrement(for: rule.id) <= rule.lockdownPolicy.maximumTimeExtensionHours
    }

    private func allowanceExplanation(for rule: BlockingRule) -> String {
        let increment = model.nextTimeAllowanceIncrement(for: rule.id)
        let words = model.timeAllowancePassageWordCount(for: rule.id)
        return "Type the passage to suspend only \(rule.name) for one additional hour. This is hour \(increment) of \(rule.lockdownPolicy.maximumTimeExtensionHours) in the current session and requires \(words) words. Each consecutive hour doubles the passage length."
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAntiUninstallConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                authorizationSection
                cloudSection
                hardeningSection
                lockdownSection
                limitationsSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Prevent all app deletion?",
                isPresented: $showAntiUninstallConfirmation,
                titleVisibility: .visible
            ) {
                Button("Enable Anti-Uninstall") { model.setAntiUninstall(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Apple's setting prevents deleting any app, including this controller. Screen Time authorization can still be revoked in Settings.")
            }
        }
    }

    private var authorizationSection: some View {
        Section("Screen Time Access") {
            LabeledContent("Status", value: model.authorizationDescription)
            if !model.isAuthorized {
                Button {
                    Task { await model.requestAuthorization() }
                } label: {
                    if model.isRequestingAuthorization {
                        ProgressView()
                    } else {
                        Label("Grant Screen Time Access", systemImage: "hourglass.badge.plus")
                    }
                }
                .disabled(model.isRequestingAuthorization)
            }
        }
    }

    private var cloudSection: some View {
        Section("iCloud Preferences") {
            LabeledContent("Status", value: model.cloudSyncStatus)
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                model.syncICloudPreferences()
                model.synchronize()
            }
            if !model.pendingCloudRuleIDs.isEmpty {
                Text("Mac changes that would weaken, mix, or remove a locked rule remain pending until that rule's unlock process is complete. Sync again afterward to apply them.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Schedules, limits, explicit domains, modes, and lockdown preferences sync. Apple's picker selections stay on this iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hardeningSection: some View {
        Section("Hardening") {
            Toggle(
                "Prevent app deletion",
                isOn: Binding(
                    get: { model.antiUninstallEnabled },
                    set: { enabled in
                        if enabled {
                            showAntiUninstallConfirmation = true
                        } else {
                            model.setAntiUninstall(false)
                        }
                    }
                )
            )
            Text("This uses Apple's global deny-app-removal setting. It is the supported substitute for restrictions surviving uninstall.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lockdownSection: some View {
        Section("Lockdown") {
            NavigationLink {
                LockdownView()
            } label: {
                LabeledContent("App-wide Lockdown", value: lockdownStatus)
            }
        }
    }

    private var lockdownStatus: String {
        guard model.lockdownConfiguration.isEnabled else { return "Off" }
        switch model.unlockPhase {
        case .idle, .cancelled: return "Locked"
        case .waiting: return "Unlock in progress"
        case .confirmationDue: return "Confirmation due"
        case .unlocked: return "Unlocked"
        }
    }

    private var limitationsSection: some View {
        Section("Privacy & Limits") {
            Text("Apple exposes normal Screen Time selections as opaque tokens. AI classification applies only to domains you explicitly enter and runs on-device.")
            Text("If Screen Time access is revoked, enforcement stops. A consumer app cannot install an undeletable orphaned restriction profile.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

}

private struct RuleRow: View {
    let rule: BlockingRule
    let isEditingLocked: Bool
    let allowance: RuleTimeAllowance?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.enforcementMode == .fortressAllowList ? "lock.shield.fill" : "shield.fill")
                .foregroundStyle(rule.isEnabled ? .indigo : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name).font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isEditingLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Editing locked")
            }
            Circle()
                .fill(rule.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts = [rule.enforcementMode.title, rule.lockdownPolicy.severity.title, "\(rule.windows.count) time block(s)"]
        if rule.usageLimitEnabled { parts.append("\(rule.dailyUsageLimitMinutes)m/day") }
        if !rule.classifiedDomains.isEmpty { parts.append("\(rule.classifiedDomains.count) domains") }
        if let allowance {
            parts.append("extra time until \(allowance.expiresAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " • ")
    }
}
