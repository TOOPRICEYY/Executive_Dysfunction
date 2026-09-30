import SwiftUI

struct MacContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: MacAppModel
    @AppStorage(MacInterfaceTheme.storageKey) private var storedTheme = MacInterfaceTheme.light.rawValue
    @AppStorage(MacHighlightColor.storageKey) private var storedHighlight = MacHighlightColor.defaultValue.rawValue
    @State private var editingBlockingGroup: CloudBlockingGroup?
    @State private var editingRetreatID: UUID?
    @State private var endingRetreatID: UUID?
    @State private var isShowingLockdown = false
    @State private var isShowingDiagnostics = false
    @State private var selectedSection: MacWorkspaceSection = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            if model.isUIPreviewMode {
                HStack {
                    Text("UI PREVIEW")
                        .font(.system(.caption, design: .monospaced, weight: .black))
                    Text("ENFORCEMENT AND ICLOUD WRITES ARE DISABLED")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(MacBrutalPalette.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(MacBrutalPalette.rule).frame(height: 1)
                }
            }
            HStack(spacing: 0) {
                MacWorkspaceSidebar(selection: $selectedSection) {
                    if model.isUIPreviewMode {
                        MacSidebarPreviewStatus()
                    } else {
                        enforcementStatusMenu
                    }
                }
                workspace
            }
            .id("workspace-\(storedTheme)-\(storedHighlight)")
        }
        .font(.system(.body, design: .default))
        .background(MacBrutalPalette.canvas)
        .tint(MacBrutalPalette.controlAccent)
        .preferredColorScheme(currentTheme.colorScheme)
        .toolbar {
            Button("LOCKDOWN") { isShowingLockdown = true }
            Button("DIAGNOSTICS") { isShowingDiagnostics = true }
            Button("REFRESH") { model.refresh() }
        }
        .sheet(item: $editingBlockingGroup) { group in
            MacBlockingGroupEditor(
                initialGroup: group,
                isNew: !model.baseline.blockingGroups.contains(where: { $0.id == group.id }),
                activityGroups: model.activityGroups,
                model: model,
                onSave: model.saveBlockingGroup
            )
        }
        .sheet(isPresented: $isShowingLockdown) {
            MacLockdownSessionSheet(model: model)
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            MacDiagnosticsSheet(model: model)
        }
        .sheet(isPresented: Binding(
            get: { endingRetreatID != nil },
            set: { if !$0 { endingRetreatID = nil } }
        )) {
            if let endingRetreatID {
                MacRetreatEarlyEndSheet(model: model, retreatID: endingRetreatID) {
                    self.endingRetreatID = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in
            model.refresh()
        }
        .alert("Action needed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch selectedSection {
        case .dashboard:
            MacDashboardView(
                activeRules: model.dashboardActiveRules,
                calendarRules: model.dashboardCalendarRules,
                baselineRules: model.baselineRules,
                retreats: model.retreats,
                temporaryAllowances: model.temporaryAllowanceExpirations,
                lockdownExpirations: model.lockdownExpirations,
                onEdit: editBlockingGroup,
                onAdd: { editingBlockingGroup = CloudBlockingGroup() },
                onAddPreset: { model.installPreset($0) },
                onOpenRetreats: {
                    editingRetreatID = nil
                    selectedSection = .retreats
                },
                onOpenRetreat: { retreat in
                    editingRetreatID = retreat.id
                    selectedSection = .retreats
                },
                bypassPanel: BypassActivityPanel(groups: model.rules.map { .init(id: $0.id, name: $0.name) }, defaults: .standard,
                    coverageNote: model.browserBypassRecordingAvailable ? nil : "Browser history is unavailable from the running filter. Update/relaunch the filter and block-page helper to record browser grants.",
                    onOpen: { id in openWindow(id: "bypass-history", value: id?.uuidString ?? "all") })
            ) {
                dashboardEnforcementStatus
                MacLockdownStatusView(sessions: model.activeLockdownSessions, rules: model.rules, syncStatus: model.lockdownSyncStatus) {
                    isShowingLockdown = true
                }
            }
        case .retreats:
            MacRetreatComposerView(
                baselineGroups: model.baseline.blockingGroups,
                retreats: model.retreats,
                initialRetreat: editingRetreatID.flatMap { id in
                    model.retreats.first(where: { $0.id == id })
                },
                onOpenRetreat: { editingRetreatID = $0 }
            ) { submission in
                model.saveRetreat(
                    id: submission.id,
                    name: submission.name,
                    goal: submission.goal,
                    plannedStart: submission.plannedStart,
                    plannedEnd: submission.plannedEnd,
                    sourceBlockingGroups: submission.blockingGroups,
                    modificationPolicy: submission.modificationPolicy,
                    startImmediately: submission.startImmediately
                )
            }
            .id(editingRetreatID?.uuidString ?? "new-retreat")
        case .history:
            MacRetreatHistoryView(
                retreats: model.retreats,
                onEnd: { id, _ in endingRetreatID = id }
            ) { retreat in
                editingRetreatID = retreat.id
                selectedSection = .retreats
            }
        case .settings:
            MacSettingsView()
        }
    }

    private var currentTheme: MacInterfaceTheme {
        MacInterfaceTheme(rawValue: storedTheme) ?? .light
    }

    private func editBlockingGroup(for rule: CloudRulePreference) {
        guard let group = model.baseline.blockingGroups.first(where: { $0.id == rule.id }) else {
            selectedSection = .retreats
            return
        }
        editingBlockingGroup = group
    }

    private var enforcementStatusMenu: some View {
        MacEnforcementStatusMenu(
            controller: model.enforcement,
            syncStatus: model.syncStatus,
            enforcementHealth: model.enforcementHealth,
            install: model.installDesktopEnforcement,
            model: model
        )
    }

    private var dashboardEnforcementStatus: some View {
        MacDashboardEnforcementStatus(
            controller: model.enforcement,
            syncStatus: model.syncStatus,
            enforcementHealth: model.enforcementHealth,
            install: model.installDesktopEnforcement,
            model: model,
            activeRuleCount: model.dashboardActiveRules.count,
            activeRetreatCount: model.retreats.filter { $0.state == .active }.count
        )
    }

}

