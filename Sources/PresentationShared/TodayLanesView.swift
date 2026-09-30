import SwiftUI

/// Today at a glance: one lane per Blocking Group across 24 hours, with the
/// current time marked.
///
/// The week calendar stacks every group into the same day column, so with more
/// than two or three groups the blocks overlap and nothing can be read. Lanes
/// never overlap: each group owns a row, and "what is blocked at 3 pm" is a
/// vertical line.
struct TodayLanesView: View {
    struct Lane: Identifiable, Equatable {
        var id: UUID
        var name: String
        var intervals: [BlockingInterval]
        var state: GroupNowState
    }

    let lanes: [Lane]
    let day: Date
    let now: Date
    var accent: Color = .accentColor
    var rule: Color = .secondary
    var surface: Color = .clear
    var onSelect: ((UUID) -> Void)? = nil

    private let labelWidth: CGFloat = 150
    private let laneHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.headline)
                Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Now \(now.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
            if lanes.isEmpty {
                Text("No Blocking Groups yet.")
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

    private var hourScale: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 12)
            GeometryReader { proxy in
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(hour == 24 ? "" : String(format: "%02d", hour))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .position(x: proxy.size.width * CGFloat(hour) / 24 + 8, y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    private func laneRow(_ lane: Lane) -> some View {
        Button {
            onSelect?(lane.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(shortState(lane.state))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(lane.state.isBlocking ? accent : .secondary)
                        .lineLimit(1)
                }
                .frame(width: labelWidth, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(surface)
                        Rectangle().stroke(rule.opacity(0.5), lineWidth: 1)
                        ForEach(Array(lane.intervals.enumerated()), id: \.offset) { _, interval in
                            let x0 = position(interval.start, width: proxy.size.width)
                            let x1 = position(interval.end, width: proxy.size.width)
                            Rectangle()
                                .fill(accent.opacity(lane.state == .off ? 0.25 : 0.85))
                                .frame(width: max(2, x1 - x0))
                                .offset(x: x0)
                        }
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: position(now, width: proxy.size.width) - 1)
                    }
                }
                .frame(height: laneHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name). \(GroupNowStatus.headline(lane.state, now: now))")
    }

    private func position(_ date: Date, width: CGFloat) -> CGFloat {
        let start = Calendar.current.startOfDay(for: day)
        let fraction = TodayLanesLayout.fraction(of: date, dayStart: start)
        return width * CGFloat(fraction)
    }

    private func shortState(_ state: GroupNowState) -> String {
        switch state {
        case .lockdown: "LOCKED DOWN"
        case .blocking: "BLOCKING"
        case .paused: "PAUSED"
        case .upcoming: "LATER"
        case .idle: "FREE TODAY"
        case .off: "OFF"
        }
    }
}

enum TodayLanesLayout {
    /// Position of `date` within the 24 hours after `dayStart`, clamped to 0...1.
    static func fraction(of date: Date, dayStart: Date, calendar: Calendar = .current) -> Double {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(dayStart) / total))
    }

    /// Lanes sorted the way people scan: in force first, then soonest.
    static func sorted(_ lanes: [TodayLanesView.Lane]) -> [TodayLanesView.Lane] {
        lanes.sorted {
            if $0.state.sortRank != $1.state.sortRank { return $0.state.sortRank < $1.state.sortRank }
            let a = $0.state.changesAt ?? .distantFuture, b = $1.state.changesAt ?? .distantFuture
            if a != b { return a < b }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
