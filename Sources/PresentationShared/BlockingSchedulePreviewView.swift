import SwiftUI

/// A read-only weekly overview. Editing stays in the full schedule painter.
struct BlockingSchedulePreviewView: View {
    let plan: CloudTimeWindowPlan
    var isEnabled = true
    var hasUsageLimit = false
    @State private var isExpanded = false
    private let days = [(2, "Mon", "Monday"), (3, "Tue", "Tuesday"), (4, "Wed", "Wednesday"),
                        (5, "Thu", "Thursday"), (6, "Fri", "Friday"), (7, "Sat", "Saturday"), (1, "Sun", "Sunday")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Text("Weekly blocking").fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(isExpanded ? "Less" : "Details").foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse weekly blocking schedule" : "Expand weekly blocking schedule")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("blocking-schedule-toggle")

            if isExpanded {
                HStack(spacing: 16) {
                    key("Blocked", color: .accentColor)
                    key("Allowed", color: .secondary.opacity(0.18))
                }
                .font(.caption2)
                .accessibilityHidden(true)
                HStack {
                    Text("00")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("24")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 36)
                .accessibilityHidden(true)
                ForEach(days, id: \.0) { day in
                    HStack(spacing: 8) {
                        Text(day.1)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                            .accessibilityHidden(true)
                        dayBar(day)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(days, id: \.0) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.1)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            dayBar(day)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Text(isEnabled ? "Local time · Schedule only" : "Group disabled · Saved schedule")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if hasUsageLimit && isExpanded {
                Text("Usage limits can also block allowed time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Weekly blocking schedule")
        .accessibilityIdentifier("blocking-schedule-preview")
    }

    private func dayBar(_ day: (Int, String, String)) -> some View {
        let spans = BlockingSchedulePreview.spans(for: day.0, plan: plan)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.12))
                ForEach(spans.indices, id: \.self) { index in
                    let span = spans[index]
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(span.end - span.start) / 1440)
                        .offset(x: geometry.size.width * CGFloat(span.start) / 1440)
                }
            }
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.2)
        .accessibilityValue(BlockingSchedulePreview.summary(spans))
        .accessibilityIdentifier("blocking-schedule-day-\(day.0)")
        .help(BlockingSchedulePreview.summary(spans))
    }

    private func key(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 10, height: 6)
            Text(label)
        }
    }
}
