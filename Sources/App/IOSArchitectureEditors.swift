import FamilyControls
import SwiftUI

struct IOSBlockingGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var group: CloudBlockingGroup
    @State private var showSchedule = false
    @State private var confirmDelete = false
    @State private var pauseDuration = TemporaryAccessDuration.tenMinutes
    @State private var showPausePassage = false
    @State private var pauseIntent: BypassEvent.Intent?
    @State private var showUnlock = false
    @State private var blockingSelection = FamilyActivitySelection()

    init(initialGroup: CloudBlockingGroup) {
        _group = State(initialValue: initialGroup)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    editorHeader("BLOCKING GROUP", "Choose what to block, when to allow access, and how changes are protected.")
                    IOSBrutalCard {
                        if let end = model.lockdownExpirations[group.id] {
                            LockdownStatusBadge(endsAt: end)
                        }
                        if let pause = activePause {
                            TemporaryAllowanceStatusView(expiresAt: pause.expiresAt)
                        }
                        BlockingSchedulePreviewView(
                            plan: group.timeWindow,
                            isEnabled: group.isEnabled,
                            hasUsageLimit: group.usageBudget.dailyLimitMinutes != nil || group.usageBudget.weeklyLimitMinutes != nil
                        )
                    }
                    if compiledRule != nil {
                        IOSBrutalCard {
                            fieldLabel("CHANGE PROTECTION")
                            Text(model.isRuleEditingLocked(group.id)
                                ? "Changes require this group's saved unlock policy, including inherited protections."
                                : "This group is currently open for changes.")
                                .font(.system(.caption, design: .default))
                                .foregroundStyle(.secondary)
                            Button(model.isRuleEditingLocked(group.id) ? "Unlock changes" : "View change policy") { showUnlock = true }
                                .buttonStyle(IOSBrutalButtonStyle())
                                .accessibilityIdentifier("blocking-group-unlock")
                            Text("Unlocking allows edits; it does not stop blocking. Use temporary access below for a timed exception, when allowed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    IOSBrutalCard {
                        fieldLabel("NAME")
                        TextField("Blocking Group name", text: $group.name).iosBrutalField()
                        Toggle("ENABLED", isOn: $group.isEnabled)
                            .font(.system(.callout, design: .default, weight: .bold))
                        Picker("ENFORCEMENT", selection: $group.enforcementMode) {
                            Text("Block selected apps & sites").tag("blockList")
                            Text("Allow only selected apps & sites").tag("fortressAllowList")
                        }
                    }
                    IOSBlockingTargetsEditor(targets: Binding(get: { group.targets ?? CloudBlockingTargets() }, set: { group.targets = $0 }), selection: $blockingSelection)
                    IOSBrutalCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                fieldLabel("ALLOWANCE SCHEDULE")
                                Text(scheduleSummary)
                                    .font(.system(.callout, design: .default, weight: .semibold))
                            }
                            Spacer()
                            Button("EDIT") { showSchedule = true }
                                .buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
                        }
                        Divider()
                        Toggle("Daily usage limit", isOn: dailyBudgetEnabled)
                        if group.usageBudget.dailyLimitMinutes != nil {
                            Stepper("\(dailyBudgetMinutes.wrappedValue) MINUTES / DAY", value: dailyBudgetMinutes, in: 1...1_440)
                        }
                        Toggle("Weekly usage limit", isOn: weeklyBudgetEnabled)
                        if group.usageBudget.weeklyLimitMinutes != nil {
                            Stepper("\(weeklyBudgetMinutes.wrappedValue) MINUTES / WEEK", value: weeklyBudgetMinutes, in: 1...10_080)
                        }
                    }
                    temporaryPauseCard
                    IOSBrutalCard { IOSTemporaryAccessPolicyEditor(policy: $group.modificationPolicy) }
                    IOSBrutalCard { IOSPolicyEditor(policy: $group.modificationPolicy) }
                    if model.baseline.blockingGroups.contains(where: { $0.id == group.id }) {
                        Button("DELETE BLOCKING GROUP") { confirmDelete = true }
                            .buttonStyle(IOSBrutalButtonStyle(emphasis: .danger))
                    }
                }
                .padding(16)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("BLOCKING GROUP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.saveBlockingGroup(group, selection: blockingSelection) { dismiss() }
                    }
                    .disabled(group.targets == nil)
                }
            }
            .iosModelErrorAlert()
            .onAppear {
                group = group.owningTargets(from: model.activityGroups, containerPolicy: model.baseline.modificationPolicy)
                if group.modificationPolicy.temporaryAccessPassageWordCount == nil {
                    group.modificationPolicy.temporaryAccessPassageWordCount = compiledRule.map {
                        $0.lockdownPolicy.temporaryAccessPassageWordCount ?? model.ruleLockdownConfiguration(for: $0).passageWordCount
                    } ?? group.modificationPolicy.effectiveTemporaryAccessPassageWordCount
                }
                blockingSelection = model.selectionForBlockingGroup(group)
            }
            .sheet(isPresented: $showSchedule) {
                IOSAllowanceScheduleEditor(plan: $group.timeWindow)
            }
            .sheet(isPresented: $showPausePassage) {
                PassageEntryView(
                    title: "Disable Temporarily",
                    explanation: pausePassageExplanation,
                    wordCount: model.timeAllowancePassageWordCount(for: group.id),
                    onVerified: { count in
                        if model.grantTimeAllowance(for: group.id, duration: pauseDuration, verifiedWordCount: count, intent: pauseIntent) {
                            pauseIntent = nil
                        }
                    }, onComplete: {}
                )
                .environmentObject(model)
            }
            .sheet(isPresented: $showUnlock) {
                NavigationStack {
                    RuleLockdownView(ruleID: group.id)
                }
                .environmentObject(model)
            }
            .confirmationDialog("Delete this Blocking Group?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    if model.deleteBlockingGroup(group) { dismiss() }
                }
            }
        }
    }

    /// The rule this group compiles to. Temporary access is decided by the
    /// resolved policy, which is the most restrictive of the group's own policy
    /// and the ones it inherits, not by the draft being edited here.
    private var compiledRule: BlockingRule? {
        model.rules.first { $0.id == group.id }
    }

    private var activePause: RuleTimeAllowance? {
        model.activeTimeAllowance(for: group.id)
    }

    @ViewBuilder
    private var temporaryPauseCard: some View {
        // Only a saved, enabled group can be paused: pausing edits enforcement
        // rather than the draft, and an unsaved group is not enforcing anything.
        if let rule = compiledRule, rule.isEnabled {
            IOSBrutalCard {
                fieldLabel("DISABLE TEMPORARILY")
                if let pause = activePause {
                    Text("PAUSED UNTIL \(pause.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(.callout, design: .default, weight: .semibold))
                    Text("\(pause.totalMinutesGranted) MINUTES USED THIS SESSION · \(pause.grantCount) PASSAGE\(pause.grantCount == 1 ? "" : "S") ACCEPTED")
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let end = model.lockdownExpirations[group.id] {
                    LockdownStatusBadge(endsAt: end)
                    Text("End the lockdown before requesting temporary access.").font(.caption)
                } else if !rule.lockdownPolicy.allowsTimeExtensions {
                    Text(TemporaryAccessExplanation.denied(
                        draft: group,
                        saved: model.baseline.blockingGroups.first { $0.id == group.id },
                        activities: model.activityGroups,
                        containerPolicy: model.baseline.modificationPolicy
                    ))
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("REVIEW CHANGE PROTECTION") { showUnlock = true }
                        .buttonStyle(IOSBrutalButtonStyle())
                } else if availablePauseDurations.isEmpty {
                    Text("THE SESSION MAXIMUM OF \(rule.lockdownPolicy.maximumTimeExtensionHours) HOUR(S) IS SPENT. IT RESETS AFTER THE CURRENT PAUSE EXPIRES.")
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("FOR", selection: $pauseDuration) {
                        ForEach(availablePauseDurations) { duration in
                            Text(duration.title.uppercased()).tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                    BypassIntentPicker(selection: $pauseIntent)
                    Text("Requires a \(model.timeAllowancePassageWordCount(for: group.id))-word passage. " + TemporaryAllowanceBackoff.description(resetDays: rule.lockdownPolicy.temporaryAllowanceResetDays))
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button(activePause == nil ? "DISABLE TEMPORARILY" : "EXTEND PAUSE") {
                        showPausePassage = true
                    }
                    .buttonStyle(IOSBrutalButtonStyle(emphasis: .danger))
                    .disabled(pauseIntent == nil)
                }
            }
        }
    }

    private var availablePauseDurations: [TemporaryAccessDuration] {
        model.availableTemporaryAccessDurations(for: group.id)
    }

    private var pausePassageExplanation: String {
        activePause == nil
            ? "Type the passage to stop this Blocking Group enforcing for \(pauseDuration.title). It resumes automatically."
            : "Type the passage to add \(pauseDuration.title) to the current pause. Each pause in a session needs a longer passage than the last."
    }

    private func toggle(_ id: UUID) {
        if group.activityGroupIDs.contains(id) { group.activityGroupIDs.removeAll { $0 == id } }
        else { group.activityGroupIDs.append(id) }
    }

    private var scheduleSummary: String {
        let count = group.timeWindow.effectiveAllowedSlots().count
        return count == 0 ? "BLOCKED ALL DAY" : "\(count) ALLOWANCE WINDOW\(count == 1 ? "" : "S")"
    }

    private var dailyBudgetEnabled: Binding<Bool> {
        Binding(
            get: { group.usageBudget.dailyLimitMinutes != nil },
            set: { group.usageBudget.dailyLimitMinutes = $0 ? 30 : nil }
        )
    }
    private var weeklyBudgetEnabled: Binding<Bool> {
        Binding(
            get: { group.usageBudget.weeklyLimitMinutes != nil },
            set: { group.usageBudget.weeklyLimitMinutes = $0 ? 180 : nil }
        )
    }
    private var dailyBudgetMinutes: Binding<Int> {
        Binding(get: { group.usageBudget.dailyLimitMinutes ?? 30 }, set: { group.usageBudget.dailyLimitMinutes = $0 })
    }
    private var weeklyBudgetMinutes: Binding<Int> {
        Binding(get: { group.usageBudget.weeklyLimitMinutes ?? 180 }, set: { group.usageBudget.weeklyLimitMinutes = $0 })
    }
}

struct IOSRetreatEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    private let initialRetreat: CloudRetreat
    private let isNew: Bool

    @State private var name: String
    @State private var goal: String
    @State private var plannedStart: Date
    @State private var plannedEnd: Date
    @State private var selectableGroups: [CloudBlockingGroup] = []
    @State private var selectedGroupIDs: Set<UUID> = []
    @State private var policy: CloudRuleLockdownPreference
    @State private var showEarlyEndPolicy = false
    @State private var isReviewing = false

    init(initialRetreat: CloudRetreat, isNew: Bool) {
        self.initialRetreat = initialRetreat
        self.isNew = isNew
        _name = State(initialValue: isNew ? "" : initialRetreat.name)
        _goal = State(initialValue: initialRetreat.goal)
        _plannedStart = State(initialValue: isNew ? Date() : initialRetreat.plannedStart)
        _plannedEnd = State(initialValue: isNew ? Date().addingTimeInterval(30 * 86_400) : initialRetreat.plannedEnd)
        var initialPolicy = initialRetreat.modificationPolicy
        initialPolicy.temporaryAccessPassageWordCount = initialPolicy.effectiveTemporaryAccessPassageWordCount
        _policy = State(initialValue: initialPolicy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    editorHeader(isNew ? "CREATE RETREAT" : "EDIT RETREAT", "Make space for something else. Choose groups, dates, and a change policy.")
                    IOSBrutalCard {
                        fieldLabel("RETREAT NAME")
                        TextField("News & Feeds Reset", text: $name).iosBrutalField()
                        fieldLabel("PURPOSE")
                        TextField("What should this make room for?", text: $goal, axis: .vertical).lineLimit(2...4).iosBrutalField()
                        DatePicker("Starts", selection: $plannedStart)
                        DatePicker("Ends", selection: $plannedEnd, in: plannedStart...)
                    }
                    IOSBrutalCard {
                        fieldLabel("BLOCKING GROUPS")
                        Text("Each retreat version keeps the selected groups’ targets, allowance windows, budgets, and protection.")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(.secondary)
                        if selectableGroups.isEmpty {
                            Text("Create a Blocking Group on the dashboard first, then return here to include it.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(selectableGroups) { group in
                            Button { toggle(group.id) } label: {
                                HStack {
                                    Image(systemName: selectedGroupIDs.contains(group.id) ? "checkmark.square.fill" : "square")
                                    Text(group.name)
                                    Spacer()
                                    Text(HoldfastPresentation.targets(group.targets)).font(.caption).foregroundStyle(.secondary)
                                }
                                .font(.system(.callout, design: .default, weight: .bold))
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    IOSBrutalCard { IOSPolicyEditor(policy: $policy, title: "RETREAT LOCK") }
                    IOSBrutalCard { IOSTemporaryAccessPolicyEditor(policy: $policy) }
                    if !isNew, initialRetreat.state == .active {
                        Button("END RETREAT EARLY") {
                            showEarlyEndPolicy = true
                        }
                        .buttonStyle(IOSBrutalButtonStyle(emphasis: .danger))
                    }
                }
                .padding(16)
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("RETREAT")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button(!isNew && initialRetreat.state != .draft ? "SAVE CHANGES" : "SAVE DRAFT") { save(start: false) }
                        .buttonStyle(IOSBrutalButtonStyle())
                    if isNew || initialRetreat.state == .draft {
                        Button("REVIEW & START") { isReviewing = true }
                            .buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
                            .disabled(selectedGroupIDs.isEmpty)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(IOSBrutalPalette.canvas)
                .overlay(alignment: .top) { Rectangle().fill(IOSBrutalPalette.rule).frame(height: 1) }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .iosModelErrorAlert()
            .onAppear(perform: seedSelection)
            .sheet(isPresented: $isReviewing) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(name.isEmpty ? "Retreat" : name).font(.title2.weight(.semibold))
                            if !goal.isEmpty { Text(goal).foregroundStyle(.secondary) }
                            IOSBrutalCard {
                                LabeledContent("Starts", value: plannedStart.formatted(date: .abbreviated, time: .shortened))
                                LabeledContent("Ends", value: plannedEnd.formatted(date: .abbreviated, time: .shortened))
                            }
                            IOSBrutalCard {
                                Text("Included Blocking Groups").font(.headline)
                                ForEach(selectableGroups.filter { selectedGroupIDs.contains($0.id) }) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name).font(.body.weight(.semibold))
                                        Text(HoldfastPresentation.schedule(group.timeWindow)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            IOSBrutalCard {
                                Text("Changes and early ending").font(.headline)
                                Text(HoldfastPresentation.policy(policy.severity))
                                Text("Inherited group protections still apply. Ending early follows the same policy as changing this retreat.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(plannedStart > Date() ? "Schedule retreat" : "Start retreat") {
                                isReviewing = false
                                save(start: true)
                            }.buttonStyle(IOSBrutalButtonStyle(emphasis: .primary))
                                .accessibilityIdentifier("confirm-retreat-start")
                        }.padding(20)
                    }.background(IOSBrutalPalette.canvas)
                        .navigationTitle("Review retreat").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { isReviewing = false } } }
                }
            }
            .sheet(isPresented: $showEarlyEndPolicy) {
                IOSRetreatEarlyEndView(retreatID: initialRetreat.id) {
                    showEarlyEndPolicy = false
                    dismiss()
                }
                .environmentObject(model)
            }
        }
    }

    private func seedSelection() {
        let historicalGroups = isNew
            ? []
            : initialRetreat.currentVersion?.blockingGroups ?? []
        let newlyAvailableGroups = model.baseline.blockingGroups.filter { baseline in
            !historicalGroups.contains {
                CloudRetreatGroupVersioning.represents($0, baselineGroup: baseline)
            }
        }
        selectableGroups = isNew
            ? model.baseline.blockingGroups
            : historicalGroups + newlyAvailableGroups
        selectedGroupIDs = Set(historicalGroups.map(\.id))
    }

    private func toggle(_ id: UUID) {
        if selectedGroupIDs.contains(id) { selectedGroupIDs.remove(id) }
        else { selectedGroupIDs.insert(id) }
    }

    private func save(start: Bool) {
        if model.saveRetreat(
            id: isNew ? nil : initialRetreat.id,
            name: name,
            goal: goal,
            plannedStart: plannedStart,
            plannedEnd: plannedEnd,
            sourceBlockingGroups: selectableGroups.filter {
                selectedGroupIDs.contains($0.id)
            },
            modificationPolicy: policy,
            startImmediately: start
        ) { dismiss() }
    }
}

private struct IOSRetreatEarlyEndView: View {
    let retreatID: UUID
    let onEnded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var passagePurpose: PassagePurpose?
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private enum PassagePurpose: String, Identifiable {
        case start
        case checkpoint
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("RETREAT CHANGE POLICY") {
                    if let retreat {
                        LabeledContent("Retreat", value: retreat.name)
                        Text("Ending this Retreat uses its saved change policy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This Retreat is no longer active.")
                    }
                }
                if let policy { phaseSection(policy: policy) }
            }
            .navigationTitle("End Retreat Early")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Retreat") { dismiss() }
                }
            }
            .iosModelErrorAlert()
            .onAppear { model.refreshRetreatLockdowns() }
            .onReceive(refreshTimer) { _ in model.refreshRetreatLockdowns() }
            .sheet(item: $passagePurpose) { purpose in
                PassageEntryView(
                    title: purpose == .start ? "Start Retreat Change" : "Retreat Confirmation",
                    explanation: purpose == .start
                        ? "Type the passage to begin this Retreat’s saved change process."
                        : "Type the passage before this checkpoint expires, or the change process is cancelled.",
                    wordCount: policy?.passageWordCount ?? 40
                ) {
                    if purpose == .start { model.startRetreatUnlock(retreatID) }
                    else { model.confirmRetreatUnlock(retreatID) }
                }
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
    private func phaseSection(policy: CloudRetreatChangePolicy) -> some View {
        Section("RETREAT CHANGE AUTHORIZATION") {
            if !policy.requiresAuthorization {
                Button("END RETREAT NOW", role: .destructive, action: finish)
            } else {
                switch model.retreatUnlockPhases[retreatID] ?? model.retreatUnlockPhase(for: retreatID) {
                case .idle, .cancelled:
                    Button("Type Passage to Start…") { passagePurpose = .start }
                    Text(policy.unlockDelayDays == 0
                        ? "The change window opens immediately after the passage."
                        : "The earliest change window opens after \(policy.unlockDelayDays) full day(s).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case let .waiting(unlocksAt, nextConfirmationAt):
                    LabeledContent("Earliest end", value: unlocksAt.formatted(date: .abbreviated, time: .shortened))
                    if let nextConfirmationAt {
                        LabeledContent("Next checkpoint", value: nextConfirmationAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Cancel Change Process", role: .destructive) {
                        model.cancelRetreatUnlock(retreatID)
                    }
                case let .confirmationDue(_, deadline, checkpoint, total):
                    Label(
                        "Checkpoint \(checkpoint) of \(total) is due before \(deadline.formatted(date: .abbreviated, time: .shortened)).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Button("Type This Checkpoint…") { passagePurpose = .checkpoint }
                case let .unlocked(editWindowEndsAt):
                    Label(
                        "Change window open until \(editWindowEndsAt.formatted(date: .abbreviated, time: .shortened)).",
                        systemImage: "lock.open"
                    )
                    .foregroundStyle(.green)
                    Button("END RETREAT EARLY", role: .destructive, action: finish)
                }
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

struct IOSPolicyEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var policy: CloudRuleLockdownPreference
    var title = "CHANGE PROTECTION"

    var body: some View {
        // Grouped explicitly: a bare multi-statement body would be flattened
        // into whatever container presents it, losing this editor's own spacing.
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel(title)
            Picker("LOCK POLICY", selection: $policy.severity) {
                Text("App default").tag("appDefault")
                Text(title.contains("RETREAT") ? "No confirmation required" : "NONE").tag("none")
                Text("Type a passage").tag("passageOnly")
                Text("Wait, then type").tag("delayed")
                Text("Repeated confirmations").tag("repeatedConfirmations")
            }
            Text(HoldfastPresentation.policy(policy.severity))
                .font(.subheadline).foregroundStyle(.secondary)
            if title.contains("RETREAT") {
                Text("This policy covers both edits and ending early. Inherited group protections still apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if policy.severity == "delayed" || policy.severity == "repeatedConfirmations" {
                Stepper("UNLOCK WAIT: \(policy.unlockDelayDays) DAYS", value: $policy.unlockDelayDays, in: 0...365)
            }
            if policy.severity != "none" && policy.severity != "appDefault" {
                Stepper("PASSAGE: \(policy.passageWordCount) WORDS", value: $policy.passageWordCount, in: 20...300, step: 10)
                Stepper("EDIT WINDOW: \(policy.editWindowHours) HOURS", value: $policy.editWindowHours, in: 1...72)
            }
            if policy.severity == "repeatedConfirmations" {
                Stepper("CHECKPOINT WINDOW: \(policy.confirmationWindowHours) HOURS", value: $policy.confirmationWindowHours, in: 1...48)
            }
            Text("Equivalent or stronger restrictions can be saved without unlocking. This policy protects permanent edits, disabling, and deletion.")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = model.temporaryAccessPolicyWarning(policy, inheritsBaseline: !title.contains("RETREAT")) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("change-policy-warning")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IOSTemporaryAccessPolicyEditor: View {
    @Binding var policy: CloudRuleLockdownPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("TEMPORARY ACCESS POLICY")
            Text("Timed exceptions only. Does not unlock editing; blocking resumes automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow temporary access", isOn: $policy.allowsTimeExtensions)
            if policy.allowsTimeExtensions {
                Stepper("ACCESS PASSAGE: \(policy.effectiveTemporaryAccessPassageWordCount) WORDS", value: Binding(
                    get: { policy.effectiveTemporaryAccessPassageWordCount },
                    set: { policy.temporaryAccessPassageWordCount = $0 }
                ), in: 20...300, step: 10)
                Stepper("MAXIMUM: \(policy.maximumTimeExtensionHours) HOURS", value: $policy.maximumTimeExtensionHours, in: 1...8)
                TemporaryAllowanceBackoffEditor(resetDays: $policy.temporaryAllowanceResetDays)
            }
        }
    }
}

struct IOSAllowanceScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var plan: CloudTimeWindowPlan
    @State private var cells: Set<AllowanceScheduleCell>
    @State private var editMode = IOSAllowanceEditMode.select

    private let days = [(2, "MON"), (3, "TUE"), (4, "WED"), (5, "THU"), (6, "FRI"), (7, "SAT"), (1, "SUN")]
    private let rowHeight = 24.0
    private let labelWidth = 62.0

    init(plan: Binding<CloudTimeWindowPlan>) {
        _plan = plan
        _cells = State(initialValue: AllowanceSchedulePainterCodec.cells(from: plan.wrappedValue.effectiveAllowedSlots()))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columnWidth = max(28, min(46, (geometry.size.width - 32 - labelWidth) / 7))
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 12) {
                        editingControls(columnWidth: columnWidth)
                        headerRow(columnWidth: columnWidth)
                        HStack(alignment: .top, spacing: 0) {
                            timeLabels
                            paintGrid(columnWidth: columnWidth)
                        }
                        Text("TAP OR SWIPE TO \(editMode.actionLabel) · USE SELECT ALL OR DESELECT ALL FOR THE WHOLE WEEK · 30-MINUTE INCREMENTS")
                            .font(.system(.caption2, design: .default, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth + columnWidth * 7, alignment: .leading)
                    }
                    .padding(16)
                }
            }
            .background(IOSBrutalPalette.canvas)
            .navigationTitle("ALLOWANCE SCHEDULE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("ALLOWANCE SCHEDULE")
                        .font(.system(.caption, design: .default, weight: .bold))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        plan = CloudTimeWindowPlan(
                            id: plan.id,
                            paintMode: .allow,
                            slots: AllowanceSchedulePainterCodec.windows(from: cells)
                        )
                        dismiss()
                    }
                }
            }
        }
    }

    private func editingControls(columnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colored time allows access. Unpainted time stays blocked.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(cells.count / 2)\(cells.count.isMultiple(of: 2) ? "" : ".5") hours allowed per week")
                .font(.caption.weight(.semibold))
            HStack(spacing: 0) {
                editModeButton(.select)
                editModeButton(.deselect)
            }
            HStack(spacing: 10) {
                Button("SELECT ALL") { cells = AllowanceSchedulePainterCodec.allCells }
                    .buttonStyle(IOSBrutalButtonStyle())
                Button("DESELECT ALL") { cells.removeAll() }
                    .buttonStyle(IOSBrutalButtonStyle())
            }
        }
        .frame(width: labelWidth + columnWidth * 7, alignment: .leading)
    }

    private func editModeButton(_ mode: IOSAllowanceEditMode) -> some View {
        Button {
            editMode = mode
        } label: {
            Text(mode.label)
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(editMode == mode ? Color.black : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(editMode == mode ? IOSBrutalPalette.signal : IOSBrutalPalette.surface)
                .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func headerRow(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 40)
            ForEach(days, id: \.0) { day in
                Text(day.1)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .frame(width: columnWidth, height: 40)
                    .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 0.5) }
            }
        }
    }

    private var timeLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<48, id: \.self) { slot in
                Text(slot.isMultiple(of: 2) ? timeLabel(slot * 30) : "")
                    .font(.system(size: 8, weight: .medium, design: .default))
                    .padding(.trailing, 6)
                    .frame(width: labelWidth, height: rowHeight, alignment: .trailing)
            }
        }
    }

    private func paintGrid(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<48, id: \.self) { slot in
                    HStack(spacing: 0) {
                        ForEach(days, id: \.0) { day in
                            let cell = AllowanceScheduleCell(weekday: day.0, slot: slot)
                            Rectangle()
                                .fill(cells.contains(cell) ? IOSBrutalPalette.signal : IOSBrutalPalette.surface)
                                .frame(width: columnWidth, height: rowHeight)
                                .overlay { Rectangle().stroke(IOSBrutalPalette.rule.opacity(slot.isMultiple(of: 2) ? 0.8 : 0.4), lineWidth: slot.isMultiple(of: 2) ? 0.8 : 0.5) }
                        }
                    }
                }
            }
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("allowance-grid"))
                        .onChanged { value in
                            guard let cell = cell(at: value.location, columnWidth: columnWidth) else { return }
                            if editMode == .select { cells.insert(cell) }
                            else { cells.remove(cell) }
                        }
                )
        }
        .coordinateSpace(name: "allowance-grid")
        .frame(width: columnWidth * 7, height: rowHeight * 48)
    }

    private func cell(at point: CGPoint, columnWidth: CGFloat) -> AllowanceScheduleCell? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / columnWidth)
        let slot = Int(point.y / rowHeight)
        guard days.indices.contains(column), 0..<48 ~= slot else { return nil }
        return AllowanceScheduleCell(weekday: days[column].0, slot: slot)
    }

    private func timeLabel(_ minutes: Int) -> String {
        let hour = minutes / 60
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(hour < 12 ? "AM" : "PM")"
    }
}

private enum IOSAllowanceEditMode {
    case select
    case deselect

    var label: String { self == .select ? "ALLOW TIME" : "REMOVE TIME" }
    var actionLabel: String { self == .select ? "SELECT ALLOWED TIME" : "DESELECT ALLOWED TIME" }
}

@ViewBuilder
private func editorHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title)
            .font(.title2.weight(.semibold))
            .tracking(-1)
        Text(subtitle)
            .font(.system(.caption2, design: .default, weight: .bold))
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
private func fieldLabel(_ title: String) -> some View {
    Text(title)
        .font(.system(.caption, design: .default, weight: .semibold))
        .foregroundStyle(.secondary)
}
