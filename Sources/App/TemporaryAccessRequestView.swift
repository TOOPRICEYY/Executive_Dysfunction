import SwiftUI

struct TemporaryAccessRequestView: View {
    let request: PendingTemporaryAccessRequest
    let onFinished: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var selectedRuleID: UUID
    @State private var selectedDuration: TemporaryAccessDuration
    @State private var showPassage = false
    @State private var intent: BypassEvent.Intent?

    init(request: PendingTemporaryAccessRequest, onFinished: @escaping () -> Void) {
        self.request = request
        self.onFinished = onFinished
        _selectedRuleID = State(initialValue: request.eligibleRuleIDs.first ?? UUID())
        _selectedDuration = State(initialValue: request.duration ?? .tenMinutes)
    }

    var body: some View {
        NavigationStack {
            Form {
                if eligibleRules.isEmpty {
                    ContentUnavailableView(
                        "Temporary Access Unavailable",
                        systemImage: "lock.shield",
                        description: Text("The filter changed or no longer allows temporary access.")
                    )
                } else {
                    ruleSection
                    durationSection
                    Section("Intention") { BypassIntentPicker(selection: $intent) }
                    confirmationSection
                }
            }
            .navigationTitle("Temporary Access")
            .navigationBarTitleDisplayMode(.inline)
            .iosModelErrorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(eligibleRules.isEmpty ? "Dismiss" : "Cancel") {
                        finish()
                    }
                }
            }
            .onAppear {
                if !eligibleRules.contains(where: { $0.id == selectedRuleID }),
                   let firstRule = eligibleRules.first {
                    selectedRuleID = firstRule.id
                }
                selectFirstAvailableDurationIfNeeded()
            }
            .onChange(of: selectedRuleID) { _, _ in
                selectFirstAvailableDurationIfNeeded()
            }
            .sheet(isPresented: $showPassage) {
                PassageEntryView(
                    title: "Confirm Temporary Access",
                    explanation: passageExplanation,
                    wordCount: model.timeAllowancePassageWordCount(for: selectedRuleID),
                    onVerified: { count in
                        if model.grantPendingTemporaryAccess(
                            requestID: request.id,
                            for: selectedRuleID,
                            duration: selectedDuration,
                            verifiedWordCount: count,
                            intent: intent
                        ) {
                            onFinished()
                        }
                    }, onComplete: {}
                )
            }
        }
    }

    private var eligibleRules: [BlockingRule] {
        let requested = Set(request.eligibleRuleIDs)
        return model.rules.filter {
            requested.contains($0.id)
                && $0.isEnabled
                && $0.lockdownPolicy.allowsTimeExtensions
                && requestDurationIsAvailable(for: $0.id)
        }
    }

    private var availableDurations: [TemporaryAccessDuration] {
        model.availableTemporaryAccessDurations(for: selectedRuleID)
    }

    @ViewBuilder
    private var ruleSection: some View {
        Section("Filter") {
            if eligibleRules.count == 1, let rule = eligibleRules.first {
                LabeledContent("Temporarily disable", value: rule.name)
            } else {
                Picker("Temporarily disable", selection: $selectedRuleID) {
                    ForEach(eligibleRules) { rule in
                        Text(rule.name).tag(rule.id)
                    }
                }
            }
            Text("Only the selected filter is suspended. Other active filters remain enforced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        Section("Duration") {
            if let requestedDuration = request.duration {
                LabeledContent("Access time", value: requestedDuration.title)
            } else {
                Picker("Access time", selection: $selectedDuration) {
                    ForEach(availableDurations) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var confirmationSection: some View {
        Section("Confirmation") {
            Text("Type the full confirmation passage before this filter can be disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Type Confirmation Passage…") {
                showPassage = true
            }
            .disabled(intent == nil)
        }
    }

    private var passageExplanation: String {
        let ruleName = eligibleRules.first(where: { $0.id == selectedRuleID })?.name ?? "this filter"
        return "Type the passage to disable only \(ruleName) for \(selectedDuration.title.lowercased())."
    }

    private func finish() {
        model.clearPendingTemporaryAccessRequest(id: request.id)
        onFinished()
    }

    private func requestDurationIsAvailable(for ruleID: UUID) -> Bool {
        let durations = model.availableTemporaryAccessDurations(for: ruleID)
        guard let requestDuration = request.duration else { return !durations.isEmpty }
        return durations.contains(requestDuration)
    }

    private func selectFirstAvailableDurationIfNeeded() {
        if let requestDuration = request.duration {
            selectedDuration = requestDuration
        } else if !availableDurations.contains(selectedDuration),
                  let firstDuration = availableDurations.first {
            selectedDuration = firstDuration
        }
    }
}

struct RuleTemporaryAccessRequestView: View {
    let ruleID: UUID

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDuration: TemporaryAccessDuration = .tenMinutes
    @State private var showPassage = false
    @State private var intent: BypassEvent.Intent?

    var body: some View {
        NavigationStack {
            Form {
                if let rule, !availableDurations.isEmpty {
                    Section("Filter") {
                        LabeledContent("Temporarily disable", value: rule.name)
                    }
                    Section("Duration") {
                        Picker("Access time", selection: $selectedDuration) {
                            ForEach(availableDurations) { duration in
                                Text(duration.title).tag(duration)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Intention") { BypassIntentPicker(selection: $intent) }
                    Section("Confirmation") {
                        Text("Type the full confirmation passage before this filter can be disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Type Confirmation Passage…") {
                            showPassage = true
                        }
                        .disabled(intent == nil)
                    }
                } else {
                    ContentUnavailableView(
                        "Temporary Access Unavailable",
                        systemImage: "lock.shield",
                        description: Text("This filter has no temporary access time remaining.")
                    )
                }
            }
            .navigationTitle("Temporary Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: selectFirstAvailableDurationIfNeeded)
            .sheet(isPresented: $showPassage) {
                PassageEntryView(
                    title: "Confirm Temporary Access",
                    explanation: passageExplanation,
                    wordCount: model.timeAllowancePassageWordCount(for: ruleID),
                    onVerified: { count in
                        if model.grantTimeAllowance(for: ruleID, duration: selectedDuration, verifiedWordCount: count, intent: intent) {
                            dismiss()
                        }
                    }, onComplete: {}
                )
            }
        }
    }

    private var rule: BlockingRule? {
        model.rules.first { $0.id == ruleID }
    }

    private var availableDurations: [TemporaryAccessDuration] {
        model.availableTemporaryAccessDurations(for: ruleID)
    }

    private var passageExplanation: String {
        "Type the passage to disable only \(rule?.name ?? "this filter") for \(selectedDuration.title.lowercased())."
    }

    private func selectFirstAvailableDurationIfNeeded() {
        if !availableDurations.contains(selectedDuration),
           let firstDuration = availableDurations.first {
            selectedDuration = firstDuration
        }
    }
}
