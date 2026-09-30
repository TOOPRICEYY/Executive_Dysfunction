import SwiftUI

private enum IOSWorkspaceSection: String, CaseIterable, Identifiable {
    case dashboard, retreats, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .retreats: "Retreats"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .retreats: "house"
        case .settings: "gearshape"
        }
    }
}

struct IOSWorkspaceRoot: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(IOSInterfaceTheme.storageKey) private var storedTheme = IOSInterfaceTheme.light.rawValue
    @AppStorage(IOSHighlightColor.storageKey) private var storedHighlight = IOSHighlightColor.themeDefault.rawValue
    @State private var selection = IOSWorkspaceSection.dashboard

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(IOSWorkspaceSection.allCases) { section in
                        Button {
                            selection = section
                        } label: {
                            Label(section.title.uppercased(), systemImage: section.icon)
                                .font(.system(.callout, design: .default, weight: .bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selection == section
                                ? IOSBrutalPalette.signal.opacity(0.25)
                                : Color.clear
                        )
                    }
                    .navigationTitle("HOLDFAST")
                    .listStyle(.sidebar)
                } detail: {
                    workspaceView(selection)
                }
            } else {
                TabView(selection: $selection) {
                    ForEach(IOSWorkspaceSection.allCases) { section in
                        workspaceView(section)
                            .tabItem { Label(section.title, systemImage: section.icon) }
                            .tag(section)
                    }
                }
            }
        }
        .font(.system(.body, design: .default))
        .tint(IOSBrutalPalette.controlAccent)
        .background(IOSBrutalPalette.canvas)
        .preferredColorScheme(
            IOSInterfaceTheme(rawValue: storedTheme)?.colorScheme ?? .light
        )
        .id(storedHighlight)
        .onAppear(perform: synchronizeAppIcon)
        .onChange(of: storedTheme) { _, _ in synchronizeAppIcon() }
        .onChange(of: storedHighlight) { _, _ in synchronizeAppIcon() }
    }

    @ViewBuilder
    private func workspaceView(_ section: IOSWorkspaceSection) -> some View {
        switch section {
        case .dashboard: IOSDashboardView()
        case .retreats: IOSRetreatsView()
        case .settings: IOSSettingsHubView()
        }
    }

    private func synchronizeAppIcon() {
        IOSDynamicAppIcon.synchronize(theme: storedTheme, highlight: storedHighlight)
    }
}

