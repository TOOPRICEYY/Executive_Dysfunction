import SwiftUI

struct MacRuleEditUnlockSheet: View {
    @ObservedObject var model: MacAppModel
    let ruleID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var failed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 18) {
                Text("UNLOCK GROUP CHANGES").font(.title2.bold())
                Text("Blocking continues during the unlock process. Once editing opens, return to the group and save your changes.")
                if let policy = model.ruleEditPolicy(ruleID) {
                    if policy.severity == "none" {
                        Text("This group has no edit lock.")
                    } else {
                        switch model.ruleEditPhase(ruleID, now: context.date) {
                        case .idle, .cancelled:
                            Text("Wait after passage: \(DesktopRuleEditUnlock.configuration(policy).unlockDelayDays) day(s)")
                            passage(policy)
                        case let .waiting(unlocksAt, nextConfirmationAt):
                            Text("Editing opens: \(unlocksAt.formatted())")
                            if let nextConfirmationAt { Text("Next checkpoint: \(nextConfirmationAt.formatted())") }
                            Button("CANCEL UNLOCK") { model.cancelRuleEditUnlock(ruleID) }
                        case let .confirmationDue(_, deadline, checkpoint, total):
                            Text("Checkpoint \(checkpoint)/\(total) due by \(deadline.formatted())")
                            passage(policy)
                        case let .unlocked(editWindowEndsAt):
                            Text("EDITING OPEN UNTIL \(editWindowEndsAt.formatted())")
                            Button("RE-LOCK NOW") { model.cancelRuleEditUnlock(ruleID) }
                        }
                    }
                } else { Text("Group no longer exists.") }
                Button("DONE") { dismiss() }
                    .buttonStyle(MacBrutalButtonStyle())
            }
            .padding(24)
            .frame(width: 560)
            .macBrutalSheet()
        }
    }

    private func passage(_ policy: DesktopLockdownPolicy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MacConfirmationPassageView(passage: DesktopRemovalGate.passage(
                wordCount: DesktopRuleEditUnlock.configuration(policy).passageWordCount, seed: ruleID))
            MacPassageInput(text: $typed).frame(height: 100).macBrutalTextField()
            PassageCheckView(typed: typed, passage: DesktopRemovalGate.passage(
                wordCount: DesktopRuleEditUnlock.configuration(policy).passageWordCount, seed: ruleID))
            if failed { Text("Passage did not match, or the saved policy changed. Try again.").foregroundStyle(.red) }
            Button("CONFIRM PASSAGE") {
                failed = !model.submitRuleEditPassage(ruleID, typed: typed, expectedPolicy: policy)
                if !failed { typed = "" }
            }
            .buttonStyle(MacBrutalButtonStyle(.primary))
        }
    }
}
