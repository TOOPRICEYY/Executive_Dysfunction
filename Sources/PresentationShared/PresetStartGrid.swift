import SwiftUI

/// First-run choices shown where an empty list would otherwise be.
///
/// An empty dashboard asks someone to design a system before they get any
/// help; for this audience that is the point where many people stop. Four
/// ready-made starting points turn setup into one tap, and every one of them
/// is ordinary, editable groups afterwards.
struct PresetStartGrid: View {
    var accent: Color = .accentColor
    var rule: Color = .secondary
    let onPick: (HoldfastPresets.BlockingPreset) -> Void
    var onCustom: (() -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with one of these")
                .font(.headline)
            Text("Each adds a Blocking Group with sensible apps, websites, a schedule and a lock. You can change anything later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(HoldfastPresets.blockingPresets) { preset in
                    Button { onPick(preset) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.name).font(.callout.weight(.bold))
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(lockLabel(preset.severity))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .padding(12)
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
                    .foregroundStyle(accent)
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