struct IOSDashboardView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showProtectionSettings = false
    @State private var showLockdown = false
    @State private var groupSearch = ""
    @EnvironmentObject private var model: AppModel
    @State private var editingBlockingGroup: CloudBlockingGroup?
    @State private var editingRetreat: CloudRetreat?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    statusHero
                    activeObjects
                    IOSBlockStatusTimeline(calendarRules: model.dashboardCalendarRules)
                    BypassActivityPanel(groups: model.rules.map { .init(id: $0.id, name: $0.name) },
                        defaults: SharedConfiguration.bypassHistoryDefaults,
                        coverageNote: "This iPhone or iPad only. App grants include requests opened from a Screen Time shield.")
                }
                .padding(16)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("DASHBOARD")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Lockdown", systemImage: "lock.shield") { showLockdown = true }
                        Button("New Blocking Group", systemImage: "plus.square") {
                            editingBlockingGroup = CloudBlockingGroup()
                        }
                        Button("New Retreat", systemImage: "house.badge.plus") {
                            editingRetreat = CloudRetreat()
                        }
                        Menu {
                            ForEach(HoldfastPresets.blockingPresets) { preset in
                                Button(preset.name) { model.installPreset(preset) }
                            }
                        } label: {
                            Label("Start from Preset", systemImage: "square.stack.3d.up")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showProtectionSettings) { SettingsView().environmentObject(model) }
            .sheet(isPresented: $showLockdown) { IOSTimedLockdownView().environmentObject(model) }
            .sheet(item: $editingBlockingGroup) { value in
                IOSBlockingGroupEditor(initialGroup: value)
                    .environmentObject(model)
            }
            .sheet(item: $editingRetreat) { value in
                IOSRetreatEditor(initialRetreat: value, isNew: !model.retreats.contains(where: { $0.id == value.id }))
                    .environmentObject(model)
            }
        }
    }

    private var statusHero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
        let allowances = model.ruleTimeAllowances.values.filter { $0.isActive(at: context.date) && model.lockdownExpirations[$0.ruleID] == nil }
        let pausedIDs = Set(allowances.map(\.ruleID))
        let scheduledIDs = Set(model.rules.filter { $0.isEnabled && $0.windows.contains { $0.isActive(at: context.date) } }.map(\.id))
        let heldIDs = Set(model.activeTimedLockdowns.filter { !model.lockdownMonitoringFailures.contains($0.id) }.flatMap { $0.rules.map(\.id) })
        let blockingCount = scheduledIDs.union(heldIDs).subtracting(pausedIDs).count
        IOSBrutalCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: model.isAuthorized ? "shield.checkered" : "exclamationmark.shield")
                    .font(.title2).foregroundStyle(model.isAuthorized ? Color.primary : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isAuthorized ? (blockingCount == 0 ? (allowances.isEmpty ? "Ready when you are" : "Temporary access active") : "Protection is active") : "Connect Screen Time")
                        .font(.title2.weight(.semibold))
                    Text(model.isAuthorized ? "\(HoldfastPresentation.count(blockingCount, "group")) blocking now · \(HoldfastPresentation.count(model.activeRetreats.count, "active retreat"))" : "Allow Screen Time access so Holdfast can enforce your groups on this device.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !model.isAuthorized {
                Button("Review Screen Time access") { showProtectionSettings = true }
                    .buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
            }
            ForEach(model.activeTimedLockdowns) { session in
                Text(session.rules.map(\.name).joined(separator: ", ")).font(.caption.weight(.semibold))
                LockdownStatusBadge(endsAt: session.endsAt)
                if model.lockdownMonitoringFailures.contains(session.id) {
                    Label("Lockdown needs attention: Screen Time monitor unavailable. Open lockdown controls for details.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if !model.activeTimedLockdowns.isEmpty {
                Text(model.lockdownSyncStatus).font(.caption).foregroundStyle(.secondary)
                Text("iOS timing is approximate in the background. Reopen Holdfast to reconcile the exact deadline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.activeTimedLockdowns.isEmpty ? "Start lockdown" : "Manage lockdowns") { showLockdown = true }
                .buttonStyle(IOSBrutalButtonStyle())
                .accessibilityIdentifier("manage-timed-lockdown")
            if !allowances.isEmpty {
                Text("\(allowances.count) temporarily allowed").font(.caption.weight(.semibold))
                // Baseline groups have their own visible rows below. Include
                // retreat-only groups here so their pauses are not hidden.
                ForEach(allowances.filter { pause in !model.baseline.blockingGroups.contains { $0.id == pause.ruleID } }
                    .sorted { $0.ruleID.uuidString < $1.ruleID.uuidString }, id: \.ruleID) { pause in
                    Text(model.rules.first { $0.id == pause.ruleID }?.name ?? "Blocking Group").font(.caption)
                    TemporaryAllowanceStatusView(expiresAt: pause.expiresAt)
                }
            }
            Text("iCloud · \(model.cloudSyncStatus)").font(.caption).foregroundStyle(.secondary)
        }
        }
    }

    @ViewBuilder
    private var activeObjects: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 16) {
                blockingPanel.frame(maxWidth: .infinity)
                retreatPanel.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 16) {
                blockingPanel
                retreatPanel
            }
        }
    }

    private var blockingPanel: some View {
        IOSObjectPanel(title: "BLOCKING GROUPS", count: model.baseline.blockingGroups.count) {
            if model.baseline.blockingGroups.isEmpty {
                IOSEmptyObjectRow(text: "Choose the apps and websites you want to spend less time with.")
            } else {
                if model.baseline.blockingGroups.count > 4 {
                    TextField("Find a Blocking Group", text: $groupSearch)
                        .iosBrutalField().padding(12).accessibilityIdentifier("group-search")
                }
                if !groupSearch.isEmpty && !model.baseline.blockingGroups.contains(where: { $0.name.localizedCaseInsensitiveContains(groupSearch) }) {
                    IOSEmptyObjectRow(text: "No matching groups. Try a different name.")
                }
                ForEach(model.baseline.blockingGroups.filter { groupSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(groupSearch) }) { group in
                    Button { editingBlockingGroup = group } label: {
                        VStack(alignment: .leading, spacing: 0) {
                        if let end = model.lockdownExpirations[group.id] {
                            LockdownStatusBadge(endsAt: end).padding(.horizontal, 16).padding(.top, 8)
                        } else if let pause = model.activeTimeAllowance(for: group.id) {
                            TemporaryAllowanceStatusView(expiresAt: pause.expiresAt)
                                .padding(.horizontal, 16).padding(.top, 8)
                        }
                        IOSObjectRow(
                            title: group.name,
                            detail: "\(HoldfastPresentation.targets(group.targets))\n\(group.isEnabled ? "Schedule enabled" : "Saved schedule disabled") · \(HoldfastPresentation.schedule(group.timeWindow))",
                            color: group.isEnabled || model.lockdownExpirations[group.id] != nil ? IOSBrutalPalette.signal : IOSBrutalPalette.raised,
                            statuses: blockingGroupStatuses(group)
                        )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("NEW BLOCKING GROUP") { editingBlockingGroup = CloudBlockingGroup() }
                .buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
                .padding(12)
        }
    }

    private func blockingGroupStatuses(_ group: CloudBlockingGroup) -> [IOSObjectStatus] {
        [
            IOSObjectStatus(
                icon: model.lockdownExpirations[group.id] != nil ? "lock.shield" : (group.isEnabled ? "bolt.fill" : "pause.fill"),
                label: model.lockdownExpirations[group.id] != nil ? "LOCKDOWN" : (group.isEnabled ? "ENABLED" : "DISABLED")
            ),
            lockStatus(group.modificationPolicy)
        ]
    }

    private func lockStatus(_ policy: CloudRuleLockdownPreference) -> IOSObjectStatus {
        switch policy.severity {
        case "none":
            IOSObjectStatus(icon: "lock.open.fill", label: "UNLOCKED")
        case "passageOnly":
            IOSObjectStatus(icon: "key.fill", label: "PASSAGE LOCK")
        case "delayed":
            IOSObjectStatus(icon: "clock.fill", label: "DELAYED LOCK")
        case "repeatedConfirmations":
            IOSObjectStatus(icon: "arrow.triangle.2.circlepath", label: "REPEATED LOCK")
        default:
            IOSObjectStatus(
                icon: model.lockdownConfiguration.isEnabled ? "lock.fill" : "lock.open.fill",
                label: model.lockdownConfiguration.isEnabled ? "APP LOCK" : "APP DEFAULT UNLOCKED"
            )
        }
    }

    private var retreatPanel: some View {
        IOSObjectPanel(title: "ACTIVE RETREATS", count: model.activeRetreats.count) {
            if model.activeRetreats.isEmpty {
                IOSEmptyObjectRow(text: "Make room for something else with a time-limited retreat.")
            } else {
                ForEach(model.activeRetreats) { retreat in
                    Button { editingRetreat = retreat } label: {
                        IOSObjectRow(
                            title: retreat.name,
                            detail: retreat.plannedEnd.formatted(.relative(presentation: .named)),
                            color: IOSBrutalPalette.signal
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("NEW RETREAT") { editingRetreat = CloudRetreat() }
                .buttonStyle(IOSBrutalButtonStyle())
                .padding(12)
        }
    }
}

private struct IOSObjectPanel<Content: View>: View {
    let title: String
    let count: Int
    let content: Content

    init(title: String, count: Int, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(.headline, design: .default, weight: .semibold))
                Text("\(count)")
                    .font(.system(.caption, design: .default, weight: .semibold))
                    .padding(6)
                    .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                Spacer()
            }
            .padding(14)
            .overlay(alignment: .bottom) { Rectangle().fill(IOSBrutalPalette.rule).frame(height: 1) }
            content
        }
        .background(IOSBrutalPalette.surface)
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
    }
}

private struct IOSObjectRow: View {
    let title: String
    let detail: String
    let color: Color
    var statuses: [IOSObjectStatus] = []

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(color).frame(width: 7, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.callout, design: .default, weight: .semibold))
                     .lineLimit(3)
                Text(detail)
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                     .lineLimit(3)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(statuses) { status in
                    Image(systemName: status.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(IOSBrutalPalette.raised)
                        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                        .accessibilityLabel(status.label)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(IOSBrutalPalette.rule.opacity(0.45)).frame(height: 1) }
    }
}

private struct IOSObjectStatus: Identifiable {
    let icon: String
    let label: String
    var id: String { "\(icon)-\(label)" }
}

private struct IOSEmptyObjectRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .default, weight: .bold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    }
}

struct IOSRetreatsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingRetreat: CloudRetreat?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Build a longer break from your Blocking Groups. Past retreats keep their configuration so you can use them again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    retreatSection("ACTIVE", retreats: model.retreats.filter { $0.state == .active })
                    retreatSection("PLANNED & DRAFTS", retreats: model.retreats.filter { $0.state == .draft || $0.state == .scheduled })
                    retreatSection("HISTORY", retreats: model.completedRetreats)
                }
                .padding(16)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("RETREATS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New", systemImage: "plus") { editingRetreat = CloudRetreat() }
                }
            }
            .sheet(item: $editingRetreat) { retreat in
                IOSRetreatEditor(
                    initialRetreat: retreat,
                    isNew: !model.retreats.contains(where: { $0.id == retreat.id })
                )
                .environmentObject(model)
            }
        }
    }

    private func retreatSection(_ title: String, retreats: [CloudRetreat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .default, weight: .semibold))
            if retreats.isEmpty {
                IOSBrutalCard { Text(title == "HISTORY" ? "Finished retreats will appear here, ready to recreate." : title == "ACTIVE" ? "No retreat is active right now." : "Create a retreat to plan your next break.").font(.subheadline).foregroundStyle(.secondary) }
            }
            ForEach(retreats) { retreat in
                IOSBrutalCard {
                    if retreat.state.isLiveConfiguration {
                        Button { editingRetreat = retreat } label: {
                            IOSObjectRow(
                                title: retreat.name,
                                detail: "\(HoldfastPresentation.state(retreat.state)) · Version \(retreat.currentVersionNumber)\n\(retreat.plannedStart.formatted(date: .abbreviated, time: .omitted)) – \(retreat.plannedEnd.formatted(date: .abbreviated, time: .omitted))",
                                color: retreat.state == .active ? IOSBrutalPalette.signal : IOSBrutalPalette.raised
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        IOSObjectRow(
                            title: retreat.name,
                            detail: "\(HoldfastPresentation.state(retreat.state)) · Version \(retreat.currentVersionNumber)\n\(retreat.plannedStart.formatted(date: .abbreviated, time: .omitted)) – \(retreat.plannedEnd.formatted(date: .abbreviated, time: .omitted))",
                            color: IOSBrutalPalette.raised
                        )
                    }
                    if retreat.state == .completed || retreat.state == .endedEarly {
                        Button("Recreate retreat") { model.recreateRetreat(retreat) }
                            .buttonStyle(IOSBrutalButtonStyle())
                            .padding([.horizontal, .bottom], 12)
                    }
                }
            }
        }
    }
}

