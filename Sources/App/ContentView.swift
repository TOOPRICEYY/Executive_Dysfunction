import FamilyControls
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingTemporaryAccessRequest: PendingTemporaryAccessRequest?

    var body: some View {
        IOSWorkspaceRoot()
        .alert("Action needed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(item: $pendingTemporaryAccessRequest) { request in
            TemporaryAccessRequestView(request: request) {
                pendingTemporaryAccessRequest = nil
            }
            .environmentObject(model)
            .interactiveDismissDisabled()
        }
        .onAppear(perform: refreshPendingTemporaryAccessRequest)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshPendingTemporaryAccessRequest()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func refreshPendingTemporaryAccessRequest() {
        model.refreshPendingTemporaryAccessRequest()
        guard let request = model.pendingTemporaryAccessRequest else {
            pendingTemporaryAccessRequest = nil
            return
        }

        let allowedRuleIDs = Set(model.rules.lazy.filter {
            $0.isEnabled && $0.lockdownPolicy.allowsTimeExtensions
        }.map(\.id))
        guard !allowedRuleIDs.isDisjoint(with: request.eligibleRuleIDs) else {
            model.clearPendingTemporaryAccessRequest(id: request.id)
            pendingTemporaryAccessRequest = nil
            return
        }
        pendingTemporaryAccessRequest = request
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
                RuleTemporaryAccessRequestView(ruleID: rule.id)
                    .environmentObject(model)
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
            && !model.availableTemporaryAccessDurations(for: rule.id).isEmpty
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAntiUninstallConfirmation = false
    @State private var diagnosticsSummary = "…"

    var body: some View {
        NavigationStack {
            List {
                authorizationSection
                cloudSection
                hardeningSection
                lockdownSection
                diagnosticsSection
                limitationsSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .iosModelErrorAlert()
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
        Section("Lockdown & change protection") {
            NavigationLink("Timed enforcement lockdown") { IOSTimedLockdownView().environmentObject(model) }
            NavigationLink {
                LockdownView()
            } label: {
                LabeledContent("App-wide change protection", value: lockdownStatus)
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

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                IOSDiagnosticsView()
            } label: {
                LabeledContent("Device Report", value: diagnosticsSummary)
            }
        }
        // Computed once when the section appears rather than in `body`. Building
        // the report reads the live monitor list and every shield store, which is
        // far too much work to repeat on each view update.
        .onAppear(perform: refreshDiagnosticsSummary)
    }

    /// Surfaced on the settings row itself so a problem is visible without
    /// having to go looking for it.
    private func refreshDiagnosticsSummary() {
        let report = model.makeDiagnosticReport(redaction: .standard)
        let critical = report.criticalWarnings.count
        if critical > 0 {
            diagnosticsSummary = "\(critical) critical"
        } else {
            diagnosticsSummary = report.warnings.isEmpty ? "OK" : "\(report.warnings.count) notes"
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
