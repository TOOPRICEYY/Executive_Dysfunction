import SwiftUI

/// A deliberate check of the current entry; editing does not update the snapshot.
struct PassageCheckView: View {
    let typed: String
    let passage: String
    var exactMatch = false
    /// Definite, not a maximum. A ScrollView has no intrinsic content height, so
    /// in a content-sized sheet a maximum alone lets its viewport collapse to
    /// zero: the caption below it still rendered while the comparison itself was
    /// invisible, which made the check look broken.
    var diffHeight: CGFloat = 180
    @State private var checkedEntry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(checkedEntry == nil ? "Check passage" : "Check again") { checkedEntry = typed }
                .disabled(CommitmentPassage.normalizedWords(in: typed).isEmpty)
            if let checkedEntry {
                ScrollView {
                    PassageDiffView(typed: checkedEntry, passage: passage, caseSensitive: exactMatch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: diffHeight)
                Text("Comparison is from your last check. After editing, check again.")
                    .font(.caption).foregroundStyle(.secondary)
                if exactMatch && checkedEntry != passage {
                    Text("This action requires exact capitalization, punctuation and spacing. The entry does not yet match exactly.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onChange(of: passage) { _, _ in checkedEntry = nil }
    }
}

/// The word-level comparison shown after a passage check.
///
/// Both platforms need this. A long commitment passage with one mistyped
/// character is otherwise unfixable: the entry is rejected with no indication
/// of which word is wrong, and re-reading eighty words to find a missing letter
/// is exactly the friction the passage is not supposed to impose.
///
/// The diff is deliberately a snapshot taken on request rather than a live
/// comparison, so it cannot be used to type the passage one green word at a
/// time.
struct PassageDiffView: View {
    let typed: String
    let passage: String
    var caseSensitive = false

    private var tokens: [PassageDiffToken] {
        PassageDiff.compare(typed: typed, passage: passage, caseSensitive: caseSensitive)
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