private struct MacRetreatEarlyEndSheet: View {
    @ObservedObject var model: MacAppModel
    let retreatID: UUID
    let onEnded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passagePurpose: PassagePurpose?
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private enum PassagePurpose: String, Identifiable {
        case start
        case checkpoint
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("END RETREAT EARLY")
                .font(.system(.title2, design: .monospaced, weight: .black))
            if let retreat, let policy {
                Text(retreat.name.uppercased())
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                Text("ENDING AN ACTIVE RETREAT IS A CHANGE. ITS SAVED CHANGE POLICY MUST COMPLETE FIRST.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Rectangle().fill(MacBrutalPalette.rule).frame(height: 1)
                phaseContent(policy: policy)
            } else {
                Text("THIS RETREAT IS NO LONGER ACTIVE.")
                    .font(.system(.body, design: .monospaced, weight: .bold))
            }
            HStack {
                Spacer()
                Button("KEEP RETREAT") { dismiss() }
                    .buttonStyle(MacBrutalButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 560)
        .macBrutalSheet()
        .onAppear { model.refreshRetreatLockdowns() }
        .onReceive(refreshTimer) { _ in model.refreshRetreatLockdowns() }
        .sheet(item: $passagePurpose) { purpose in
            MacRetreatPassageSheet(
                title: purpose == .start ? "START CHANGE PROCESS" : "CHANGE POLICY CHECKPOINT",
                explanation: purpose == .start
                    ? "Type the passage to begin the Retreat’s saved change process."
                    : "Type the passage before this checkpoint expires or the process is cancelled.",
                wordCount: policy?.passageWordCount ?? 40
            ) {
                if purpose == .start { model.startRetreatUnlock(retreatID) }
                else { model.confirmRetreatUnlock(retreatID) }
            }
        }
    }

    private var retreat: CloudRetreat? {
        model.retreats.first { $0.id == retreatID && $0.state == .active }
    }

    private var policy: CloudRetreatChangePolicy? {
        model.retreatChangePolicy(for: retreatID)
    }

    @ViewBuilder
    private func phaseContent(policy: CloudRetreatChangePolicy) -> some View {
        if !policy.requiresAuthorization {
            Button("END RETREAT NOW", role: .destructive, action: finish)
                .buttonStyle(MacBrutalButtonStyle(.danger))
        } else {
            switch model.retreatUnlockPhases[retreatID] ?? model.retreatUnlockPhase(for: retreatID) {
            case .idle, .cancelled:
                Button("TYPE PASSAGE TO START…") { passagePurpose = .start }
                    .buttonStyle(MacBrutalButtonStyle(.danger))
                Text(policy.unlockDelayDays == 0
                    ? "The change window opens immediately after the passage."
                    : "The earliest change window opens after \(policy.unlockDelayDays) full day(s).")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            case let .waiting(unlocksAt, nextConfirmationAt):
                Text("EARLIEST END: \(unlocksAt.formatted(date: .abbreviated, time: .shortened))")
                if let nextConfirmationAt {
                    Text("NEXT CHECKPOINT: \(nextConfirmationAt.formatted(date: .abbreviated, time: .shortened))")
                }
                Button("CANCEL CHANGE PROCESS") { model.cancelRetreatUnlock(retreatID) }
                    .buttonStyle(MacBrutalButtonStyle())
            case let .confirmationDue(_, deadline, checkpoint, total):
                Text("CHECKPOINT \(checkpoint) OF \(total) — DUE BEFORE \(deadline.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(Color.orange)
                Button("TYPE CHECKPOINT PASSAGE…") { passagePurpose = .checkpoint }
                    .buttonStyle(MacBrutalButtonStyle(.danger))
            case let .unlocked(editWindowEndsAt):
                Text("CHANGE WINDOW OPEN UNTIL \(editWindowEndsAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(Color.green)
                Button("END RETREAT EARLY", role: .destructive, action: finish)
                    .buttonStyle(MacBrutalButtonStyle(.danger))
            }
        }
    }

    private func finish() {
        if model.finishRetreat(retreatID) {
            onEnded()
            dismiss()
        }
    }
}

private struct MacRetreatPassageSheet: View {
    let title: String
    let explanation: String
    let wordCount: Int
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passage = ""
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(.headline, design: .monospaced, weight: .black))
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            MacConfirmationPassageView(passage: passage, height: 180)
            MacPassageInput(text: $typed)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            HStack {
                Button("CANCEL") { dismiss() }.buttonStyle(MacBrutalButtonStyle())
                Spacer()
                Button("CONFIRM") {
                    onComplete()
                    dismiss()
                }
                .buttonStyle(MacBrutalButtonStyle(.danger))
                .disabled(!CommitmentPassage.matches(typed, passage: passage))
            }
        }
        .padding(20)
        .frame(width: 560)
        .macBrutalSheet()
        .onAppear {
            if passage.isEmpty { passage = CommitmentPassage.generate(wordCount: wordCount) }
        }
    }
}

private struct MacSidebarPreviewStatus: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(MacBrutalPalette.rule)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("WEB ENFORCEMENT")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                Text("PREVIEW ONLY")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(MacBrutalPalette.canvas)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }
}

