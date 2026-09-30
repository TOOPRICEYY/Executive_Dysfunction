import SwiftUI

/// First-run choices shown where an empty list would otherwise be.
///
/// An empty dashboard asks someone to design a system before they get any
/// help; for this audience that is the point where many people stop. Four
/// ready-made starting points turn setup into one tap, and every one of them
/// is ordinary, editable groups afterwards.
struct PresetStartGrid: View {
    var accent: Color = .accentColor
    /// Text-safe version of the accent (bright fills can be unreadable as text).
    var ink: Color? = nil
    var rule: Color = .secondary
    let onPick: (HoldfastPresets.BlockingPreset) -> Void
    var onCustom: (() -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with a preset")
                .font(.headline)
            Text("Each adds an editable group with sites, a schedule and a lock.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(HoldfastPresets.blockingPresets) { preset in
                    Button { onPick(preset) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name).font(.subheadline.weight(.bold))
                            Text(preset.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(lockLabel(preset.severity))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(ink ?? accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .padding(10)
                        .overlay { Rectangle().stroke(rule, lineWidth: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("preset-\(preset.id)")
                }
            }
            if let onCustom {
                Button("Or build your own", action: onCustom)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ink ?? accent)
                    .accessibilityIdentifier("NEW BLOCKING GROUP")
            }
        }
    }

    private func lockLabel(_ severity: String) -> String {
        switch severity {
        case "passageOnly": "PASSAGE TO CHANGE"
        case "delayed": "DELAY + PASSAGE"
        case "repeatedConfirmations": "DAILY CONFIRMATIONS"
        default: "NO LOCK"
        }
    }
}
