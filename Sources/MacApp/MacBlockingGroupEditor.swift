import SwiftUI

struct MacBlockingGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var group: CloudBlockingGroup
    @State private var allowanceCells: Set<AllowanceScheduleCell>
    @State private var schedulePaintMode: CloudTimeWindowPaintMode
    @State private var isPaintingSchedule = false
    @ObservedObject var model: MacAppModel
    @State private var isShowingPause = false
    @State private var isShowingUnlock = false
    let isNew: Bool
    let activityGroups: [CloudActivityGroup]
    let onSave: (CloudBlockingGroup) -> Bool

    private let severityNames = ["appDefault", "none", "passageOnly", "delayed", "repeatedConfirmations"]
    private let days: [(value: Int, label: String)] = [
        (2, "MON"), (3, "TUE"), (4, "WED"), (5, "THU"), (6, "FRI"), (7, "SAT"), (1, "SUN")
    ]
    private let slotCount = AllowanceSchedulePainterCodec.slotCount

    init(
        initialGroup: CloudBlockingGroup,
        isNew: Bool,
        activityGroups: [CloudActivityGroup],
        model: MacAppModel,
        onSave: @escaping (CloudBlockingGroup) -> Bool
    ) {
        self.model = model
        var draft = initialGroup.owningTargets(from: activityGroups, containerPolicy: model.baseline.modificationPolicy)
        // Freeze the legacy shared length once so changing edit protection
        // cannot silently change the temporary-access passage (or vice versa).
        if draft.modificationPolicy.temporaryAccessPassageWordCount == nil {
            draft.modificationPolicy.temporaryAccessPassageWordCount = model.ruleEditPolicy(draft.id)?.effectiveTemporaryAccessPassageWordCount
                ?? draft.modificationPolicy.effectiveTemporaryAccessPassageWordCount
        }
        _group = State(initialValue: draft)
        _allowanceCells = State(initialValue: AllowanceSchedulePainterCodec.cells(
            from: initialGroup.timeWindow.slots
        ))
        _schedulePaintMode = State(initialValue: initialGroup.timeWindow.paintMode)
        self.isNew = isNew
        self.activityGroups = activityGroups
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPaintingSchedule {
                    schedulePainter
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            if let end = model.lockdownExpirations[group.id] {
                                LockdownStatusBadge(endsAt: end)
                            }
                            if let expiry = model.temporaryAllowanceExpirations[group.id] {
                                TemporaryAllowanceStatusView(expiresAt: expiry)
                            }
                            BlockingSchedulePreviewView(
                                plan: CloudTimeWindowPlan(paintMode: schedulePaintMode, slots: AllowanceSchedulePainterCodec.windows(from: allowanceCells)),
                                isEnabled: group.isEnabled,
                                hasUsageLimit: group.usageBudget.dailyLimitMinutes != nil || group.usageBudget.weeklyLimitMinutes != nil
                            )
                            if !isNew {
                                Button("Unlock changes / view policy") { isShowingUnlock = true }
                                    .buttonStyle(MacBrutalButtonStyle(.primary))
                            }
                            identitySection
                            MacBlockingTargetsEditor(targets: Binding(get: { group.targets ?? CloudBlockingTargets() }, set: { group.targets = $0 }))
                            scheduleAndBudgetSection
                            temporaryAccessSection
                            temporaryAccessPolicySection
                            securitySection
                        }
                        .padding(36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .safeAreaInset(edge: .bottom) { actionBar }
                }
            }
            .navigationTitle("")
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 720, idealHeight: 860)
        .macBrutalSheet()
        .sheet(isPresented: $isShowingUnlock) {
            MacRuleEditUnlockSheet(model: model, ruleID: group.id)
        }
        .alert("Group changes", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(model.errorMessage ?? "Unable to save changes.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "NEW BLOCKING GROUP" : "EDIT BLOCKING GROUP")
                .font(.system(size: 32, weight: .semibold, design: .default))
                .tracking(-0.5)
            Text("Choose what to block, when to allow access, and how changes are protected.")
                .font(.system(.caption, design: .default, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
        }
    }

    private var identitySection: some View {
        editorSection("IDENTITY & BEHAVIOR", subtitle: "Name this group and choose how it treats the selected targets.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    editorLabel("BLOCKING GROUP NAME")
                    TextField("BLOCKING GROUP NAME", text: $group.name)
                        .macBrutalTextField()
                }
                HStack(spacing: 22) {
                    Toggle("ENABLED", isOn: $group.isEnabled)
                        .toggleStyle(MacBrutalCheckboxStyle())
                    Spacer()
                    editorLabel("ENFORCEMENT")
                    Picker("ENFORCEMENT", selection: $group.enforcementMode) {
                        Text("Block selected apps & sites").tag("blockList")
                        Text("Allow only selected apps & sites").tag("fortressAllowList")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                    .padding(4)
                    .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                }
                .font(.system(.caption, design: .default, weight: .bold))
            }
        }
    }

    private var scheduleAndBudgetSection: some View {
        editorSection("ALLOWANCE & USAGE", subtitle: "Paint allowance windows, then optionally cap usage within them.") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    editorLabel("CURRENT SCHEDULE")
                    Text(scheduleTitle)
                        .font(.system(.title3, design: .default, weight: .semibold))
                    Text(scheduleDetail)
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("EDIT SCHEDULE") { isPaintingSchedule = true }
                        .buttonStyle(MacBrutalButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(MacBrutalPalette.rule).frame(width: 1, height: 150)

                VStack(alignment: .leading, spacing: 13) {
                    editorLabel("USAGE BUDGET")
                    Toggle("DAILY MAXIMUM", isOn: dailyBudgetEnabled)
                        .toggleStyle(MacBrutalCheckboxStyle())
                    if group.usageBudget.dailyLimitMinutes != nil {
                        Stepper("\(dailyBudgetMinutes.wrappedValue) MINUTES / DAY", value: dailyBudgetMinutes, in: 1...1_440)
                    }
                    Toggle("WEEKLY MAXIMUM", isOn: weeklyBudgetEnabled)
                        .toggleStyle(MacBrutalCheckboxStyle())
                    if group.usageBudget.weeklyLimitMinutes != nil {
                        Stepper("\(weeklyBudgetMinutes.wrappedValue) MINUTES / WEEK", value: weeklyBudgetMinutes, in: 1...10_080)
                    }
                }
                .font(.system(.caption, design: .default, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var schedulePainter: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TIME WINDOW")
                        .font(.system(size: 38, weight: .semibold, design: .default))
                        .tracking(-1.5)
                    Text(group.name.uppercased())
                        .font(.system(.caption, design: .default, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                paintModeToggle
                scheduleColorKey(color: MacBrutalPalette.scheduleSignal, label: selectedScheduleMeaning)
                scheduleColorKey(color: MacBrutalPalette.surface, label: unselectedScheduleMeaning)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(MacBrutalPalette.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 2) }

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 14) {
                    scheduleGrid
                    Text("LEFT-DRAG PAINTS \(selectedScheduleMeaning)  •  RIGHT-CLICK OR RIGHT-DRAG UNPAINTS  •  30-MINUTE INCREMENTS")
                        .font(.system(.caption, design: .default, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .frame(
                            width: AllowanceScheduleGridGeometry.columnWidth * Double(days.count) + 78,
                            alignment: .leading
                        )
                        .overlay(alignment: .top) {
                            Rectangle().fill(MacBrutalPalette.rule).frame(height: 1)
                        }
                }
                .padding(28)
            }
            .background(MacBrutalPalette.canvas)

            HStack(spacing: 10) {
                Text("SCHEDULE IS SAVED WITH THIS BLOCKING GROUP")
                    .font(.system(.caption2, design: .default, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("PAINT EVENINGS") { paintEvenings() }
                    .buttonStyle(MacBrutalButtonStyle())
                Button("CLEAR ALL") { allowanceCells.removeAll() }
                    .buttonStyle(MacBrutalButtonStyle(.danger))
                Button("DONE") { isPaintingSchedule = false }
                    .buttonStyle(MacBrutalButtonStyle(.primary))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 15)
            .background(MacBrutalPalette.canvas)
            .overlay(alignment: .top) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }
        }
    }

    private var scheduleGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 78, height: 42)
                ForEach(days, id: \.value) { day in
                    Text(day.label)
                        .font(.system(.caption, design: .default, weight: .bold))
                        .frame(
                            width: AllowanceScheduleGridGeometry.columnWidth,
                            height: 42
                        )
                        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 0.5) }
                }
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<slotCount, id: \.self) { slot in
                        Text(
                            AllowanceScheduleGridGeometry.showsTimeLabel(forSlot: slot)
                                ? timeLabel(slot * AllowanceSchedulePainterCodec.slotMinutes)
                                : ""
                        )
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .padding(.trailing, 8)
                        .frame(
                            width: 78,
                            height: AllowanceScheduleGridGeometry.rowHeight,
                            alignment: .trailing
                        )
                    }
                }

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<slotCount, id: \.self) { slot in
                            HStack(spacing: 0) {
                                ForEach(days, id: \.value) { day in
                                    let cell = AllowanceScheduleCell(weekday: day.value, slot: slot)
                                    Rectangle()
                                        .fill(allowanceCells.contains(cell) ? MacBrutalPalette.scheduleSignal : MacBrutalPalette.surface)
                                        .frame(
                                            width: AllowanceScheduleGridGeometry.columnWidth,
                                            height: AllowanceScheduleGridGeometry.rowHeight
                                        )
                                        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 0.5) }
                                }
                            }
                        }
                    }

                    MacSchedulePaintGestureLayer { cell, isAllowed in
                        if isAllowed { allowanceCells.insert(cell) }
                        else { allowanceCells.remove(cell) }
                    }
                }
                .frame(
                    width: AllowanceScheduleGridGeometry.columnWidth * Double(days.count),
                    height: AllowanceScheduleGridGeometry.rowHeight * Double(slotCount)
                )
            }
        }
    }

    private func scheduleColorKey(color: Color, label: String) -> some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
            Text(label)
                .font(.system(.caption, design: .default, weight: .bold))
        }
    }

    private var paintModeToggle: some View {
        HStack(spacing: 0) {
            paintModeButton(.allow, label: "ALLOWED")
            paintModeButton(.block, label: "DISALLOWED")
        }
    }

    private func paintModeButton(_ mode: CloudTimeWindowPaintMode, label: String) -> some View {
        Button {
            switchPaintMode(to: mode)
        } label: {
            Text(label)
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(schedulePaintMode == mode ? Color.black : Color.primary)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(schedulePaintMode == mode ? MacBrutalPalette.signal : MacBrutalPalette.surface)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func switchPaintMode(to mode: CloudTimeWindowPaintMode) {
        guard mode != schedulePaintMode else { return }
        allowanceCells = AllowanceSchedulePainterCodec.cells(
            preservingSchedule: allowanceCells,
            from: schedulePaintMode,
            to: mode
        )
        schedulePaintMode = mode
    }

    private var selectedScheduleMeaning: String {
        schedulePaintMode == .allow ? "ALLOWED" : "DISALLOWED"
    }

    private var unselectedScheduleMeaning: String {
        schedulePaintMode == .allow ? "DISALLOWED" : "ALLOWED"
    }

    private func paintEvenings() {
        let start = 18 * 60 / AllowanceSchedulePainterCodec.slotMinutes
        let end = 22 * 60 / AllowanceSchedulePainterCodec.slotMinutes
        for day in days.map(\.value) {
            for slot in start..<end {
                allowanceCells.insert(AllowanceScheduleCell(weekday: day, slot: slot))
            }
        }
    }

    private func timeLabel(_ minutes: Int) -> String {
        let hour24 = minutes / 60
        let minute = minutes % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, hour24 < 12 ? "AM" : "PM")
    }

    /// Present only for a saved, enabled group: a pause changes enforcement
    /// rather than the draft, and an unsaved group is not enforcing anything.
    @ViewBuilder
    private var temporaryAccessSection: some View {
        if !isNew, group.isEnabled {
            editorSection(
                "TEMPORARY ACCESS",
                subtitle: "Pause this group for a set time. Blocking resumes automatically, even if Holdfast is closed."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if let pause = model.temporaryPause(for: group.id) {
                        HStack(spacing: 12) {
                            editorLabel("PAUSED UNTIL")
                            Text(pause.expiresAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(.body, design: .default, weight: .semibold))
                            Spacer()
                            Button("RESUME NOW") { model.cancelTemporaryPause(for: group.id) }
                                .buttonStyle(MacBrutalButtonStyle())
                        }
                        Text("\(pause.totalMinutesGranted) MINUTES USED THIS SESSION · \(pause.grantCount) PASSAGE(S) ACCEPTED")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if !model.allowsTemporaryPause(for: group.id) {
                        Text(TemporaryAccessExplanation.denied(
                            draft: group,
                            saved: model.baseline.blockingGroups.first { $0.id == group.id },
                            activities: model.activityGroups,
                            containerPolicy: model.baseline.modificationPolicy
                        ))
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("REVIEW CHANGE PROTECTION") { isShowingUnlock = true }
                            .buttonStyle(MacBrutalButtonStyle())
                    } else if model.availablePauseDurations(for: group.id).isEmpty {
                        Text("THE SESSION MAXIMUM OF \(model.maximumPauseHours(for: group.id)) HOUR(S) IS SPENT. IT RESETS AFTER THE CURRENT PAUSE EXPIRES.")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(model.temporaryPause(for: group.id) == nil ? "DISABLE TEMPORARILY…" : "EXTEND PAUSE…") {
                            isShowingPause = true
                        }
                        .buttonStyle(MacBrutalButtonStyle(.danger))
                        Text("Requires a \(model.pausePassageWordCount(for: group.id))-word passage. " + model.pausePassageExplanation(for: group.id))
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $isShowingPause) {
                MacTemporaryPauseSheet(model: model, ruleID: group.id, ruleName: group.name)
            }
        }
    }

    private var securitySection: some View {
        editorSection("CHANGE PROTECTION", subtitle: "Protects permanent edits, disabling, and deletion. Equivalent or stronger restrictions save without unlocking.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    editorLabel("LOCK POLICY")
                    Spacer()
                    Picker("LOCK POLICY", selection: $group.modificationPolicy.severity) {
                        ForEach(severityNames, id: \.self) { severity in
                            Text(HoldfastPresentation.policy(severity)).tag(severity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .padding(4)
                    .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                }
                if group.modificationPolicy.severity == "delayed" || group.modificationPolicy.severity == "repeatedConfirmations" {
                    Stepper("UNLOCK WAIT: \(group.modificationPolicy.unlockDelayDays) DAYS", value: $group.modificationPolicy.unlockDelayDays, in: 0...365)
                }
                if group.modificationPolicy.severity != "none" && group.modificationPolicy.severity != "appDefault" {
                    Stepper("CONFIRMATION PASSAGE: \(group.modificationPolicy.passageWordCount) WORDS", value: $group.modificationPolicy.passageWordCount, in: 20...300)
                    Stepper("EDIT WINDOW: \(group.modificationPolicy.editWindowHours) HOURS", value: $group.modificationPolicy.editWindowHours, in: 1...72)
                }
                if group.modificationPolicy.severity == "repeatedConfirmations" {
                    Stepper("CONFIRMATION WINDOW: \(group.modificationPolicy.confirmationWindowHours) HOURS", value: $group.modificationPolicy.confirmationWindowHours, in: 1...48)
                }
                if let warning = policyConflictWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("change-policy-warning")
                }
            }
            .font(.system(.caption, design: .default, weight: .medium))
        }
    }

    private var temporaryAccessPolicySection: some View {
        editorSection("TEMPORARY ACCESS POLICY", subtitle: "Controls timed exceptions only. It does not unlock editing; blocking resumes automatically.") {
            Toggle("ALLOW TEMPORARY ACCESS", isOn: $group.modificationPolicy.allowsTimeExtensions)
                .toggleStyle(MacBrutalCheckboxStyle())
            if group.modificationPolicy.allowsTimeExtensions {
                Stepper("ACCESS PASSAGE: \(group.modificationPolicy.effectiveTemporaryAccessPassageWordCount) WORDS", value: Binding(
                    get: { group.modificationPolicy.effectiveTemporaryAccessPassageWordCount },
                    set: { group.modificationPolicy.temporaryAccessPassageWordCount = $0 }
                ), in: 20...300)
                Stepper("MAXIMUM TEMPORARY ACCESS: \(group.modificationPolicy.maximumTimeExtensionHours) HOURS", value: $group.modificationPolicy.maximumTimeExtensionHours, in: 1...8)
                TemporaryAllowanceBackoffEditor(resetDays: $group.modificationPolicy.temporaryAllowanceResetDays)
                Text("Custom access passages and backoff are completed in Holdfast, including for blocked websites.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var policyConflictWarning: String? {
        let effective = CloudRuleLockdownPreference.restrictiveMaximum([model.baseline.modificationPolicy, group.modificationPolicy])
        return TemporaryAccessPolicyComparison.warning(changePolicy: effective, temporaryPolicy: effective)
    }

    private var actionBar: some View {
        HStack {
            Text("BASELINE BLOCKING GROUP · INDEPENDENT TARGETS")
                .font(.system(.caption2, design: .default, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(MacBrutalButtonStyle())
            Button("SAVE BLOCKING GROUP") { save() }
                .buttonStyle(MacBrutalButtonStyle(.primary))
                .disabled(!canSave)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
        .background(MacBrutalPalette.canvas)
        .overlay(alignment: .top) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }
    }

    private func editorSection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(.title3, design: .default, weight: .semibold))
                Text(subtitle)
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacBrutalPalette.surface)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .default, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private var canSave: Bool {
        !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && group.targets != nil
    }

    private func toggle(_ id: UUID) {
        if group.activityGroupIDs.contains(id) {
            group.activityGroupIDs.removeAll { $0 == id }
        } else {
            group.activityGroupIDs.append(id)
        }
    }

    private var linkedAvailableCount: Int {
        activityGroups.filter { group.activityGroupIDs.contains($0.id) }.count
    }

    private var missingLinkedCount: Int {
        let availableIDs = Set(activityGroups.map(\.id))
        return group.activityGroupIDs.filter { !availableIDs.contains($0) }.count
    }

    private func activitySummary(_ activity: CloudActivityGroup) -> String {
        let portableApps = activity.macApplicationIdentifiers.count
            + activity.windowsExecutablePaths.count
            + activity.windowsPublisherRules.count
        return "\(activity.domains.count) DOMAINS · \(activity.websiteCategories.count) CATEGORIES · \(portableApps) APP TARGETS · \(activity.deviceLocalSelectionCount) DEVICE-LOCAL"
    }

    private var scheduleTitle: String {
        schedulePaintMode == .allow ? "ALLOWANCE WINDOWS" : "BLOCKING WINDOWS"
    }

    private var scheduleDetail: String {
        let windows = AllowanceSchedulePainterCodec.windows(from: allowanceCells)
        let hours = Double(allowanceCells.count) * Double(AllowanceSchedulePainterCodec.slotMinutes) / 60.0
        return "\(windows.count) WINDOW\(windows.count == 1 ? "" : "S") · \(hours.formatted(.number.precision(.fractionLength(0...1)))) HOURS / WEEK"
    }

    private var dailyBudgetEnabled: Binding<Bool> {
        Binding(
            get: { group.usageBudget.dailyLimitMinutes != nil },
            set: { enabled in group.usageBudget.dailyLimitMinutes = enabled ? (group.usageBudget.dailyLimitMinutes ?? 30) : nil }
        )
    }

    private var dailyBudgetMinutes: Binding<Int> {
        Binding(
            get: { group.usageBudget.dailyLimitMinutes ?? 30 },
            set: { group.usageBudget.dailyLimitMinutes = $0 }
        )
    }

    private var weeklyBudgetEnabled: Binding<Bool> {
        Binding(
            get: { group.usageBudget.weeklyLimitMinutes != nil },
            set: { enabled in group.usageBudget.weeklyLimitMinutes = enabled ? (group.usageBudget.weeklyLimitMinutes ?? 180) : nil }
        )
    }

    private var weeklyBudgetMinutes: Binding<Int> {
        Binding(
            get: { group.usageBudget.weeklyLimitMinutes ?? 180 },
            set: { group.usageBudget.weeklyLimitMinutes = $0 }
        )
    }

    private func save() {
        group.timeWindow.paintMode = schedulePaintMode
        group.timeWindow.slots = AllowanceSchedulePainterCodec.windows(from: allowanceCells)
        if onSave(group) { dismiss() }
    }

    private func severityLabel(_ value: String) -> String {
        switch value {
        case "appDefault": "App default"
        case "none": "No edit lock"
        case "passageOnly": "Passage only"
        case "delayed": "Delayed unlock"
        default: "Repeated confirmations"
        }
    }
}
