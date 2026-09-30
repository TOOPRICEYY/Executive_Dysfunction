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
                LazyVStack(alignment: .leading, spacing: 12) {
                    statusHero
                    activeObjects
                    if !model.dashboardCalendarRules.isEmpty {
                        schedulePanel
                    }
                    // The bypass report is a full list of reference material,
                    // so it starts folded and remembers how you left it.
                    IOSCollapsibleSection(
                        title: "BYPASSES",
                        summary: "Temporary access you granted",
                        storageKey: "dashboard.bypasses-expanded"
                    ) {
                        BypassActivityPanel(groups: model.rules.map { .init(id: $0.id, name: $0.name) },
                            defaults: SharedConfiguration.bypassHistoryDefaults,
                            coverageNote: "This iPhone or iPad only. App grants include requests opened from a Screen Time shield.")
                    }
                    Text("iCloud · \(model.cloudSyncStatus)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("DASHBOARD")
            .navigationBarTitleDisplayMode(.inline)
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
        let summary = DashboardNowSummary(groups: model.baseline.blockingGroups.map {
            DashboardNowSummary.Group(name: $0.name, state: nowState($0, now: context.date))
        })
        VStack(alignment: .leading, spacing: 8) {
            if model.isAuthorized {
                Text((blockingCount == 0 && !allowances.isEmpty ? "Temporary access active" : summary.headline).uppercased())
                    .font(.system(.title3, design: .default, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if let next = summary.nextLine(now: context.date) {
                    Text(next)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dashboard-next-change")
                }
            } else {
                Label("Connect Screen Time", systemImage: "exclamationmark.shield")
                    .font(.system(.title3, design: .default, weight: .bold))
                    .foregroundStyle(.orange)
                Text("Allow Screen Time access so Holdfast can enforce your groups on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Review Screen Time access") { showProtectionSettings = true }
                    .buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
                    .controlSize(.small)
            }
            ForEach(model.activeTimedLockdowns) { session in
                HStack(spacing: 8) {
                    Text(session.rules.map(\.name).joined(separator: ", "))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    LockdownStatusBadge(endsAt: session.endsAt)
                }
                if model.lockdownMonitoringFailures.contains(session.id) {
                    Label("Screen Time monitor unavailable. Open lockdown for details.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if !allowances.isEmpty {
                // Baseline groups show their pause in their own row below;
                // list retreat-only groups here so their pauses stay visible.
                ForEach(allowances.filter { pause in !model.baseline.blockingGroups.contains { $0.id == pause.ruleID } }
                    .sorted { $0.ruleID.uuidString < $1.ruleID.uuidString }, id: \.ruleID) { pause in
                    HStack(spacing: 8) {
                        Text(model.rules.first { $0.id == pause.ruleID }?.name ?? "Blocking Group").font(.caption)
                        TemporaryAllowanceStatusView(expiresAt: pause.expiresAt)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    showLockdown = true
                } label: {
                    Label(model.activeTimedLockdowns.isEmpty ? "Lockdown" : "Manage lockdowns", systemImage: "lock.shield")
                        .font(.system(.footnote, design: .default, weight: .bold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manage-timed-lockdown")
                if !model.activeTimedLockdowns.isEmpty {
                    Text("Timing is approximate in the background.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSBrutalPalette.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(blockingCount > 0 ? IOSBrutalPalette.signal : IOSBrutalPalette.rule).frame(width: 5)
        }
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
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
                PresetStartGrid(
                    accent: IOSBrutalPalette.signal,
                    ink: IOSBrutalPalette.controlAccent,
                    rule: IOSBrutalPalette.rule,
                    onPick: { model.installPreset($0) },
                    onCustom: { editingBlockingGroup = CloudBlockingGroup() }
                )
                .padding(12)
            } else {
                if model.baseline.blockingGroups.count > 4 {
                    TextField("Find a Blocking Group", text: $groupSearch)
                        .iosBrutalField().padding(12).accessibilityIdentifier("group-search")
                }
                if !groupSearch.isEmpty && !model.baseline.blockingGroups.contains(where: { $0.name.localizedCaseInsensitiveContains(groupSearch) }) {
                    IOSEmptyObjectRow(text: "No matching groups. Try a different name.")
                }
                let now = Date()
                ForEach(sortedGroups(now: now).filter { groupSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(groupSearch) }) { group in
                    let state = nowState(group, now: now)
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
                            headline: GroupNowStatus.headline(state, now: now),
                            headlineIsActive: state.isBlocking,
                            detail: HoldfastPresentation.targets(group.targets),
                            color: rowColor(state),
                            statuses: [lockStatus(group.modificationPolicy)]
                        )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if !model.baseline.blockingGroups.isEmpty {
                Button { editingBlockingGroup = CloudBlockingGroup() } label: {
                    Label("New Blocking Group", systemImage: "plus")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(IOSBrutalPalette.controlAccent)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("NEW BLOCKING GROUP")
            }
        }
    }

    private func nowState(_ group: CloudBlockingGroup, now: Date) -> GroupNowState {
        GroupNowStatus.evaluate(
            isEnabled: group.isEnabled,
            windows: group.timeWindow.effectiveBlockingSlots(),
            now: now,
            allowanceUntil: model.activeTimeAllowance(for: group.id)?.expiresAt,
            lockdownUntil: model.lockdownExpirations[group.id]
        )
    }

    /// In force first, then soonest, so the list reads "now, next, later".
    private func sortedGroups(now: Date) -> [CloudBlockingGroup] {
        model.baseline.blockingGroups
            .map { ($0, nowState($0, now: now)) }
            .sorted { lhs, rhs in
                if lhs.1.sortRank != rhs.1.sortRank { return lhs.1.sortRank < rhs.1.sortRank }
                let a = lhs.1.changesAt ?? .distantFuture, b = rhs.1.changesAt ?? .distantFuture
                if a != b { return a < b }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    private func rowColor(_ state: GroupNowState) -> Color {
        switch state {
        case .lockdown, .blocking: IOSBrutalPalette.signal
        case .paused: .orange
        case .upcoming: IOSBrutalPalette.signal.opacity(0.35)
        case .idle, .off: IOSBrutalPalette.raised
        }
    }

    /// One lane per group, one day at a time, with a seven-day strip.
    private var schedulePanel: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScheduleLanesView(
                calendarRules: model.dashboardCalendarRules,
                now: context.date,
                states: Dictionary(
                    model.baseline.blockingGroups.map { ($0.id, nowState($0, now: context.date)) },
                    uniquingKeysWith: { first, _ in first }
                ),
                accent: IOSBrutalPalette.signal,
                ink: IOSBrutalPalette.controlAccent,
                rule: IOSBrutalPalette.rule,
                surface: IOSBrutalPalette.raised,
                labelWidth: 104,
                onSelect: { id in
                    editingBlockingGroup = model.baseline.blockingGroups.first { $0.id == id }
                }
            )
            .padding(12)
            .background(IOSBrutalPalette.surface)
            .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
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

    @ViewBuilder
    private var retreatPanel: some View {
        if model.activeRetreats.isEmpty {
            Button { editingRetreat = CloudRetreat() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "house")
                    Text("No retreat running").font(.footnote.weight(.semibold))
                    Spacer()
                    Text("Plan one").font(.footnote.weight(.bold)).foregroundStyle(IOSBrutalPalette.controlAccent)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(IOSBrutalPalette.surface)
                .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NEW RETREAT")
        } else {
            activeRetreatPanel
        }
    }

    private var activeRetreatPanel: some View {
        IOSObjectPanel(title: "ACTIVE RETREATS", count: model.activeRetreats.count) {
            if model.activeRetreats.isEmpty {
                EmptyView()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(IOSBrutalPalette.rule).frame(height: 1) }
            content
        }
        .background(IOSBrutalPalette.surface)
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
    }
}

private struct IOSObjectRow: View {
    let title: String
    var headline: String? = nil
    var headlineIsActive = false
    let detail: String
    let color: Color
    var statuses: [IOSObjectStatus] = []

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(color).frame(width: 7, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.callout, design: .default, weight: .semibold))
                    .lineLimit(3)
                if let headline {
                    Text(headline)
                        .font(.system(.footnote, design: .default, weight: .semibold))
                        .foregroundStyle(headlineIsActive ? Color.primary : Color.secondary)
                        .lineLimit(2)
                }
                Text(detail)
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !statuses.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(statuses) { status in
                            HStack(spacing: 3) {
                                Image(systemName: status.icon)
                                Text(status.label)
                            }
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(IOSBrutalPalette.raised)
                            .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                            .accessibilityLabel(status.label)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(IOSBrutalPalette.rule.opacity(0.45)).frame(height: 1) }
        .accessibilityElement(children: .combine)
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

/// A folded section: a slim header row that expands in place. Used for the
/// reference material below the fold so the dashboard reads as "now" first.
private struct IOSCollapsibleSection<Content: View>: View {
    let title: String
    let summary: String
    @AppStorage private var isExpanded: Bool
    let content: Content

    init(title: String, summary: String, storageKey: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        _isExpanded = AppStorage(wrappedValue: false, storageKey)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(title).font(.system(.footnote, design: .default, weight: .bold))
                    if !isExpanded {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(IOSBrutalPalette.surface)
                .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("section-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            if isExpanded {
                content
            }
        }
    }
}

