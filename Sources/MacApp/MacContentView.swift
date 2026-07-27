import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var editingRule: CloudRulePreference?
    @State private var selectedRuleID: UUID?
    @State private var isShowingLockdown = false

    var body: some View {
        VStack(spacing: 0) {
            enforcementBanner
            NavigationSplitView {
                List(model.rules, selection: $selectedRuleID) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name).font(.headline)
                        Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(rule.id)
                    .contextMenu {
                        Button("Delete Rule", role: .destructive) { model.delete(rule) }
                    }
                }
                .onChange(of: selectedRuleID) { _, id in
                    guard let id, let rule = model.rules.first(where: { $0.id == id }) else { return }
                    editingRule = rule
                    selectedRuleID = nil
                }
                .navigationTitle("Rules")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                .toolbar {
                    Button("Add Rule", systemImage: "plus") { editingRule = CloudRulePreference() }
                    Button("Lockdown…", systemImage: "lock.circle") { isShowingLockdown = true }
                    Button("Refresh", systemImage: "arrow.triangle.2.circlepath") { model.refresh() }
                }
            } detail: {
                ContentUnavailableView(
                    "iPhone Preference Companion",
                    systemImage: "iphone.and.arrow.forward",
                    description: Text("Select a rule to edit its portable preferences, or add a new one.")
                )
            }
        }
        .sheet(item: $editingRule) { rule in
            MacRuleEditor(initialRule: rule) { model.save($0) }
        }
        .sheet(isPresented: $isShowingLockdown) {
            MacLockdownSessionSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        )) { _ in
            model.refresh()
        }
        .alert("iCloud Sync", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var enforcementBanner: some View {
        MacEnforcementBanner(
            controller: model.enforcement,
            syncStatus: model.syncStatus,
            enforcementHealth: model.enforcementHealth,
            install: model.installDesktopEnforcement,
            model: model
        )
    }

    private func summary(_ rule: CloudRulePreference) -> String {
        var parts = [rule.isEnabled ? "Enabled" : "Disabled", "\(rule.windows.count) block(s)"]
        if rule.usageLimitEnabled { parts.append("\(rule.dailyUsageLimitMinutes)m/day") }
        if !rule.domains.isEmpty { parts.append("\(rule.domains.count) domains") }
        if rule.deviceLocalSelectionCount > 0 { parts.append("\(rule.deviceLocalSelectionCount) iPhone selections") }
        return parts.joined(separator: " • ")
    }
}

