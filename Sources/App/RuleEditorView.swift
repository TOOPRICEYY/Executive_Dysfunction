import FamilyControls
import SwiftUI

struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var rule: BlockingRule
    @State private var selection: FamilyActivitySelection
    @State private var showActivityPicker = false
    @State private var domainInput = ""
    @State private var isClassifying = false
    @State private var classificationNote: String?
    @State private var showSaveRejection = false

    let onSave: (BlockingRule) -> Bool

    init(initialRule: BlockingRule, onSave: @escaping (BlockingRule) -> Bool) {
        _rule = State(initialValue: initialRule)
        _selection = State(initialValue: initialRule.selection)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            basicsSection
            lockdownSection
            selectionSection
            scheduleSection
            usageSection
            websiteSection
        }
        .navigationTitle(rule.name.isEmpty ? "Rule" : rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .familyActivityPicker(isPresented: $showActivityPicker, selection: $selection)
        .alert("Rule remains locked", isPresented: $showSaveRejection) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This draft is not strictly more restrictive in every affected dimension. Use Unlock for Broader Changes, then save during its editing window.")
        }
    }

    private var lockdownSection: some View {
        Section("Edit Lockdown") {
            if model.isRuleEditingLocked(rule.id) {
                Label(
                    "Locked: strictly stronger drafts can still be saved without an unlock.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                NavigationLink("Unlock for Broader Changes") {
                    RuleLockdownView(ruleID: rule.id)
                }
            }
            Picker("Severity", selection: $rule.lockdownPolicy.severity) {
                ForEach(RuleLockdownSeverity.allCases) { severity in
                    Text(severity.title).tag(severity)
                }
            }
            Text(rule.lockdownPolicy.severity.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if usesCustomLockdown {
                if rule.lockdownPolicy.severity != .passageOnly {
                    Stepper(
                        "Unlock wait: \(rule.lockdownPolicy.unlockDelayDays) day(s)",
                        value: $rule.lockdownPolicy.unlockDelayDays,
                        in: LockdownConfiguration.delayRange
                    )
                }
                Stepper(
                    "Passage length: \(rule.lockdownPolicy.passageWordCount) words",
                    value: $rule.lockdownPolicy.passageWordCount,
                    in: LockdownConfiguration.passageWordRange,
                    step: 10
                )
                if rule.lockdownPolicy.severity == .repeatedConfirmations {
                    Stepper(
                        "Checkpoint window: \(rule.lockdownPolicy.confirmationWindowHours) hour(s)",
                        value: $rule.lockdownPolicy.confirmationWindowHours,
                        in: LockdownConfiguration.confirmationWindowRange
                    )
                }
                Stepper(
                    "Editing window: \(rule.lockdownPolicy.editWindowHours) hour(s)",
                    value: $rule.lockdownPolicy.editWindowHours,
                    in: LockdownConfiguration.editWindowRange
                )
            }

            Toggle("Allow temporary pause from block page", isOn: $rule.lockdownPolicy.allowsTimeExtensions)
            if rule.lockdownPolicy.allowsTimeExtensions {
                Stepper(
                    "Maximum extra time: \(rule.lockdownPolicy.maximumTimeExtensionHours) hour(s)",
                    value: $rule.lockdownPolicy.maximumTimeExtensionHours,
                    in: TimeAllowancePolicy.maximumHoursRange
                )
                Text("The block screen can offer 10, 30, or 60 minutes after the rule's confirmation passage is typed. Consecutive requests use progressively longer passages and cannot exceed this cumulative limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var usesCustomLockdown: Bool {
        rule.lockdownPolicy.severity != .appDefault
            && rule.lockdownPolicy.severity != .none
    }

    private var basicsSection: some View {
        Section("Rule") {
            TextField("Name", text: $rule.name)
            Toggle("Enabled", isOn: $rule.isEnabled)
            Picker("Mode", selection: $rule.enforcementMode) {
                ForEach(EnforcementMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(rule.enforcementMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if rule.enforcementMode == .fortressAllowList {
                Label("Apple category tokens cannot be allow-list exceptions. Select individual apps and domains.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var selectionSection: some View {
        Section(rule.enforcementMode == .blockList ? "Activities to Block" : "Activities to Allow") {
            Button {
                showActivityPicker = true
            } label: {
                LabeledContent("Choose apps, sites & categories", value: "\(selectionCount) selected")
            }
        }
    }

    private var scheduleSection: some View {
        Section("Recurring Time Blocks") {
            ForEach($rule.windows) { $window in
                TimeWindowEditor(window: $window) {
                    rule.windows.removeAll { $0.id == window.id }
                }
            }
            Button("Add Time Block", systemImage: "plus") {
                rule.windows.append(TimeWindow())
            }
        }
    }

    private var usageSection: some View {
        Section("Daily Usage Length") {
            Toggle("Enforce a daily usage limit", isOn: $rule.usageLimitEnabled)
            if rule.usageLimitEnabled {
                Stepper(
                    "\(rule.dailyUsageLimitMinutes) minutes",
                    value: $rule.dailyUsageLimitMinutes,
                    in: 1...1_440,
                    step: 5
                )
                Text("Usage is accumulated for the selected activity tokens. iOS invokes the monitor extension when the threshold is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var websiteSection: some View {
        Section("On-device Website Classification") {
            TextEditor(text: $domainInput)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if domainInput.isEmpty {
                        Text("Enter domains, one per line\nexample.com\nyoutube.com")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                classifyDomains()
            } label: {
                if isClassifying {
                    ProgressView()
                } else {
                    Label("Classify Domains", systemImage: "sparkles")
                }
            }
            .disabled(isClassifying || DomainClassifier.normalizedDomains(from: domainInput).isEmpty)

            if let classificationNote {
                Text(classificationNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(WebsiteCategory.allCases.filter(categoryHasDomains)) { category in
                Toggle(isOn: categoryBinding(category)) {
                    VStack(alignment: .leading) {
                        Text(category.title)
                        Text(domains(in: category).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !rule.classifiedDomains.isEmpty {
                Button("Clear Classified Domains", role: .destructive) {
                    rule.classifiedDomains = []
                    rule.websiteCategories = []
                }
            }

            Text(rule.enforcementMode == .blockList
                 ? "Enabled categories above are blocked."
                 : "Enabled categories above become explicit domain exceptions to the Fortress web filter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
    }

    private func categoryHasDomains(_ category: WebsiteCategory) -> Bool {
        rule.classifiedDomains.contains { $0.category == category }
    }

    private func domains(in category: WebsiteCategory) -> [String] {
        rule.classifiedDomains.filter { $0.category == category }.map(\.domain).sorted()
    }

    private func categoryBinding(_ category: WebsiteCategory) -> Binding<Bool> {
        Binding(
            get: { rule.websiteCategories.contains(category) },
            set: { enabled in
                if enabled { rule.websiteCategories.insert(category) }
                else { rule.websiteCategories.remove(category) }
            }
        )
    }

    private func classifyDomains() {
        let domains = DomainClassifier.normalizedDomains(from: domainInput)
        isClassifying = true
        Task {
            let results = await DomainClassifier.classify(domains)
            await MainActor.run {
                let reclassified = Set(results.map(\.domain))
                rule.classifiedDomains.removeAll { reclassified.contains($0.domain) }
                rule.classifiedDomains.append(contentsOf: results)
                rule.websiteCategories.formUnion(results.map(\.category))
                domainInput = ""
                let usedAI = results.contains { $0.source == .appleIntelligence }
                classificationNote = usedAI
                    ? "Classified locally with Apple Intelligence."
                    : "Apple Intelligence was unavailable; classified with the local heuristic fallback."
                isClassifying = false
            }
        }
    }

    private func save() {
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.selection = selection
        if onSave(rule) {
            dismiss()
        } else {
            showSaveRejection = true
        }
    }
}

private struct TimeWindowEditor: View {
    @Binding var window: TimeWindow
    let onDelete: () -> Void

    private let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Days").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Remove", role: .destructive, action: onDelete)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }

            HStack(spacing: 7) {
                ForEach(1...7, id: \.self) { weekday in
                    Button {
                        if window.weekdays.contains(weekday) { window.weekdays.remove(weekday) }
                        else { window.weekdays.insert(weekday) }
                    } label: {
                        Text(weekdaySymbols[weekday - 1])
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(window.weekdays.contains(weekday) ? Color.indigo : Color.secondary.opacity(0.15))
                            .foregroundStyle(window.weekdays.contains(weekday) ? .white : .primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            DatePicker("Starts", selection: startBinding, displayedComponents: .hourAndMinute)
            DatePicker("Ends", selection: endBinding, displayedComponents: .hourAndMinute)
        }
        .padding(.vertical, 4)
    }

    private var startBinding: Binding<Date> {
        Binding(get: { window.startsAt }, set: { window.startsAt = $0 })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { window.endsAt }, set: { window.endsAt = $0 })
    }
}