struct IOSSettingsHubView: View {
    @AppStorage(IOSInterfaceTheme.storageKey) private var theme = IOSInterfaceTheme.light.rawValue
    @AppStorage(IOSHighlightColor.storageKey) private var highlight = IOSHighlightColor.themeDefault.rawValue
    @State private var showProtectionSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Button { showProtectionSettings = true } label: {
                        IOSBrutalCard {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.shield").font(.title2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Protection & system").font(.headline)
                                    Text("Screen Time, sync, change policies and diagnostics")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("PROTECTION & SYSTEM SETTINGS")
                    IOSBrutalCard {
                        Text("APPEARANCE")
                            .font(.system(.headline, design: .default, weight: .semibold))
                        Picker("Theme", selection: $theme) {
                            ForEach(IOSInterfaceTheme.allCases) { option in
                                Text(option.label.capitalized).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("HIGHLIGHT COLOR")
                            .font(.system(.caption, design: .default, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        Text("Your accent and theme also update the app icon.")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                            ForEach(IOSHighlightColor.allCases) { option in
                                Button {
                                    highlight = option.rawValue
                                } label: {
                                    HStack {
                                        Rectangle()
                                            .fill(Color(uiColor: option.uiColor(isDark: theme == IOSInterfaceTheme.dark.rawValue)))
                                            .frame(width: 18, height: 18)
                                        Text(option.label.capitalized).lineLimit(2)
                                    }
                                    .font(.system(.caption2, design: .default, weight: .bold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(IOSBrutalButtonStyle(
                                    emphasis: highlight == option.rawValue ? .primary : .secondary
                                ))
                            }
                        }
                    }
                    
                }
                .padding(16)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("SETTINGS")
            .sheet(isPresented: $showProtectionSettings) { SettingsView() }
        }
    }
}
