import SwiftUI

struct LockdownStatusBadge: View {
    let endsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if endsAt > context.date {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Lockdown · until \(endsAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "lock.shield")
                        .font(.caption.weight(.semibold))
                    Text("Overrides schedule and temporary access.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lockdown-group-status")
            }
        }
    }
}
