import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MacWorkspaceSection: String, CaseIterable, Identifiable {
    case dashboard
    case retreats
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "DASHBOARD"
        case .retreats: "RETREATS"
        case .history: "HISTORY"
        case .settings: "SETTINGS"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .retreats: "house"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
}

struct MacWorkspaceSidebar<StatusContent: View>: View {
    @Binding var selection: MacWorkspaceSection
    let statusContent: StatusContent

    init(
        selection: Binding<MacWorkspaceSection>,
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        _selection = selection
        self.statusContent = statusContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HOLDFAST")
                .font(.system(size: 29, weight: .semibold, design: .default))
                .tracking(-1.5)
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 30)

            Rectangle()
                .fill(MacBrutalPalette.rule)
                .frame(height: 1)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)

            ForEach(MacWorkspaceSection.allCases.filter { $0 != .settings }) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: section.symbol)
                            .frame(width: 20)
                        Text(section.title)
                            .font(.system(.callout, design: .default, weight: .bold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .foregroundStyle(selection == section ? Color.black : Color.primary)
                    .background(selection == section ? MacBrutalPalette.signal : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 24)

            statusContent
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            Rectangle()
                .fill(MacBrutalPalette.rule)
                .frame(height: 1)
                .padding(.horizontal, 18)

            Button {
                selection = .settings
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: MacWorkspaceSection.settings.symbol)
                        .frame(width: 20)
                    Text(MacWorkspaceSection.settings.title)
                        .font(.system(.callout, design: .default, weight: .bold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .frame(height: 52)
                .foregroundStyle(selection == .settings ? Color.black : Color.primary)
                .background(selection == .settings ? MacBrutalPalette.signal : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            MacThemeSwitch()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 252)
        .background(MacBrutalPalette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(MacBrutalPalette.rule).frame(width: 1)
        }
    }
}

struct MacDashboardView<StatusContent: View>: View {
    let activeRules: [CloudRulePreference]
    let calendarRules: [BlockStatusCalendarRule]
    let baselineRules: [CloudRulePreference]
    let retreats: [CloudRetreat]
    let temporaryAllowances: [UUID: Date]
    let lockdownExpirations: [UUID: Date]
    let onEdit: (CloudRulePreference) -> Void
    let onAdd: () -> Void
    let onOpenRetreats: () -> Void
    let onOpenRetreat: (CloudRetreat) -> Void
    let statusContent: StatusContent
    let bypassPanel: BypassActivityPanel?
    @State private var groupSearch = ""

    init(
        activeRules: [CloudRulePreference],
        calendarRules: [BlockStatusCalendarRule],
        baselineRules: [CloudRulePreference],
        retreats: [CloudRetreat],
        temporaryAllowances: [UUID: Date] = [:],
        lockdownExpirations: [UUID: Date] = [:],
        onEdit: @escaping (CloudRulePreference) -> Void,
        onAdd: @escaping () -> Void,
        onOpenRetreats: @escaping () -> Void,
        onOpenRetreat: @escaping (CloudRetreat) -> Void,
        bypassPanel: BypassActivityPanel? = nil,
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        self.activeRules = activeRules
        self.calendarRules = calendarRules
        self.baselineRules = baselineRules
        self.retreats = retreats
        self.temporaryAllowances = temporaryAllowances
        self.lockdownExpirations = lockdownExpirations
        self.onEdit = onEdit
        self.onAdd = onAdd
        self.onOpenRetreats = onOpenRetreats
        self.onOpenRetreat = onOpenRetreat
        self.statusContent = statusContent()
        self.bypassPanel = bypassPanel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statusContent
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        activeBlockingGroups.frame(minWidth: 440)
                        activeRetreats.frame(minWidth: 280)
                    }
                    VStack(spacing: 20) {
                        activeBlockingGroups
                        activeRetreats
                    }
                }
                secondaryActions
                MacBlockStatusTimeline(calendarRules: calendarRules)
                bypassPanel
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacBrutalPalette.canvas)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Text("DASHBOARD")
                .font(.system(size: 34, weight: .semibold, design: .default))
                .tracking(-0.5)
            Spacer()
            Text("NOW")
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
        }
    }

    private var activeBlockingGroups: some View {
        primaryPanel(title: "Blocking Groups", count: dashboardRules.count) {
            EmptyView()
        } content: {
            if dashboardRules.isEmpty {
                emptyState("Create a group to choose apps, websites and allowance windows.")
            } else {
                if dashboardRules.count > 4 {
                    TextField("Find a Blocking Group", text: $groupSearch).macBrutalTextField().padding(16)
                }
                if !groupSearch.isEmpty && !dashboardRules.contains(where: { $0.name.localizedCaseInsensitiveContains(groupSearch) }) {
                    emptyState("No matching groups. Try a different name.")
                }
                ForEach(dashboardRules.filter { groupSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(groupSearch) }) { rule in
                    Button {
                        baselineRuleIDs.contains(rule.id) ? onEdit(rule) : onOpenRetreats()
                    } label: {
                        MacDashboardBlockingGroupRow(
                            rule: rule,
                            origin: baselineRuleIDs.contains(rule.id) ? "BASELINE" : "RETREAT",
                            allowanceExpiresAt: temporaryAllowances[rule.id],
                            lockdownEndsAt: lockdownExpirations[rule.id]
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activeRetreats: some View {
        primaryPanel(title: "Active retreats", count: runningRetreats.count) {
            Button("New retreat", action: onOpenRetreats)
                .buttonStyle(MacBrutalButtonStyle())
        } content: {
            if runningRetreats.isEmpty {
                emptyState("Plan a longer break using your Blocking Groups.")
            } else {
                ForEach(runningRetreats) { retreat in
                    Button { onOpenRetreat(retreat) } label: {
                        MacDashboardRetreatRow(retreat: retreat)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            Button("NEW BLOCKING GROUP", action: onAdd)
                .buttonStyle(MacBrutalButtonStyle(.primary))
            Spacer()
            Button("All retreats · \(nonActiveLiveRetreats.count) planned", action: onOpenRetreats)
                .buttonStyle(MacBrutalButtonStyle())
        }
    }

    private var dashboardRules: [CloudRulePreference] {
        let baselineIDs = Set(baselineRules.map(\.id))
        return baselineRules + activeRules.filter { !baselineIDs.contains($0.id) }
    }

    private func primaryPanel<Trailing: View, Content: View>(
        title: String,
        count: Int,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(.title2, design: .default, weight: .semibold))
                dashboardBadge("\(count)")
                Spacer()
                trailing()
            }
            .padding(20)
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(MacBrutalPalette.surface)
        .overlay {
            Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1)
        }
    }

    private func dashboardBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .default, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MacBrutalPalette.raisedSurface)
            .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }

    private var availableRules: [CloudRulePreference] {
        let activeIDs = Set(activeRules.map(\.id))
        return baselineRules.filter { !activeIDs.contains($0.id) }
    }

    private var baselineRuleIDs: Set<UUID> {
        Set(baselineRules.map(\.id))
    }

    private var runningRetreats: [CloudRetreat] {
        retreats
            .filter { $0.state == .active }
            .sorted { $0.plannedStart < $1.plannedStart }
    }

    private var nonActiveLiveRetreats: [CloudRetreat] {
        retreats.filter { $0.state.isLiveConfiguration && $0.state != .active }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(.callout, design: .default, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }
}

private struct MacDashboardBlockingGroupRow: View {
    let rule: CloudRulePreference
    let origin: String
    let allowanceExpiresAt: Date?
    let lockdownEndsAt: Date?

    var body: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(rule.isEnabled || lockdownEndsAt != nil ? MacBrutalPalette.signal : MacBrutalPalette.raisedSurface)
                .frame(width: 9, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(rule.name)
                    .font(.system(.headline, design: .default, weight: .semibold))
                if let lockdownEndsAt {
                    LockdownStatusBadge(endsAt: lockdownEndsAt)
                } else if let allowanceExpiresAt {
                    TemporaryAllowanceStatusView(expiresAt: allowanceExpiresAt)
                }
                Text("\(rule.isEnabled ? "Schedule enabled" : "Saved schedule disabled") · \(origin.capitalized)\n\(HoldfastPresentation.targets(rule: rule))")
                    .font(.system(.caption2, design: .default, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MacDashboardBlockingGroupStatusIcons(rule: rule, isForced: lockdownEndsAt != nil)
            Image(systemName: "arrow.up.right")
                .font(.system(.caption, design: .default, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 72)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule.opacity(0.65)).frame(height: 1)
        }
    }
}

private struct MacDashboardBlockingGroupStatusIcons: View {
    let rule: CloudRulePreference
    var isForced = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon(
                isForced ? "lock.shield" : (rule.isEnabled ? "bolt.fill" : "pause.fill"),
                label: isForced ? "LOCKDOWN" : (rule.isEnabled ? "ENABLED" : "DISABLED")
            )
            statusIcon(lockStatus.icon, label: lockStatus.label)
        }
    }

    private var lockStatus: (icon: String, label: String) {
        switch rule.lockdown.severity {
        case "none":
            ("lock.open.fill", "UNLOCKED")
        case "passageOnly":
            ("key.fill", "PASSAGE LOCK")
        case "delayed":
            ("clock.fill", "DELAYED LOCK")
        case "repeatedConfirmations":
            ("arrow.triangle.2.circlepath", "REPEATED LOCK")
        default:
            ("lock.fill", "APP DEFAULT LOCK")
        }
    }

    private func statusIcon(_ name: String, label: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 27, height: 27)
            .background(MacBrutalPalette.raisedSurface)
            .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            .help(label)
            .accessibilityLabel(label)
    }
}

private struct MacDashboardRetreatRow: View {
    let retreat: CloudRetreat

    var body: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(MacBrutalPalette.signal)
                .frame(width: 9, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(retreat.name)
                    .font(.system(.headline, design: .default, weight: .semibold))
                Text("\(retreat.currentVersion?.blockingGroups.count ?? 0) GROUPS · ENDS \(retreat.plannedEnd.formatted(date: .abbreviated, time: .omitted).uppercased())")
                    .font(.system(.caption2, design: .default, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(.caption, design: .default, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 72)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule.opacity(0.65)).frame(height: 1)
        }
    }
}

struct MacActivityGroupsView: View {
    let groups: [CloudActivityGroup]
    let onEdit: (CloudActivityGroup) -> Void
    let onAdd: () -> Void
    let onDelete: (CloudActivityGroup) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACTIVITY GROUPS")
                            .font(.system(size: 34, weight: .semibold, design: .default))
                            .tracking(-0.5)
                        Text("REUSABLE LIVE OBJECTS. CHANGES APPLY EVERYWHERE.")
                            .font(.system(.caption, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("NEW GROUP", action: onAdd)
                        .buttonStyle(MacBrutalButtonStyle(.primary))
                }

                Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)

                ForEach(groups) { group in
                    Button { onEdit(group) } label: {
                        MacActivityGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Activity Group", role: .destructive) { onDelete(group) }
                    }
                }

                if groups.isEmpty {
                    Text("NO ACTIVITY GROUPS YET. CREATE ONE TO COLLECT WEBSITES, CATEGORIES, AND APPLICATION TARGETS.")
                        .font(.system(.callout, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 36)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacBrutalPalette.canvas)
    }
}

private struct MacActivityGroupRow: View {
    let group: CloudActivityGroup

    var body: some View {
        HStack(spacing: 24) {
            Rectangle()
                .fill(MacBrutalPalette.signal)
                .frame(width: 12, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                Text(group.name.uppercased())
                    .font(.system(.title3, design: .default, weight: .semibold))
                Text("LIVE TARGET COLLECTION")
                    .font(.system(.caption2, design: .default, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 220, alignment: .leading)

            Text("\(group.domains.count) DOMAINS")
            Text("\(group.websiteCategories.count) CATEGORIES")
            Text("\(portableApplicationCount) APP TARGETS")
            if group.deviceLocalSelectionCount > 0 {
                Text("\(group.deviceLocalSelectionCount) DEVICE-LOCAL")
            }
            Spacer()
            Text("EDIT →")
                .fontWeight(.bold)
        }
        .font(.system(.caption, design: .default, weight: .medium))
        .padding(.vertical, 18)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule.opacity(0.65)).frame(height: 1)
        }
    }

    private var portableApplicationCount: Int {
        group.macApplicationIdentifiers.count
            + group.windowsExecutablePaths.count
            + group.windowsPublisherRules.count
    }
}

struct MacRetreatSubmission {
    var id: UUID?
    var name: String
    var goal: String
    var plannedStart: Date
    var plannedEnd: Date
    var blockingGroups: [CloudBlockingGroup]
    var modificationPolicy: CloudRuleLockdownPreference
    var startImmediately: Bool
}

struct MacRetreatComposerView: View {
    let retreats: [CloudRetreat]
    let onOpenRetreat: (UUID?) -> Void
    let onSave: (MacRetreatSubmission) -> Void

    @State private var editingRetreatID: UUID?
    @State private var selectableGroups: [CloudBlockingGroup]
    @State private var name: String
    @State private var goal: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var selectedRuleIDs: Set<UUID>
    @State private var lockMode: String
    @State private var isReviewing = false

    private let isRecreatingPastRetreat: Bool

    init(
        baselineGroups: [CloudBlockingGroup],
        retreats: [CloudRetreat],
        initialRetreat: CloudRetreat?,
        onOpenRetreat: @escaping (UUID?) -> Void,
        onSave: @escaping (MacRetreatSubmission) -> Void
    ) {
        self.retreats = retreats
        self.onOpenRetreat = onOpenRetreat
        self.onSave = onSave

        let recreating = initialRetreat.map { !$0.state.isLiveConfiguration } ?? false
        isRecreatingPastRetreat = recreating
        _editingRetreatID = State(initialValue: recreating ? nil : initialRetreat?.id)

        let historicalGroups = initialRetreat?.currentVersion?.blockingGroups ?? []
        let newlyAvailableGroups = baselineGroups.filter { baseline in
            !historicalGroups.contains {
                CloudRetreatGroupVersioning.represents($0, baselineGroup: baseline)
            }
        }
        let sourceGroups = initialRetreat == nil
            ? baselineGroups
            : historicalGroups + newlyAvailableGroups
        _selectableGroups = State(initialValue: sourceGroups)
        _selectedRuleIDs = State(initialValue: Set(
            initialRetreat == nil
                ? sourceGroups.filter(\.isEnabled).map(\.id)
                : historicalGroups.map(\.id)
        ))
        _name = State(initialValue: initialRetreat?.name ?? "NEWS & FEEDS RESET")
        _goal = State(initialValue: initialRetreat?.goal ?? "")

        if let initialRetreat, recreating {
            let start = Calendar.current.startOfDay(for: Date())
            let duration = max(60, initialRetreat.plannedEnd.timeIntervalSince(initialRetreat.plannedStart))
            _startDate = State(initialValue: start)
            _endDate = State(initialValue: start.addingTimeInterval(duration))
        } else {
            _startDate = State(initialValue: initialRetreat?.plannedStart ?? Date())
            _endDate = State(initialValue:
                initialRetreat?.plannedEnd
                    ?? Calendar.current.date(byAdding: .day, value: 30, to: Date())
                    ?? Date()
            )
        }
        let existingPolicy = initialRetreat?.currentVersion?.modificationPolicy
            ?? initialRetreat?.modificationPolicy
            ?? CloudRuleLockdownPreference(severity: "delayed")
        _lockMode = State(initialValue: Self.lockMode(for: existingPolicy))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                retreatNavigator
                header
                if isReviewing { review }
                else { composer }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacBrutalPalette.canvas)
    }

    private var retreatNavigator: some View {
        HStack(spacing: 12) {
            MacFieldLabel("OPEN RETREAT")
            Menu {
                Button("NEW RETREAT") { onOpenRetreat(nil) }
                if !retreats.isEmpty { Divider() }
                ForEach(retreats) { retreat in
                    Button("\(retreat.name.uppercased()) · \(retreat.state.rawValue.uppercased())") {
                        onOpenRetreat(retreat.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(currentRetreatMenuLabel)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.down")
                }
                .font(.system(.caption, design: .default, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(width: 390, height: 38)
                .background(MacBrutalPalette.surface)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)

            Button("NEW RETREAT") { onOpenRetreat(nil) }
                .buttonStyle(MacBrutalButtonStyle())
            Spacer()
            if isRecreatingPastRetreat {
                Text("PAST CONFIGURATION · SAVES AS A NEW RETREAT")
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(headerTitle)
                    .font(.system(size: 34, weight: .semibold, design: .default))
                    .tracking(-0.5)
                Text(isReviewing ? "CONFIRM THE RETREAT BEFORE IT STARTS" : "SELECT BLOCKING GROUPS FOR A TEMPORARY MODE")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(editingRetreatID == nil ? "RETREAT DRAFT" : "VERSIONED RETREAT")
                .font(.system(.caption, design: .default, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
        }
    }

    private var headerTitle: String {
        if isReviewing { return "REVIEW RETREAT" }
        if isRecreatingPastRetreat { return "RECREATE RETREAT" }
        return editingRetreatID == nil ? "CREATE RETREAT" : "EDIT RETREAT"
    }

    private var currentRetreatMenuLabel: String {
        if let id = editingRetreatID,
           let retreat = retreats.first(where: { $0.id == id }) {
            return retreat.name.uppercased()
        }
        if isRecreatingPastRetreat { return "RECREATE · \(name.uppercased())" }
        return "NEW RETREAT"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        MacFieldLabel("RETREAT NAME")
                        TextField("Name your retreat", text: $name).macBrutalTextField()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        MacFieldLabel("PURPOSE")
                        TextField("What should this make room for?", text: $goal, axis: .vertical)
                            .lineLimit(2...4).macBrutalTextField()
                    }
                }
                HStack(spacing: 28) {
                    DatePicker("Starts", selection: $startDate)
                    DatePicker("Ends", selection: $endDate, in: startDate...)
                }
            }

            blockingGroupSelection
            lockSection

            HStack {
                Text("Selected groups are copied into this retreat version, including their schedules and budgets.")
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isEditingLiveRetreat ? "SAVE CHANGES" : "SAVE DRAFT") { save(startImmediately: false) }
                    .buttonStyle(MacBrutalButtonStyle())
                if !isEditingLiveRetreat {
                    Button("REVIEW & START") { isReviewing = true }
                        .buttonStyle(MacBrutalButtonStyle(.primary))
                        .disabled(selectedRuleIDs.isEmpty)
                }
            }
            .padding(.top, 8)
        }
    }

    private var blockingGroupSelection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MacFieldLabel("BLOCKING GROUPS")
                Spacer()
                MacFieldLabel("INHERITED SETTINGS")
                    .frame(width: 270, alignment: .leading)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }

            if selectableGroups.isEmpty {
                Text("Create a Blocking Group on the dashboard first, then include it in a retreat.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(selectableGroups) { rule in
                HStack(spacing: 20) {
                    Toggle(isOn: Binding(
                        get: { selectedRuleIDs.contains(rule.id) },
                        set: { selected in
                            if selected { selectedRuleIDs.insert(rule.id) }
                            else { selectedRuleIDs.remove(rule.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.name.uppercased())
                                .font(.system(.title3, design: .default, weight: .semibold))
                            Text(rule.enforcementMode == "fortressAllowList" ? "FORTRESS ALLOW-LIST" : "BLOCK SELECTED")
                                .font(.system(.caption2, design: .default, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(MacBrutalCheckboxStyle())

                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inheritedSettingsSummary(for: rule))
                            .font(.system(.caption, design: .default, weight: .bold))
                        Text("SCHEDULE + BUDGET")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 270, alignment: .leading)
                }
                .padding(.vertical, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(MacBrutalPalette.rule.opacity(0.55)).frame(height: 1) }
            }
        }
    }

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Text("RETREAT LOCK")
                    .font(.system(.title3, design: .default, weight: .semibold))
                Text("Edits and ending early follow this policy. Inherited group protections still apply.")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                MacFieldLabel("CHANGES AND EARLY ENDING")
                Picker("LOCK", selection: $lockMode) {
                    Text("Wait, then type a passage").tag("PASSAGE OF TIME")
                    Text("Type a passage").tag("PASSAGE ONLY")
                    Text("Repeated confirmations").tag("REPEATED CONFIRMATIONS")
                    Text("No confirmation required").tag("NO CONFIRMATION REQUIRED")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .padding(5)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            }
            .frame(maxWidth: 460, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                MacFieldLabel("RETREAT DURATION")
                Text("\(durationDays) DAYS")
                    .font(.system(.title2, design: .default, weight: .semibold))
                Text("\(startDate.formatted(date: .abbreviated, time: .omitted).uppercased()) → \(endDate.formatted(date: .abbreviated, time: .omitted).uppercased())")
                    .font(.system(.caption2, design: .default, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .overlay {
            Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1)
        }
        .padding(.top, 6)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 34) {
                VStack(alignment: .leading, spacing: 7) {
                    MacFieldLabel("RETREAT")
                    Text(name.uppercased())
                        .font(.system(.title2, design: .default, weight: .semibold))
                    if !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(goal)
                            .font(.system(.caption, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    MacFieldLabel("DURATION")
                    Text("\(durationDays) DAYS")
                        .font(.system(.headline, design: .default, weight: .bold))
                    Text("\(startDate.formatted(date: .abbreviated, time: .omitted).uppercased()) → \(endDate.formatted(date: .abbreviated, time: .omitted).uppercased())")
                        .font(.system(.caption2, design: .default, weight: .medium))
                    Text("LOCK · \(lockMode)")
                        .font(.system(.caption2, design: .default, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                MacFieldLabel("INCLUDED BLOCKING GROUPS")
                Spacer()
                MacFieldLabel("INHERITED SETTINGS")
                    .frame(width: 270, alignment: .leading)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }

            ForEach(selectableGroups.filter { selectedRuleIDs.contains($0.id) }) { rule in
                HStack(spacing: 20) {
                    Text(rule.name.uppercased())
                        .font(.system(.headline, design: .default, weight: .semibold))
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inheritedSettingsSummary(for: rule))
                            .font(.system(.caption, design: .default, weight: .bold))
                        Text("UNCHANGED FROM BLOCKING GROUP")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 270, alignment: .leading)
                }
                .padding(.vertical, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }
            }

            HStack {
                Button("BACK TO EDIT") { isReviewing = false }
                    .buttonStyle(MacBrutalButtonStyle())
                Spacer()
                Button(startDate > Date() ? "SCHEDULE RETREAT" : "START RETREAT") { save(startImmediately: true) }
                    .buttonStyle(MacBrutalButtonStyle(.primary))
                    .disabled(selectedRuleIDs.isEmpty)
            }
        }
    }

    private var isEditingLiveRetreat: Bool {
        retreats.contains { $0.id == editingRetreatID && ($0.state == .active || $0.state == .scheduled) }
    }

    private var durationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 1)
    }

    private func inheritedSettingsSummary(for rule: CloudBlockingGroup) -> String {
        let windows = rule.timeWindow.slots
        let schedule = windows.isEmpty
            ? "NO SCHEDULE"
            : "\(windows.count) \(rule.timeWindow.paintMode == .allow ? "ALLOWANCE" : "BLOCKING") \(windows.count == 1 ? "WINDOW" : "WINDOWS")"
        let budget = rule.usageBudget.dailyLimitMinutes.map { "\($0) MIN/DAY" }
            ?? "NO USAGE BUDGET"
        return "\(schedule) · \(budget)"
    }

    private func save(startImmediately: Bool) {
        onSave(MacRetreatSubmission(
            id: editingRetreatID,
            name: name,
            goal: goal,
            plannedStart: startDate,
            plannedEnd: endDate,
            blockingGroups: selectableGroups.filter { selectedRuleIDs.contains($0.id) },
            modificationPolicy: lockPolicy,
            startImmediately: startImmediately
        ))
        if startImmediately { isReviewing = false }
    }

    private var lockPolicy: CloudRuleLockdownPreference {
        switch lockMode {
        case "NO CONFIRMATION REQUIRED":
            CloudRuleLockdownPreference(severity: "none")
        case "PASSAGE ONLY":
            CloudRuleLockdownPreference(severity: "passageOnly", unlockDelayDays: 0)
        case "REPEATED CONFIRMATIONS":
            CloudRuleLockdownPreference(severity: "repeatedConfirmations")
        default:
            CloudRuleLockdownPreference(severity: "delayed")
        }
    }

    private static func lockMode(for policy: CloudRuleLockdownPreference) -> String {
        switch policy.severity {
        case "passageOnly": "PASSAGE ONLY"
        case "repeatedConfirmations": "REPEATED CONFIRMATIONS"
        default: "PASSAGE OF TIME"
        }
    }
}

private struct MacFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .default, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

struct MacSchedulePaintGestureLayer: NSViewRepresentable {
    let onChange: (AllowanceScheduleCell, Bool) -> Void

    func makeNSView(context: Context) -> PaintTrackingView {
        let view = PaintTrackingView()
        view.onChange = onChange
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(
            "Allowance schedule grid. Drag to paint. Right-click or right-drag to remove."
        )
        return view
    }

    func updateNSView(_ nsView: PaintTrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class PaintTrackingView: NSView {
        var onChange: ((AllowanceScheduleCell, Bool) -> Void)?
        private var lastPoint: CGPoint?
        private var touchedCells: Set<AllowanceScheduleCell> = []

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            beginStroke(with: event, isAllowed: true)
        }

        override func mouseDragged(with event: NSEvent) {
            continueStroke(with: event, isAllowed: true)
        }

        override func mouseUp(with event: NSEvent) {
            continueStroke(with: event, isAllowed: true)
            endStroke()
        }

        override func rightMouseDown(with event: NSEvent) {
            beginStroke(with: event, isAllowed: false)
        }

        override func rightMouseDragged(with event: NSEvent) {
            continueStroke(with: event, isAllowed: false)
        }

        override func rightMouseUp(with event: NSEvent) {
            continueStroke(with: event, isAllowed: false)
            endStroke()
        }

        private func beginStroke(with event: NSEvent, isAllowed: Bool) {
            lastPoint = nil
            touchedCells.removeAll(keepingCapacity: true)
            continueStroke(with: event, isAllowed: isAllowed)
        }

        private func continueStroke(with event: NSEvent, isAllowed: Bool) {
            let appKitPoint = convert(event.locationInWindow, from: nil)
            // AppKit's event coordinates originate at the lower-left while the
            // schedule geometry is expressed from the visual top-left.
            let currentPoint = CGPoint(
                x: appKitPoint.x,
                y: AllowanceScheduleGridGeometry.topDownY(
                    forAppKitY: Double(appKitPoint.y),
                    height: Double(bounds.height)
                )
            )
            let startPoint = lastPoint ?? currentPoint
            let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)
            let steps = max(1, Int(ceil(distance / 10)))

            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: startPoint.x + (currentPoint.x - startPoint.x) * progress,
                    y: startPoint.y + (currentPoint.y - startPoint.y) * progress
                )
                guard let cell = AllowanceScheduleGridGeometry.cell(
                    atX: Double(point.x),
                    y: Double(point.y)
                ), touchedCells.insert(cell).inserted else {
                    continue
                }
                onChange?(cell, isAllowed)
            }
            lastPoint = currentPoint
        }

        private func endStroke() {
            lastPoint = nil
            touchedCells.removeAll(keepingCapacity: true)
        }
    }
}

struct MacRetreatHistoryView: View {
    let retreats: [CloudRetreat]
    let onEnd: (UUID, Bool) -> Void
    let onOpen: (CloudRetreat) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("RETREAT HISTORY")
                    .font(.system(size: 34, weight: .semibold, design: .default))
                    .tracking(-0.5)
                Text("Review past retreats and recreate the configuration that worked for you.")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)

                if retreats.isEmpty {
                    Text("Your retreat history will appear here. Each version keeps its configuration for next time.")
                        .font(.system(.title3, design: .default, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(retreats) { retreat in
                        retreatRow(retreat)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MacBrutalPalette.canvas)
    }

    private func retreatRow(_ retreat: CloudRetreat) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(retreat.name.uppercased())
                    .font(.system(.title2, design: .default, weight: .semibold))
                if !retreat.goal.isEmpty {
                    Text(retreat.goal)
                        .font(.system(.caption, design: .default))
                        .foregroundStyle(.secondary)
                }
                Text("VERSION \(retreat.currentVersionNumber)  •  \(retreat.currentVersion?.blockingGroups.count ?? 0) BLOCKING GROUPS")
                    .font(.system(.caption2, design: .default, weight: .bold))
            }
            Spacer()
            Text(HoldfastPresentation.state(retreat.state))
                .font(.system(.caption, design: .default, weight: .semibold))
            Button(retreat.state.isLiveConfiguration ? "OPEN / EDIT" : "RECREATE") {
                onOpen(retreat)
            }
            .buttonStyle(MacBrutalButtonStyle())
            if retreat.state == .active {
                Button("END EARLY") { onEnd(retreat.id, true) }
                    .buttonStyle(MacBrutalButtonStyle(.danger))
            }
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 1)
        }
    }
}

