import SwiftUI

struct IOSTimedLockdownView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var hours = 4
    @State private var ending: UUID?
    @State private var typed = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hold selected groups on continuously across all your devices, including during allowance windows and existing temporary pauses. Saved schedules remain unchanged.")
                    Text(model.lockdownSyncStatus).font(.caption).foregroundStyle(.secondary)
                    Text("New lockdowns require an 80-word passage to end early. Shared lockdowns keep their original passage, delay and checkpoints. Ending early applies to all devices. Emergency Screen Time recovery remains available in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("iOS uses a roughly timed Screen Time window, padded by up to 15 minutes. Reopen Holdfast at the deadline to reconcile blocking precisely; background callbacks can be delayed by iOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.activeTimedLockdowns.isEmpty {
                    Section("Running lockdowns") {
                        ForEach(model.activeTimedLockdowns) { session in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(session.rules.map(\.name).joined(separator: ", ")).font(.headline)
                                LockdownStatusBadge(endsAt: session.endsAt)
                                if ending == session.id {
                                    Text(session.earlyExitPassage).textSelection(.disabled).font(.callout)
                                    IOSPassageInput(text: $typed).frame(minHeight: 160)
                                    if failed { Text(model.errorMessage ?? "Passage did not match, or the lockdown could not be ended.").foregroundStyle(.red) }
                                    Button("End lockdown", role: .destructive) {
                                        failed = !model.endTimedLockdown(session, passage: typed)
                                        if !failed { ending = nil; typed = "" }
                                    }
                                    Button("Keep lockdown") { ending = nil; typed = "" }
                                } else {
                                    Button("End with passage…") { ending = session.id; typed = ""; failed = false }
                                }
                            }
                        }
                    }
                }
                Section("Blocking groups") {
                    if model.rules.isEmpty {
                        Text("Create a Blocking Group on the dashboard first, then choose it here.").foregroundStyle(.secondary)
                    }
                    ForEach(model.rules) { rule in
                        Toggle(rule.name, isOn: Binding(
                            get: { selected.contains(rule.id) },
                            set: { if $0 { selected.insert(rule.id) } else { selected.remove(rule.id) } }
                        ))
                    }
                }
                Section("Duration") {
                    Picker("Hold for", selection: $hours) {
                        Text("1 hour").tag(1)
                        Text("4 hours").tag(4)
                        Text("12 hours").tag(12)
                        Text("24 hours").tag(24)
                        Text("3 days").tag(72)
                        Text("7 days").tag(168)
                    }
                    Button("Start lockdown", role: .destructive) {
                        if model.startTimedLockdown(ruleIDs: selected, hours: hours) { selected = [] }
                    }
                    .disabled(selected.isEmpty || !model.isAuthorized)
                    .accessibilityIdentifier("confirm-timed-lockdown")
                    if !model.isAuthorized {
                        Text("Connect Screen Time in Settings before starting lockdown.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = model.errorMessage { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("Lockdown")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
