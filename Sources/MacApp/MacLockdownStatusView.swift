import SwiftUI

/// Commitments remain visible even while web enforcement is paused; the
/// enforcement status above this panel remains the source of connection health.
struct MacLockdownStatusView: View {
    let sessions: [DesktopLockdownSession]
    let rules: [CloudRulePreference]
    var syncStatus: String? = nil
    let onManage: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let active = sessions.filter { $0.isActive(at: context.date) }
                .sorted { $0.endsAt < $1.endsAt }
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("TEMPORARY LOCKDOWNS · \(active.count)")
                            .font(.system(.headline, design: .monospaced, weight: .black))
                        Spacer()
                        Button("MANAGE", action: onManage)
                            .buttonStyle(MacBrutalButtonStyle())
                    }
                    ForEach(active) { session in
                        Button(action: onManage) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(names(for: session))
                                    .font(.system(.body, design: .monospaced, weight: .bold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(DesktopLockdownSessionGate.remainingDescription(session.remaining(at: context.date))) remaining · Ends \(session.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(MacBrutalPalette.raisedSurface)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens lockdown controls. Ending early requires its confirmation passage.")
                    }
                    Text("HOLDS THESE GROUPS ON OUTSIDE THEIR NORMAL SCHEDULES. WEB BLOCKING STILL REQUIRES WEB ENFORCEMENT.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let syncStatus { Text(syncStatus).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(20)
                .background(MacBrutalPalette.surface)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                .accessibilityIdentifier("temporary-lockdown-status")
            }
        }
    }

    private func names(for session: DesktopLockdownSession) -> String {
        let snapshotNames = Dictionary((session.ruleSnapshots ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let names = session.ruleIDs.compactMap { id in rules.first { $0.id == id }?.name ?? snapshotNames[id] }.sorted()
        let missing = session.ruleIDs.count - names.count
        return (names + (missing > 0 ? ["\(missing) unavailable group(s)"] : []))
            .joined(separator: ", ")
    }
}
