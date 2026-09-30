import SwiftUI

/// Newest-first list of tamper events: clock changes, the filter switched off
/// outside Holdfast, emergency disables and removal requests.
struct TamperJournalList: View {
    let events: [TamperEvent]
    var limit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tamper journal").font(.headline)
            if events.isEmpty {
                Text("Nothing recorded. Emergency disables, clock changes and the filter being switched off outside Holdfast appear here and sync through iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(events.suffix(limit).reversed())) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).fontWeight(.semibold)
                        Text("\(event.at.formatted(date: .abbreviated, time: .shortened)) · \(event.origin)\(event.detail.isEmpty ? "" : " · \(event.detail)")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
