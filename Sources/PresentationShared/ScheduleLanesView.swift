import SwiftUI

/// The schedule, one lane per Blocking Group across 24 hours, one day at a
/// time. Replaces the week grid, which stacked every group into the same day
/// column until the blocks overlapped and nothing could be read.
///
/// Lanes never overlap: each group owns a row, and "what is blocked at 3 pm"
/// is a vertical line. A strip of the next seven days gives the week view.
struct ScheduleLanesView: View {
    let calendarRules: [BlockStatusCalendarRule]
    let now: Date
    var states: [UUID: GroupNowState] = [:]
    var accent: Color = .accentColor
    /// Text-safe version of the accent (bright fills can be unreadable as text).
    var ink: Color? = nil
    var rule: Color = .secondary
    var surface: Color = .clear
    var labelWidth: CGFloat = 150
    var onSelect: ((UUID) -> Void)? = nil

    @State private var dayOffset = 0

    private let laneHeight: CGFloat = 22
    private var calendar: Calendar { .current }

    private var selectedDay: Date {
        calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
    }

    private var isToday: Bool { dayOffset == 0 }

    var body: some View {
        let lanes = ScheduleLanes.lanes(for: calendarRules, day: selectedDay, now: now, states: states)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Schedule").font(.headline)
                Spacer()
                if isToday {
                    Text("Now \(now.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ink ?? accent)
                } else {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            dayStrip
            if lanes.isEmpty {
                Text("Enable a Blocking Group to see its schedule here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                hourScale
                ForEach(lanes) { lane in
                    laneRow(lane)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { offset in
                    let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
                    let selected = offset == dayOffset
                    Button {
                        dayOffset = offset
                    } label: {
                        VStack(spacing: 1) {
                            Text(offset == 0 ? "TODAY" : date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Text(date.formatted(.dateTime.day()))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(minWidth: 44, minHeight: 36)
                        .padding(.horizontal, 4)
                        .foregroundStyle(selected ? Color.black : Color.primary)
                        .background(selected ? accent : surface)
                        .overlay { Rectangle().stroke(rule, lineWidth: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide).month().day()))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var hourScale: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 12)
            GeometryReader { proxy in
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .position(x: proxy.size.width * CGFloat(hour) / 24 + 8, y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    private func laneRow(_ lane: ScheduleLanes.Lane) -> some View {
        Button {
            onSelect?(lane.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(lane))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(lane.state?.isBlocking == true ? (ink ?? accent) : .secondary)
                        .lineLimit(1)
                }
                .frame(width: labelWidth, alignment: .leading)
                GeometryReader { proxy in
                    let dayStart = calendar.startOfDay(for: selectedDay)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(surface)
                        Rectangle().stroke(rule.opacity(0.5), lineWidth: 1)
                        ForEach(Array(lane.intervals.enumerated()), id: \.offset) { _, interval in
                            let x0 = proxy.size.width * ScheduleLanes.fraction(of: interval.start, dayStart: dayStart)
                            let x1 = proxy.size.width * ScheduleLanes.fraction(of: interval.end, dayStart: dayStart)
                            Rectangle()
                                .fill(accent.opacity(0.85))
                                .frame(width: max(2, x1 - x0))
                                .offset(x: x0)
                        }
                        if isToday {
                            Rectangle()
                                .fill(Color.primary)
                                .frame(width: 2)
                                .offset(x: proxy.size.width * ScheduleLanes.fraction(of: now, dayStart: dayStart) - 1)
                        }
                    }
                }
                .frame(height: laneHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name). \(accessibilitySummary(lane))")
    }

    private func subtitle(_ lane: ScheduleLanes.Lane) -> String {
        if let state = lane.state {
            switch state {
            case .lockdown: return "LOCKED DOWN"
            case .blocking: return "BLOCKING"
            case .paused: return "PAUSED"
            case let .upcoming(at): return calendar.isDate(at, inSameDayAs: now) ? "LATER TODAY" : "NOT TODAY"
            case .idle: return "FREE TODAY"
            case .off: return "OFF"
            }
        }
        return ScheduleLanes.duration(minutes: lane.blockedMinutes).uppercased()
    }

    private func accessibilitySummary(_ lane: ScheduleLanes.Lane) -> String {
        if let state = lane.state { return GroupNowStatus.headline(state, now: now) }
        return lane.intervals.isEmpty
            ? "Free"
            : lane.intervals.map {
                "\($0.start.formatted(date: .omitted, time: .shortened)) to \($0.end.formatted(date: .omitted, time: .shortened))"
            }.joined(separator: ", ")
    }
}