private struct MacEnforcementBanner: View {
    @ObservedObject var controller: MacEnforcementController
    let syncStatus: String
    let enforcementHealth: FilterEnforcementSummary.Health
    let install: () -> Void
    @ObservedObject var model: MacAppModel
    @State private var isShowingRemoval = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(controller.status.description, systemImage: statusIcon)
                    .font(.headline)
                Text("iPhone rules sync through iCloud. On this Mac, an approval-free Network Extension enforces domains, DNS queries, and common web-filter bypass paths. Local app-launch enforcement is not included. \(syncStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What the filter reports it is actually enforcing. A rejected
                // or stale policy is otherwise invisible: the rules simply do
                // nothing, which looks the same as a filter that is fine.
                Label(
                    FilterEnforcementSummary.description(for: enforcementHealth),
                    systemImage: FilterEnforcementSummary.isHealthy(enforcementHealth)
                        ? "checkmark.seal"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(FilterEnforcementSummary.isHealthy(enforcementHealth) ? Color.secondary : Color.red)
                .textSelection(.enabled)
                removalNotice
            }
            Spacer(minLength: 12)
            if controller.status == .active || controller.status == .rebootRequired {
                Button("Recovery / Remove…", role: .destructive) { isShowingRemoval = true }
            } else {
                Button("Install Web Enforcement", action: install)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(bannerColor)
        .sheet(isPresented: $isShowingRemoval) {
            MacRemovalSheet(controller: controller, model: model)
        }
    }

    /// A pending uninstall is surfaced in the banner itself, not only inside the
    /// sheet. A countdown the user has to go looking for is one they can start
    /// and forget, which defeats the point of having a delay at all.
    @ViewBuilder private var removalNotice: some View {
        switch controller.removalState {
        case .notRequested:
            EmptyView()
        case let .waiting(remaining):
            Label(
                "Uninstall requested — completes in \(MacRemovalSheet.duration(remaining)). Enforcement continues until then.",
                systemImage: "hourglass"
            )
            .font(.caption)
            .foregroundStyle(Color.orange)
        case let .ready(remaining, _):
            Label(
                "Uninstall can be confirmed for the next \(MacRemovalSheet.duration(remaining)).",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Color.red)
        case .expired:
            Label(
                "The uninstall window closed unused. Requesting again starts the full wait over.",
                systemImage: "clock.badge.xmark"
            )
            .font(.caption)
            .foregroundStyle(Color.secondary)
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .active: "lock.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .awaitingApproval, .rebootRequired: "person.badge.key.fill"
        default: "lock.shield"
        }
    }

    private var bannerColor: Color {
        switch controller.status {
        case .active: .green.opacity(0.12)
        case .failed: .red.opacity(0.12)
        default: .blue.opacity(0.1)
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
    @State private var severity = "delayed"
    @State private var passageWordCount = 8
    @State private var unlockDelayDays = 0
    @State private var typedPassage = ""
    @State private var endingSessionID: UUID?
    @State private var didFailPassage = false

    private static let severities = ["passageOnly", "delayed", "repeatedConfirmations"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lockdown session").font(.title3.weight(.semibold))

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
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Running now").font(.headline)
            ForEach(model.activeLockdownSessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(names(for: session.ruleIDs)) — \(DesktopLockdownSessionGate.remainingDescription(session.remaining(at: Date()))) left",
                        systemImage: "lock.fill"
                    )
                    .font(.callout.weight(.medium))

                    if endingSessionID == session.id {
                        Text("Type this passage to end early:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(session.earlyExitPassage)
                            .font(.system(.caption, design: .monospaced))
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                        TextField("Passage", text: $typedPassage, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        if didFailPassage {
                            Text("That does not match.").font(.caption).foregroundStyle(Color.red)
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
                .background(Color.orange.opacity(0.10))
            }
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a new session").font(.headline)
            Text("The selected lists are held on for the whole period, whatever their schedules say and whether or not they are enabled.")
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
            Stepper("Passage length: \(passageWordCount) words", value: $passageWordCount, in: 0...40)
            Stepper("Extra delay before early exit: \(unlockDelayDays)d", value: $unlockDelayDays, in: 0...30)

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

    private func names(for ids: Set<UUID>) -> String {
        let matched = model.rules.filter { ids.contains($0.id) }.map(\.name)
        return matched.isEmpty ? "\(ids.count) list(s)" : matched.joined(separator: ", ")
    }
}

/// The uninstall gate. Uninstalling is the strongest weakening of the policy,
/// so it goes through the same delay-and-passage workflow as loosening a locked
/// rule rather than through a button that answers immediately.
private struct MacRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: MacEnforcementController
    @ObservedObject var model: MacAppModel
    @State private var typedPassage = ""
    @State private var didFailPassage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove web enforcement")
                .font(.title3.weight(.semibold))

            switch controller.removalState {
            case .notRequested: notRequested
            case let .waiting(remaining): waiting(remaining)
            case let .ready(remaining, passage): ready(remaining, passage)
            case .expired: expired
            }

            Divider()
            HStack {
                if controller.removalState != .notRequested {
                    Button("Cancel uninstall", role: .destructive) {
                        model.cancelDesktopEnforcementRemoval()
                        typedPassage = ""
                    }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var notRequested: some View {
        let terms = controller.removalTerms
        return VStack(alignment: .leading, spacing: 10) {
            if terms.delaySeconds <= 0 {
                Text("No locked rule is currently in force, so enforcement can be removed right away.")
                    .font(.callout)
            } else {
                Text("Your locked rules require a wait of \(Self.duration(terms.delaySeconds)) before enforcement can be removed. Blocking stays fully active for the whole wait, and you can cancel at any point.")
                    .font(.callout)
                if terms.passageWordCount > 0 {
                    Text("When the wait ends you will have \(Self.duration(terms.confirmationWindowSeconds)) to confirm by typing a \(terms.passageWordCount)-word passage. If you miss that window, the wait starts over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Start the uninstall wait", role: .destructive) {
                model.beginDesktopEnforcementRemoval()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func waiting(_ remaining: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Uninstall completes in \(Self.duration(remaining))", systemImage: "hourglass")
                .font(.callout.weight(.medium))
            Text("Enforcement is still running and will keep running until you confirm. Nothing has been switched off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ready(_ remaining: TimeInterval, _ passage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready to confirm — \(Self.duration(remaining)) left", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.red)
            if passage.isEmpty {
                Text("Confirm to remove enforcement.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Type this passage exactly:").font(.caption).foregroundStyle(.secondary)
                Text(passage)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.disabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                TextField("Passage", text: $typedPassage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            if didFailPassage {
                Text("That does not match the passage.").font(.caption).foregroundStyle(Color.red)
            }
            Button("Remove enforcement now", role: .destructive) {
                didFailPassage = !model.completeDesktopEnforcementRemoval(passage: typedPassage)
                if !didFailPassage { dismiss() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var expired: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The confirmation window closed", systemImage: "clock.badge.xmark")
                .font(.callout.weight(.medium))
            Text("Enforcement was never removed. Cancel this request and start again if you still want to uninstall; the full wait applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }
}

private struct MacRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: CloudRulePreference
    @State private var domainText: String
    @State private var macApplicationText: String
    @State private var windowsExecutableText: String
    @State private var windowsPublisherText: String
    let onSave: (CloudRulePreference) -> Void

    private let categoryNames = ["social", "video", "news", "shopping", "gaming", "adult", "aiTools", "productivity", "education", "finance", "health", "other"]
    private let severityNames = ["appDefault", "none", "passageOnly", "delayed", "repeatedConfirmations"]

    init(initialRule: CloudRulePreference, onSave: @escaping (CloudRulePreference) -> Void) {
        _rule = State(initialValue: initialRule)
        _domainText = State(initialValue: initialRule.domains.map(\.domain).joined(separator: "\n"))
        _macApplicationText = State(initialValue: initialRule.macApplicationIdentifiers.sorted().joined(separator: "\n"))
        _windowsExecutableText = State(initialValue: initialRule.windowsExecutablePaths.sorted().joined(separator: "\n"))
        _windowsPublisherText = State(initialValue: initialRule.windowsPublisherRules.sorted().joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
                    Picker("Enforcement", selection: $rule.enforcementMode) {
                        Text("Block selected").tag("blockList")
                        Text("Fortress allow-list").tag("fortressAllowList")
                    }
                    if rule.deviceLocalSelectionCount > 0 {
                        LabeledContent("iPhone-only selections", value: "\(rule.deviceLocalSelectionCount)")
                    }
                }

                Section("Time Blocks") {
                    ForEach($rule.windows) { $window in
                        MacTimeWindowEditor(window: $window) {
                            rule.windows.removeAll { $0.id == window.id }
                        }
                    }
                    Button("Add Time Block", systemImage: "plus") { rule.windows.append(CloudTimeWindow()) }
                }

                Section("Usage Length") {
                    Toggle("Enable daily usage limit", isOn: $rule.usageLimitEnabled)
                    if rule.usageLimitEnabled {
                        Stepper("Minutes per day: \(rule.dailyUsageLimitMinutes)", value: $rule.dailyUsageLimitMinutes, in: 1...1440)
                    }
                }

                Section("Explicit Website Domains") {
                    Text("One domain per line. These portable domains can sync; sites selected in Apple's Screen Time picker cannot.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $domainText).frame(minHeight: 100)
                    DisclosureGroup("Blocked AI-classified categories") {
                        ForEach(categoryNames, id: \.self) { category in
                            Toggle(categoryLabel(category), isOn: categoryBinding(category))
                        }
                    }
                }

                Section("Desktop Applications (portable only)") {
                    Text("macOS signing identifiers remain synced for MDM or a future Apple-approved app-launch provider; this approval-free Mac edition does not enforce application launches locally.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $macApplicationText).frame(minHeight: 80)
                    Text("Windows executable paths")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $windowsExecutableText).frame(minHeight: 80)
                    Text("Windows publisher rules")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $windowsPublisherText).frame(minHeight: 60)
                }

                Section("Rule Lockdown") {
                    Picker("Severity", selection: $rule.lockdown.severity) {
                        ForEach(severityNames, id: \.self) { Text(severityLabel($0)).tag($0) }
                    }
                    if rule.lockdown.severity == "delayed" || rule.lockdown.severity == "repeatedConfirmations" {
                        Stepper("Unlock wait: \(rule.lockdown.unlockDelayDays) days", value: $rule.lockdown.unlockDelayDays, in: 0...365)
                    }
                    if rule.lockdown.severity != "none" && rule.lockdown.severity != "appDefault" {
                        Stepper("Passage: \(rule.lockdown.passageWordCount) words", value: $rule.lockdown.passageWordCount, in: 20...300)
                        Stepper("Edit window: \(rule.lockdown.editWindowHours) hours", value: $rule.lockdown.editWindowHours, in: 1...72)
                    }
                    if rule.lockdown.severity == "repeatedConfirmations" {
                        Stepper("Confirmation window: \(rule.lockdown.confirmationWindowHours) hours", value: $rule.lockdown.confirmationWindowHours, in: 1...48)
                    }
                    Toggle("Allow passage-gated extra time", isOn: $rule.lockdown.allowsTimeExtensions)
                    if rule.lockdown.allowsTimeExtensions {
                        Stepper(
                            "Maximum extra time: \(rule.lockdown.maximumTimeExtensionHours) hours",
                            value: $rule.lockdown.maximumTimeExtensionHours,
                            in: 1...8
                        )
                        Text("Requests are made on iPhone in one-hour increments. Each consecutive request doubles the required passage length.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("A locked iPhone auto-applies only strictly stronger cloud changes. Weaker, mixed, or deletion changes wait for that rule's iPhone unlock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule.name.isEmpty ? "New Rule" : rule.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save to iCloud") {
                        updateDomains()
                        updateDesktopApplications()
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 680)
    }

    private func updateDomains() {
        let domains = domainText.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
        let old = Dictionary(uniqueKeysWithValues: rule.domains.map { ($0.domain, $0) })
        rule.domains = Array(Set(domains)).sorted().map {
            old[$0] ?? CloudDomainPreference(domain: $0, category: "other", source: "user")
        }
        if !rule.domains.isEmpty { rule.websiteCategories.insert("other") }
    }

    private func updateDesktopApplications() {
        rule.macApplicationIdentifiers = normalizedLines(macApplicationText, lowercase: true)
        rule.windowsExecutablePaths = normalizedLines(windowsExecutableText, lowercase: true)
        rule.windowsPublisherRules = normalizedLines(windowsPublisherText, lowercase: true)
    }

    private func normalizedLines(_ text: String, lowercase: Bool) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return lowercase ? trimmed.lowercased() : trimmed
        })
    }

    private func categoryBinding(_ category: String) -> Binding<Bool> {
        Binding(
            get: { rule.websiteCategories.contains(category) },
            set: { value in
                if value { rule.websiteCategories.insert(category) }
                else { rule.websiteCategories.remove(category) }
            }
        )
    }

    private func categoryLabel(_ value: String) -> String {
        value == "aiTools" ? "AI Tools" : value.capitalized
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

private struct MacTimeWindowEditor: View {
    @Binding var window: CloudTimeWindow
    let onDelete: () -> Void
    private let symbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Days").fontWeight(.semibold)
                Spacer()
                Button("Remove", role: .destructive, action: onDelete).buttonStyle(.borderless)
            }
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Toggle(symbols[day - 1], isOn: Binding(
                        get: { window.weekdays.contains(day) },
                        set: { value in
                            if value { window.weekdays.insert(day) }
                            else { window.weekdays.remove(day) }
                        }
                    )).toggleStyle(.button)
                }
            }
            DatePicker("Starts", selection: $window.startsAt, displayedComponents: .hourAndMinute)
            DatePicker("Ends", selection: $window.endsAt, displayedComponents: .hourAndMinute)
        }
        .padding(.vertical, 5)
    }
}
