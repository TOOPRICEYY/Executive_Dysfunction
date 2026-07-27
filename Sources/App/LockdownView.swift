import SwiftUI

struct LockdownView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showStartPassage = false
    @State private var showConfirmPassage = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            configurationSection
            if model.lockdownConfiguration.isEnabled {
                unlockSection
            }
        }
        .navigationTitle("Settings Lockdown")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshLockdown() }
        .onReceive(refreshTimer) { _ in model.refreshLockdown() }
        .sheet(isPresented: $showStartPassage) {
            PassageEntryView(
                title: "Start Unlock",
                explanation: "Type the passage below to begin the unlock countdown. Editing opens after the waiting period ends.",
                wordCount: model.lockdownConfiguration.passageWordCount
            ) {
                model.startUnlock()
            }
        }
        .sheet(isPresented: $showConfirmPassage) {
            PassageEntryView(
                title: "Daily Confirmation",
                explanation: "Type the passage below to keep the unlock process alive. Missing a daily confirmation cancels it.",
                wordCount: model.lockdownConfiguration.passageWordCount
            ) {
                model.confirmUnlock()
            }
        }
    }

    private var configurationSection: some View {
        Section("Lockdown") {
            Toggle("Enable settings lockdown", isOn: configBinding(\.isEnabled))
            Stepper(
                "Unlock wait: \(model.lockdownConfiguration.unlockDelayDays) day(s)",
                value: configBinding(\.unlockDelayDays),
                in: LockdownConfiguration.delayRange
            )
            Toggle("Require daily typed confirmations", isOn: configBinding(\.repeatConfirmations))
            Stepper(
                "Passage length: \(model.lockdownConfiguration.passageWordCount) words",
                value: configBinding(\.passageWordCount),
                in: LockdownConfiguration.passageWordRange,
                step: 10
            )
            if model.lockdownConfiguration.repeatConfirmations {
                Stepper(
                    "Checkpoint window: \(model.lockdownConfiguration.confirmationWindowHours) hour(s)",
                    value: configBinding(\.confirmationWindowHours),
                    in: LockdownConfiguration.confirmationWindowRange
                )
            }
            Stepper(
                "Editing window: \(model.lockdownConfiguration.editWindowHours) hour(s)",
                value: configBinding(\.editWindowHours),
                in: LockdownConfiguration.editWindowRange
            )
            Text("Configure these options before enabling lockdown. Once enabled, existing rules, anti-uninstall, and lockdown itself cannot be weakened without completing an unlock. Adding or tightening protection remains available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var unlockSection: some View {
        Section("Unlock Process") {
            switch model.unlockPhase {
            case .idle, .cancelled:
                Button("Start Unlock Process…") { showStartPassage = true }
                Text("Starting requires typing a commitment passage. Editing opens after \(model.lockdownConfiguration.unlockDelayDays) full 24-hour period(s)\(model.lockdownConfiguration.repeatConfirmations ? ", with one additional passage at each daily checkpoint" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case let .waiting(unlocksAt, nextConfirmationAt):
                LabeledContent("Earliest edit unlock", value: unlocksAt.formatted(date: .abbreviated, time: .shortened))
                if let nextConfirmationAt {
                    LabeledContent(
                        "Next confirmation",
                        value: nextConfirmationAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                Button("Abandon Unlock Process", role: .destructive) { model.cancelUnlock() }

            case let .confirmationDue(unlocksAt, deadline, checkpoint, total):
                LabeledContent("Earliest edit unlock", value: unlocksAt.formatted(date: .abbreviated, time: .shortened))
                Label(
                    "Checkpoint \(checkpoint) of \(total) is due before \(deadline.formatted(date: .abbreviated, time: .shortened)) or the unlock cancels.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Type Today's Confirmation…") { showConfirmPassage = true }
                Button("Abandon Unlock Process", role: .destructive) { model.cancelUnlock() }

            case let .unlocked(editWindowEndsAt):
                Label(
                    "Editing is unlocked until \(editWindowEndsAt.formatted(date: .abbreviated, time: .shortened)).",
                    systemImage: "lock.open"
                )
                .foregroundStyle(.green)
                Button("Re-lock Now", role: .destructive) { model.cancelUnlock() }
            }
        }
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<LockdownConfiguration, T>) -> Binding<T> {
        Binding(
            get: { model.lockdownConfiguration[keyPath: keyPath] },
            set: { newValue in
                var configuration = model.lockdownConfiguration
                configuration[keyPath: keyPath] = newValue
                model.updateLockdownConfiguration(configuration)
            }
        )
    }
}

struct RuleLockdownView: View {
    let ruleID: UUID

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showStartPassage = false
    @State private var showConfirmPassage = false

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let rule {
                Section("Rule Protection") {
                    LabeledContent("Rule", value: rule.name)
                    LabeledContent("Severity", value: rule.lockdownPolicy.severity.title)
                    Text(rule.lockdownPolicy.severity.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                unlockSection(rule: rule)
            } else {
                ContentUnavailableView("Rule Not Found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Rule Unlock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { model.refreshRuleLockdowns() }
        .onReceive(refreshTimer) { _ in model.refreshRuleLockdowns() }
        .sheet(isPresented: $showStartPassage) {
            PassageEntryView(
                title: "Unlock \(rule?.name ?? "Rule")",
                explanation: "Type the passage to start this rule's independent unlock process.",
                wordCount: configuration.passageWordCount
            ) {
                model.startRuleUnlock(ruleID)
            }
        }
        .sheet(isPresented: $showConfirmPassage) {
            PassageEntryView(
                title: "Rule Confirmation",
                explanation: "Type the passage before this checkpoint expires, or this rule's unlock is cancelled.",
                wordCount: configuration.passageWordCount
            ) {
                model.confirmRuleUnlock(ruleID)
            }
        }
    }

    private var rule: BlockingRule? {
        model.rules.first { $0.id == ruleID }
    }

    private var configuration: LockdownConfiguration {
        guard let rule else { return LockdownConfiguration() }
        return model.ruleLockdownConfiguration(for: rule)
    }

    @ViewBuilder
    private func unlockSection(rule: BlockingRule) -> some View {
        Section("Unlock Process") {
            switch model.ruleUnlockPhases[rule.id] ?? model.ruleUnlockPhase(for: rule.id) {
            case .idle, .cancelled:
                Button("Start Rule Unlock…") { showStartPassage = true }
                if configuration.unlockDelayDays == 0 {
                    Text("Editing opens immediately after the passage is entered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The earliest edit unlock is \(configuration.unlockDelayDays) day(s) after the initial passage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .waiting(unlocksAt, nextConfirmationAt):
                LabeledContent("Earliest edit unlock", value: unlocksAt.formatted(date: .abbreviated, time: .shortened))
                if let nextConfirmationAt {
                    LabeledContent("Next confirmation", value: nextConfirmationAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Cancel Rule Unlock", role: .destructive) {
                    model.cancelRuleUnlock(rule.id)
                }

            case let .confirmationDue(unlocksAt, deadline, checkpoint, total):
                LabeledContent("Earliest edit unlock", value: unlocksAt.formatted(date: .abbreviated, time: .shortened))
                Label(
                    "Checkpoint \(checkpoint) of \(total) is due before \(deadline.formatted(date: .abbreviated, time: .shortened)).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Type This Checkpoint…") { showConfirmPassage = true }
                Button("Cancel Rule Unlock", role: .destructive) {
                    model.cancelRuleUnlock(rule.id)
                }

            case let .unlocked(editWindowEndsAt):
                Label(
                    "This rule can be edited until \(editWindowEndsAt.formatted(date: .abbreviated, time: .shortened)).",
                    systemImage: "lock.open"
                )
                .foregroundStyle(.green)
                Button("Done — Return to Edit Rule") { dismiss() }
                Button("Re-lock Rule Now", role: .destructive) {
                    model.cancelRuleUnlock(rule.id)
                }
            }
        }
    }
}

struct PassageEntryView: View {
    let title: String
    let explanation: String
    let wordCount: Int
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passage = ""
    @State private var typed = ""
    @State private var checkedEntry: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Type this passage") {
                    Text(passage)
                        .font(.callout)
                }
                Section("Your entry") {
                    TextEditor(text: $typed)
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Passage check") {
                    Button(checkedEntry == nil ? "Check Passage" : "Check Again") {
                        checkedEntry = typed
                    }
                    .disabled(CommitmentPassage.normalizedWords(in: typed).isEmpty)

                    if let checkedEntry {
                        PassageDiffView(typed: checkedEntry, passage: passage)
                        Text("This is a snapshot from the last check. It will not update while you type.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Confirm") {
                        onComplete()
                        dismiss()
                    }
                    .disabled(!CommitmentPassage.matches(typed, passage: passage))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if passage.isEmpty {
                    passage = CommitmentPassage.generate(wordCount: wordCount)
                }
            }
        }
    }
}

private struct PassageDiffView: View {
    let typed: String
    let passage: String

    private var tokens: [PassageDiffToken] {
        PassageDiff.compare(typed: typed, passage: passage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                legendItem(color: .green, label: "Correct")
                legendItem(color: .red, label: "Incorrect")
                Text("Struck = missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if CommitmentPassage.normalizedWords(in: typed).isEmpty {
                Text("Start typing to see the comparison.")
                    .foregroundStyle(.secondary)
            } else {
                diffText
                    .font(.callout.monospaced())
                    .textSelection(.disabled)
                    .accessibilityLabel(accessibilityDescription)
            }
        }
    }

    private var diffText: Text {
        tokens.reduce(Text("")) { partial, token in
            partial + styledText(for: token) + Text(" ")
        }
    }

    private func styledText(for token: PassageDiffToken) -> Text {
        switch token.kind {
        case .matched:
            Text(token.text).foregroundColor(.green)
        case .incorrect:
            Text(token.text).foregroundColor(.red).bold()
        case .missing:
            Text(token.text).foregroundColor(.red.opacity(0.55)).strikethrough()
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        Label {
            Text(label).font(.caption2)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private var accessibilityDescription: String {
        let correct = tokens.filter { $0.kind == .matched }.count
        let incorrect = tokens.filter { $0.kind == .incorrect }.count
        let missing = tokens.filter { $0.kind == .missing }.count
        return "\(correct) correct words, \(incorrect) incorrect words, \(missing) missing words."
    }
}
