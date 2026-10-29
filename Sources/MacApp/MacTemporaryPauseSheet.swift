import SwiftUI

/// The passage gate in front of a temporary pause.
///
/// The passage is generated once when the sheet opens and its length comes from
/// the group's own policy, doubling for each pause already taken in the session.
/// That escalation is the friction: a first pause is cheap, a fourth is not.
struct MacTemporaryPauseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacAppModel
    let ruleID: UUID
    let ruleName: String

    @State private var duration: TemporaryAccessDuration = .tenMinutes
    @State private var requiredPassage = ""
    @State private var typedPassage = ""
    @State private var showsMismatch = false
    @State private var intent: BypassEvent.Intent?
    @State private var reflection = ""
    @State private var reflectionPrompt = ReflectionPrompt.prompt(for: UUID())

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.temporaryPause(for: ruleID) == nil ? "Disable temporarily" : "Extend pause")
                .font(.title3.weight(.semibold))
            Text("\(ruleName) stops being enforced on this Mac for the period you choose, then resumes on its own.")
                .font(.callout)

            Picker("For", selection: $duration) {
                ForEach(availableDurations) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            BypassIntentPicker(selection: $intent)
            BypassReflectionField(prompt: reflectionPrompt, answer: $reflection)

            Text("Type this passage exactly. Case and line breaks do not matter.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MacConfirmationPassageView(passage: requiredPassage, height: 170)
            if !requiredPassage.isEmpty {
                Text("Current requirement: \(CommitmentPassage.normalizedWords(in: requiredPassage).count) words.")
                    .font(.caption.weight(.medium))
            }
            Text(model.pausePassageExplanation(for: ruleID))
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            MacPassageInput(text: $typedPassage)
                .frame(height: 110)
                .macBrutalTextField()
                .lineLimit(3...8)

            PassageCheckView(typed: typedPassage, passage: requiredPassage)

            if showsMismatch {
                Label("That does not match the passage.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacBrutalButtonStyle())
                Button("Disable for \(duration.title)", role: .destructive, action: confirm)
                    .buttonStyle(MacBrutalButtonStyle(.danger))
                    .disabled(intent == nil || !ReflectionPrompt.isSufficient(reflection)
                        || typedPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .macBrutalSheet()
        .onAppear(perform: prepare)
    }

    private var availableDurations: [TemporaryAccessDuration] {
        let available = model.availablePauseDurations(for: ruleID)
        return available.isEmpty ? [.tenMinutes] : available
    }

    private func prepare() {
        if let first = availableDurations.first, !availableDurations.contains(duration) {
            duration = first
        }
        // Generated once per sheet: regenerating on each keystroke would make
        // the passage impossible to type.
        requiredPassage = CommitmentPassage.generate(
            wordCount: model.pausePassageWordCount(for: ruleID)
        )
    }

    private func confirm() {
        guard let intent else { return }
        guard CommitmentPassage.matches(typedPassage, passage: requiredPassage) else {
            showsMismatch = true
            return
        }
        if model.grantTemporaryPause(for: ruleID, duration: duration,
            verifiedWordCount: CommitmentPassage.normalizedWords(in: requiredPassage).count, intent: intent,
            reflection: ReflectionPrompt.normalized(reflection)) {
            dismiss()
        }
    }
}