private struct MacDashboardEnforcementStatus: View {
    @ObservedObject var controller: MacEnforcementController
    let syncStatus: String
    let enforcementHealth: FilterEnforcementSummary.Health
    let install: () -> Void
    @ObservedObject var model: MacAppModel
    let activeRuleCount: Int
    let activeRetreatCount: Int
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Text(statusSummary)
                .font(.system(size: 32, weight: .black, design: .monospaced))
                .tracking(-1.2)

            Spacer(minLength: 18)

            statusBadge(syncStatus.uppercased())
            statusBadge("\(activeRuleCount) ACTIVE BLOCKING")
            statusBadge("\(activeRetreatCount) ACTIVE RETREATS")

            Button("CONTROLS") {
                isShowingDetails.toggle()
            }
            .buttonStyle(MacBrutalButtonStyle())
            .popover(isPresented: $isShowingDetails, arrowEdge: .top) {
                MacEnforcementBanner(
                    controller: controller,
                    syncStatus: syncStatus,
                    enforcementHealth: enforcementHealth,
                    install: install,
                    model: model
                )
                .frame(width: 680)
            }
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 82)
        .foregroundStyle(statusForeground)
        .background(statusColor)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 2) }
        .accessibilityElement(children: .contain)
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .black))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(statusForeground.opacity(0.12))
            .overlay { Rectangle().stroke(statusForeground.opacity(0.6), lineWidth: 1) }
    }

    private var hasWarning: Bool {
        controller.activationSafetyRequiresRestart
            || controller.recoveryWarning != nil
            || controller.deliveryError != nil
            || (!controller.isBlockingDisabled && !FilterEnforcementSummary.isHealthy(enforcementHealth))
    }

    private var statusSummary: String {
        if controller.activationSafetyRequiresRestart { return "SAFETY LOCKED" }
        if controller.recoveryWarning != nil { return "NEEDS ATTENTION" }
        if controller.deliveryError != nil { return "DELIVERY ERROR" }
        if controller.isBlockingDisabled { return "PAUSED" }
        if controller.status == .active {
            return FilterEnforcementSummary.isHealthy(enforcementHealth) ? "ACTIVE" : "NEEDS ATTENTION"
        }
        return controller.status.description.uppercased()
    }

    private var statusForeground: Color {
        hasWarning ? .white : .black
    }

    private var statusColor: Color {
        if hasWarning { return .red }
        if controller.isBlockingDisabled { return .orange }
        return switch controller.status {
        case .active: MacBrutalPalette.signal
        case .disabled: .orange
        case .failed: .red
        default: MacBrutalPalette.scheduleSignal
        }
    }
}