struct MacSettingsView: View {
    @AppStorage(MacInterfaceTheme.storageKey) private var storedTheme = MacInterfaceTheme.light.rawValue
    @AppStorage(MacHighlightColor.storageKey) private var storedHighlight = MacHighlightColor.defaultValue.rawValue
    @State private var diagnosticModeEnabled = DesktopDiagnosticTrace.isEnabled
    @State private var diagnosticStatus: String?
    @State private var confirmClearTrace = false

    private let columns = [
        GridItem(.adaptive(minimum: 220), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                appearance
                diagnostics
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MacBrutalPalette.canvas)
        .confirmationDialog("Clear the diagnostic trace?", isPresented: $confirmClearTrace) {
            Button("Clear trace", role: .destructive) { clearDiagnosticTrace() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Existing diagnostic events will be removed. Export a copy first if you want to keep them.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETTINGS")
                .font(.system(size: 34, weight: .semibold, design: .default))
                .tracking(-0.5)
            Text("Personalize Holdfast and get help with device issues. These settings do not change your blocking policies.")
                .font(.system(.caption, design: .default, weight: .medium))
                .foregroundStyle(.secondary)
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
                .padding(.top, 16)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("DIAGNOSTICS")
                .font(.system(.title2, design: .default, weight: .semibold))

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("RECORD DEBUG TRACE", isOn: $diagnosticModeEnabled)
                        .toggleStyle(.switch)
                        .font(.system(.callout, design: .default, weight: .semibold))
                        .onChange(of: diagnosticModeEnabled) { _, enabled in
                            DesktopDiagnosticTrace.setEnabled(enabled)
                            diagnosticStatus = enabled
                                ? "TRACE ACTIVE — NEW ACTIVITY IS BEING RECORDED."
                                : "TRACE PAUSED — EXISTING EVENTS ARE RETAINED."
                        }
                    Text("Keep a limited technical timeline to help diagnose app and web-filter issues.")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Does not record websites, URLs, page content, network payloads or app identities.")
                        .font(.system(.caption2, design: .default, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 660, alignment: .leading)

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 10) {
                    Button("EXPORT TRACE…") { exportDiagnosticTrace() }
                        .buttonStyle(MacBrutalButtonStyle(.primary))
                    Button("Clear trace") { confirmClearTrace = true }
                        .buttonStyle(MacBrutalButtonStyle())
                }
            }

            if let diagnosticStatus {
                Text(diagnosticStatus)
                    .font(.system(.caption, design: .default, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }

    private func exportDiagnosticTrace() {
        DesktopDiagnosticTrace.record(
            component: "diagnostics",
            event: "trace_export_requested"
        )
        let panel = NSSavePanel()
        panel.title = "Export Holdfast Debug Trace"
        panel.nameFieldStringValue = "Holdfast-debug-trace-\(Self.exportTimestamp()).jsonl"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            diagnosticStatus = "EXPORT CANCELLED."
            return
        }
        do {
            let data = try DesktopDiagnosticTrace.exportedData()
            try data.write(to: url, options: [.atomic])
            diagnosticStatus = "EXPORTED \(data.count) BYTES TO \(url.lastPathComponent)."
        } catch {
            diagnosticStatus = "EXPORT FAILED — \(error.localizedDescription.uppercased())"
        }
    }

    private func clearDiagnosticTrace() {
        do {
            try DesktopDiagnosticTrace.clear()
            diagnosticStatus = "TRACE CLEARED."
        } catch {
            diagnosticStatus = "CLEAR FAILED — \(error.localizedDescription.uppercased())"
        }
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("APPEARANCE")
                .font(.system(.title2, design: .default, weight: .semibold))

            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    MacFieldLabel("COLOR MODE")
                    MacThemeSwitch()
                        .frame(width: 280)
                }

                Rectangle().fill(MacBrutalPalette.rule).frame(width: 1, height: 80)

                VStack(alignment: .leading, spacing: 10) {
                    MacFieldLabel("HIGHLIGHT COLOR")
                    Text("Your accent follows you through the app and its icon. The icon also follows light or dark mode.")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(MacHighlightColor.allCases) { highlight in
                    Button {
                        storedHighlight = highlight.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(highlight.color)
                                .frame(width: 34, height: 34)
                                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                            Text(highlight.label.capitalized)
                                .font(.system(.callout, design: .default, weight: .bold))
                            Spacer()
                            Image(systemName: storedHighlight == highlight.rawValue ? "checkmark" : "minus").opacity(storedHighlight == highlight.rawValue ? 1 : 0)
                                .font(.system(.caption2, design: .default, weight: .semibold))
                        }
                        .padding(12)
                        .foregroundStyle(Color.primary)
                        .background(MacBrutalPalette.surface)
                        .overlay {
                            Rectangle().stroke(
                                storedHighlight == highlight.rawValue ? highlight.color : MacBrutalPalette.rule,
                                lineWidth: storedHighlight == highlight.rawValue ? 3 : 1
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }

}
