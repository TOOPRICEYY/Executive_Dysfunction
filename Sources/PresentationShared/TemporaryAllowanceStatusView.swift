import SwiftUI

struct TemporaryAllowanceStatusView: View {
    let expiresAt: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let expiresAt, expiresAt > context.date {
                Label("Temporarily allowed until \(expiresAt.formatted(date: Calendar.current.isDate(expiresAt, inSameDayAs: context.date) ? .omitted : .abbreviated, time: .shortened))", systemImage: "pause.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("temporary-allowance-status")
            }
        }
    }
}