private struct MacEnforcementStatusMenu: View {
    @ObservedObject var controller: MacEnforcementController
    let syncStatus: String
    let enforcementHealth: FilterEnforcementSummary.Health
    let install: () -> Void
    @ObservedObject var model: MacAppModel
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WEB ENFORCEMENT")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                    Text(statusSummary)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(hasWarning ? Color.red : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(MacBrutalPalette.canvas)
            .overlay { Rectangle().stroke(statusColor, lineWidth: hasWarning ? 2 : 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Web enforcement status: \(statusSummary)")
        .popover(isPresented: $isShowingDetails, arrowEdge: .leading) {
            MacEnforcementBanner(
                controller: controller,
                syncStatus: syncStatus,
                enforcementHealth: enforcementHealth,
                install: install,
                model: model
            )
            .frame(width: 680)
        }
    }

    private var hasWarning: Bool {
        controller.activationSafetyRequiresRestart
            || controller.recoveryWarning != nil
            || controller.deliveryError != nil
            || (!controller.isBlockingDisabled && !FilterEnforcementSummary.isHealthy(enforcementHealth))
    }

    private var statusSummary: String {
        if controller.activationSafetyRequiresRestart { return "SAFETY LOCKED" }
        if controller.recoveryWarning != nil { return "NEEDS ATTENTION" }
        if controller.deliveryError != nil { return "DELIVERY ERROR" }
        if controller.isBlockingDisabled { return "PAUSED" }
        if controller.status == .active {
            return FilterEnforcementSummary.isHealthy(enforcementHealth) ? "ACTIVE" : "NEEDS ATTENTION"
        }
        return controller.status.description.uppercased()
    }

    private var statusColor: Color {
        if hasWarning { return .red }
        return switch controller.status {
        case .active: MacBrutalPalette.signal
        case .disabled: .orange
        case .failed: .red
        default: MacBrutalPalette.scheduleSignal
        }
    }
}

private struct MacEnforcementBanner: View {
    @ObservedObject var controller: MacEnforcementController
    let syncStatus: String
    let enforcementHealth: FilterEnforcementSummary.Health
    let install: () -> Void
    @ObservedObject var model: MacAppModel
    @State private var isShowingRemoval = false
    @State private var blockingDisableChallenge: DesktopBlockingDisableChallenge?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(controller.status.description, systemImage: statusIcon)
                        .font(.system(.headline, design: .monospaced, weight: .black))
                    Spacer()
                    Text(syncStatus.uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text("iPhone rules sync through iCloud. On this Mac, an approval-free Network Extension enforces domains, DNS queries, and common web-filter bypass paths. Local app-launch enforcement is not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What the filter reports it is actually enforcing. A rejected
                // or stale policy is otherwise invisible: the rules simply do
                // nothing, which looks the same as a filter that is fine.
                Label(
                    controller.isBlockingDisabled
                        ? "Web blocking is paused; internet traffic is not being filtered."
                        : (controller.enforcementPreparationMessage ?? FilterEnforcementSummary.description(for: enforcementHealth)),
                    systemImage: controller.isBlockingDisabled
                        ? "pause.circle"
                        : (FilterEnforcementSummary.isHealthy(enforcementHealth)
                        ? "checkmark.seal"
                        : "exclamationmark.triangle.fill")
                )
                .font(.caption)
                .foregroundStyle(
                    controller.isBlockingDisabled || FilterEnforcementSummary.isHealthy(enforcementHealth)
                        ? Color.secondary
                        : Color.red
                )
                .textSelection(.enabled)
                if let warning = controller.recoveryWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .textSelection(.enabled)
                }
                ForEach(model.heldWeakenings) { held in
                    Label(
                        "\(held.name): a looser version arrived without this Mac's unlock. The current rules stay in force until \(held.appliesAt.formatted(date: .abbreviated, time: .shortened)), or unlock the group here to apply it now.",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
                }
                if let deliveryError = controller.deliveryError {
                    Label("Policy delivery: \(deliveryError)", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                }
                if controller.activationSafetyRequiresRestart {
                    Label(
                        "Web enforcement is safety-locked off after a Network Extension failure. Resetting removes and verifies its preference, tests ordinary connectivity, and keeps blocking disabled until you explicitly enable it.",
                        systemImage: "arrow.counterclockwise.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
                    if let reason = controller.activationSafetyReason {
                        Text("Recorded cause: \(reason)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let resetStatus = controller.enforcementResetStatus {
                    Label(
                        resetStatus,
                        systemImage: controller.isResettingEnforcement
                            ? "network.badge.shield.half.filled"
                            : "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        controller.activationSafetyRequiresRestart
                            ? Color.orange
                            : Color.secondary
                    )
                    .textSelection(.enabled)
                }
                if let smokeTestStatus = model.smokeTestStatus {
                    Label(smokeTestStatus, systemImage: "network.badge.shield.half.filled")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .textSelection(.enabled)
                }
            }

            Rectangle().fill(MacBrutalPalette.rule).frame(height: 1)

            HStack(spacing: 8) {
                if controller.isRemoving {
                    if controller.status == .rebootRequired {
                        Label("Restart this Mac to finish removal", systemImage: "restart")
                            .font(.callout.weight(.medium))
                    } else {
                        ProgressView("Removing Network Extension…")
                            .controlSize(.small)
                    }
                } else {
                    if controller.isBlockingDisabled {
                        if controller.activationSafetyRequiresRestart {
                            if controller.isResettingEnforcement {
                                ProgressView("Resetting enforcement safely…")
                                    .controlSize(.small)
                            } else {
                                Button("Reset Enforcement Without Restart") {
                                    model.resetDesktopEnforcementWithoutRestart()
                                }
                                .buttonStyle(.borderedProminent)
                                .help("Keeps blocking off, removes and verifies the filter preference, and tests connectivity before clearing the safety interlock")
                            }
                            if controller.deliveryError != nil {
                                Button("Retry Disable") {
                                    model.disableDesktopBlockingImmediately()
                                }
                            }
                        } else if controller.deliveryError != nil {
                            Button("Retry Disable") {
                                model.disableDesktopBlockingImmediately()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Enable Web Enforcement", action: install)
                                .buttonStyle(.borderedProminent)
                        }
                    } else if controller.recoveryWarning != nil || controller.deliveryError != nil {
                        if controller.status == .awaitingApproval {
                            Button("Open System Settings") {
                                model.openNetworkExtensionSettings()
                            }
                        }
                        if case .failed = controller.status {
                            Button("Retry Web Enforcement", action: install)
                        }
                        Button("Disable All Web Blocks With Passage…", role: .destructive) {
                            blockingDisableChallenge = model.makeDesktopBlockingDisableChallenge()
                        }
                        .help("Type the confirmation passage to pause every web block immediately")
                    } else if controller.status == .active || controller.status == .rebootRequired {
                        Button("Disable Blocking With Passage", role: .destructive) {
                            blockingDisableChallenge = model.makeDesktopBlockingDisableChallenge()
                        }
                        .help("Requires a confirmation passage before disabling the Network Extension")
                    } else if controller.status == .awaitingApproval {
                        ProgressView("Waiting for Network Extension approval…")
                            .controlSize(.small)
                        Button("Open System Settings") {
                            model.openNetworkExtensionSettings()
                        }
                        Button("Cancel Enable", role: .destructive) {
                            model.disableDesktopBlockingImmediately()
                        }
                    } else if controller.status == .activating {
                        ProgressView("Enabling web enforcement safely…")
                            .controlSize(.small)
                        Button("Cancel Enable", role: .destructive) {
                            model.disableDesktopBlockingImmediately()
                        }
                    } else {
                        Button("Install Web Enforcement", action: install)
                            .buttonStyle(.borderedProminent)
                    }

                    if controller.status != .notInstalled,
                       !controller.isResettingEnforcement {
                        Button("Remove Network Extension…", role: .destructive) {
                            isShowingRemoval = true
                        }
                    }
                }
            }
            .buttonStyle(MacBrutalButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(MacBrutalPalette.surface)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
        .overlay(alignment: .top) { Rectangle().fill(statusColor).frame(height: 7) }
        .sheet(isPresented: $isShowingRemoval) {
            MacRemovalSheet(model: model)
        }
        .sheet(item: $blockingDisableChallenge) { challenge in
            MacBlockingDisableSheet(challenge: challenge, model: model)
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .active: "lock.shield.fill"
        case .disabled: "lock.open.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .awaitingApproval, .rebootRequired: "person.badge.key.fill"
        default: "lock.shield"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .active: MacBrutalPalette.signal
        case .disabled: .orange
        case .failed: .red
        default: MacBrutalPalette.scheduleSignal
        }
    }
}

/// The ordinary pause control is deliberately gated. This is separate from
/// watchdog and repair controls, which must remain immediately available if the
/// Network Extension itself causes an outage.
private struct MacBlockingDisableSheet: View {
    @Environment(\.dismiss) private var dismiss
    let challenge: DesktopBlockingDisableChallenge
    @ObservedObject var model: MacAppModel
    @State private var typedPassage = ""
    @State private var validationError: DesktopBlockingDisableGate.Validation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Disable web blocking")
                .font(.title3.weight(.semibold))
            Text("This pauses every web filter until you manually enable web enforcement again.")
                .font(.callout)
            Text("Type this passage exactly. It expires after five minutes and becomes invalid if filter settings change.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MacConfirmationPassageView(passage: challenge.requiredPassage)

            MacPassageInput(text: $typedPassage)
                .frame(height: 110)
                .macBrutalTextField()
                .lineLimit(3...8)

            if let validationError {
                Label(validationMessage(for: validationError), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacBrutalButtonStyle())
                Button("Disable Blocking", role: .destructive) {
                    confirm()
                }
                .buttonStyle(MacBrutalButtonStyle(.danger))
                .disabled(typedPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .macBrutalSheet()
    }

    private func confirm() {
        let validation = model.disableDesktopBlocking(
            challenge: challenge,
            passage: typedPassage
        )
        if validation == .authorized {
            dismiss()
        } else {
            validationError = validation
        }
    }

    private func validationMessage(for validation: DesktopBlockingDisableGate.Validation) -> String {
        switch validation {
        case .authorized:
            "Blocking was disabled."
        case .passageMismatch:
            "That does not match the passage."
        case .expired:
            "This passage expired. Close this window and request a new one."
        case .policyChanged:
            "Filter settings changed. Close this window and request a new passage."
        case .notYetValid:
            "This passage is not valid yet. Close this window and request a new one."
        }
    }
}

/// Starts and ends a lockdown session: hold chosen block lists on for a set
/// period, ignoring their schedules, under the same lock settings a normal
/// locked rule uses.
private struct MacLockdownSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacAppModel
    @State private var selectedRuleIDs: Set<UUID> = []
    @State private var durationIndex = 4
    @State private var severity = "passageOnly"
    @State private var passageWordCount = 80
    @State private var unlockDelayDays = 0
    @State private var typedPassage = ""
    @State private var endingSessionID: UUID?
    @State private var didFailPassage = false

    private static let severities = ["passageOnly", "delayed", "repeatedConfirmations"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lockdown session").font(.title3.weight(.semibold))
            Text(model.lockdownSyncStatus).font(.caption).foregroundStyle(.secondary)

            if !model.activeLockdownSessions.isEmpty {
                activeSection
                Divider()
            }
            startSection

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .macBrutalSheet()
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Running now").font(.headline)
            ForEach(model.activeLockdownSessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(names(for: session)) — \(DesktopLockdownSessionGate.remainingDescription(session.remaining(at: Date()))) left",
                        systemImage: "lock.fill"
                    )
                    .font(.callout.weight(.medium))

                    if endingSessionID == session.id {
                        Text("Type this passage to end early:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(session.earlyExitPassage)
                            .textSelection(.disabled)
                            .font(.system(.caption, design: .monospaced))
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                        MacPassageInput(text: $typedPassage)
                            .frame(height: 100)
                            .macBrutalTextField()
                            .lineLimit(2...4)
                        if didFailPassage {
                            Text(model.errorMessage ?? "That passage does not match.").font(.caption).foregroundStyle(Color.red)
                        }
                        HStack {
                            Button("End session", role: .destructive) {
                                didFailPassage = !model.endLockdownSession(id: session.id, passage: typedPassage)
                                if !didFailPassage { endingSessionID = nil; typedPassage = "" }
                            }
                            Button("Keep going") { endingSessionID = nil; typedPassage = "" }
                        }
                    } else {
                        Button("End early…") {
                            endingSessionID = session.id
                            typedPassage = ""
                            didFailPassage = false
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(MacBrutalPalette.raisedSurface)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            }
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a new session").font(.headline)
            Text("The selected groups are held on across all your devices for the whole period, whatever their schedules say and whether or not they are enabled. An authorized early exit ends the session on all devices.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.rules) { rule in
                        Toggle(isOn: Binding(
                            get: { selectedRuleIDs.contains(rule.id) },
                            set: { if $0 { selectedRuleIDs.insert(rule.id) } else { selectedRuleIDs.remove(rule.id) } }
                        )) {
                            Text("\(rule.name) — \(rule.domains.count) domain(s)")
                        }
                        .toggleStyle(MacBrutalCheckboxStyle())
                    }
                }
            }
            .frame(maxHeight: 130)

            Picker("Duration", selection: $durationIndex) {
                ForEach(Array(DesktopLockdownSessionGate.offeredDurations.enumerated()), id: \.offset) { index, option in
                    Text(option.label).tag(index)
                }
            }
            Picker("Lock mode", selection: $severity) {
                ForEach(Self.severities, id: \.self) { Text(label(for: $0)).tag($0) }
            }
            Stepper("Passage length: \(passageWordCount) words", value: $passageWordCount, in: 20...300)
            if severity != "passageOnly" {
                Stepper("Extra delay before early exit: \(unlockDelayDays)d", value: $unlockDelayDays, in: 0...30)
            }

            Button("Start lockdown", role: .destructive) {
                model.startLockdownSession(
                    ruleIDs: selectedRuleIDs,
                    duration: DesktopLockdownSessionGate.offeredDurations[durationIndex].seconds,
                    lockdown: DesktopLockdownPolicy(
                        severity: severity,
                        unlockDelayDays: unlockDelayDays,
                        passageWordCount: passageWordCount,
                        confirmationWindowHours: 24,
                        editWindowHours: 1,
                        allowsTimeExtensions: false,
                        maximumTimeExtensionHours: 0
                    )
                )
                selectedRuleIDs = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedRuleIDs.isEmpty)
        }
    }

    private func label(for severity: String) -> String {
        switch severity {
        case "passageOnly": "Passage only"
        case "repeatedConfirmations": "Repeated confirmations"
        default: "Delayed"
        }
    }

    private func names(for session: DesktopLockdownSession) -> String {
        session.ruleIDs.map { id in
            model.rules.first { $0.id == id }?.name ?? session.ruleSnapshots?.first { $0.id == id }?.name ?? "Unavailable group"
        }.sorted().joined(separator: ", ")
    }
}

/// An always-available extension-removal escape hatch. It does not inherit a
/// rule's time delay because an unhealthy Network Extension must never trap the
/// machine; the fixed eighty-word acknowledgement keeps removal deliberate.
private struct MacRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacAppModel
    @State private var typedPassage = ""
    @State private var didFailPassage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove Network Extension")
                .font(.title3.weight(.semibold))

            Label(
                "Removing the extension disables all website filtering on this Mac.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.red)

            Text("Your rules will remain in the app, but they cannot block network traffic until the extension is installed and approved again.")
                .font(.callout)

            Text("macOS may ask for an administrator password or approval. Removal may require restarting this Mac before it finishes.")
                .font(.callout)

            Text("Type this \(DesktopNetworkExtensionRemovalGate.requiredWordCount)-word passage exactly, including capitalization and punctuation:")
                .font(.caption)
                .foregroundStyle(.secondary)

            MacConfirmationPassageView(passage: DesktopNetworkExtensionRemovalGate.requiredPassage, height: 190)

            MacPassageInput(text: $typedPassage)
                .frame(height: 140)
                .macBrutalTextField()
                .lineLimit(4...10)
                .onChange(of: typedPassage) { _, _ in
                    didFailPassage = false
                }

            if didFailPassage {
                Label(
                    "That does not match the displayed passage exactly. The extension was not removed.",
                    systemImage: "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.red)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacBrutalButtonStyle())
                Button("Remove Network Extension", role: .destructive) {
                    let validation = model.removeDesktopNetworkExtension(passage: typedPassage)
                    didFailPassage = validation != .authorized
                    if validation == .authorized { dismiss() }
                }
                .buttonStyle(MacBrutalButtonStyle(.danger))
                .disabled(typedPassage.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .macBrutalSheet()
    }
}
