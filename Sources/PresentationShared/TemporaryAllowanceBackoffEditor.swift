import SwiftUI

struct TemporaryAllowanceBackoffEditor: View {
    @Binding var resetDays: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Passage backoff", isOn: Binding(get: { resetDays != nil }, set: { resetDays = $0 ? 7 : nil }))
            if resetDays != nil {
                Stepper("Reset every \(resetDays ?? 7) day(s)", value: Binding(
                    get: { resetDays ?? 7 }, set: { resetDays = $0 }
                ), in: TemporaryAllowanceBackoff.daysRange)
                .accessibilityIdentifier("allowance-backoff-reset-days")
                Text(TemporaryAllowanceBackoff.description(resetDays: resetDays))
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                Text("Request allowances in Holdfast when backoff is on, including for blocked websites.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
    }
}
