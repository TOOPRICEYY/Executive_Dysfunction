import Foundation

/// Pure layout for the schedule lanes: one row per group, one day at a time.
enum ScheduleLanes {
    struct Lane: Identifiable, Equatable, Sendable {
        var id: UUID
        var name: String
        var intervals: [BlockingInterval]
        /// Present for today only; other days have no "now".
        var state: GroupNowState?

        var blockedMinutes: Int {
            intervals.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
        }
    }

    /// When a calendar rule blocks between `from` and `to`: its weekly
    /// schedule while enabled (clipped to a Retreat's run when it has one),
    /// plus any lockdown that holds it regardless of schedule.
    static func intervals(
        for entry: BlockStatusCalendarRule,
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) -> [BlockingInterval] {
        var start = from, end = to
        if let run = entry.enforcementInterval {
            start = max(start, run.start)
            end = min(end, run.end)
        }
        var result: [BlockingInterval] = []
        if entry.rule.isEnabled, start < end {
            result += ScheduleTimeline.intervals(windows: entry.rule.windows, from: start, to: end, calendar: calendar)
        }
        for forced in entry.forcedIntervals {
            let s = max(forced.start, from), e = min(forced.end, to)
            if s < e { result.append(BlockingInterval(start: s, end: e)) }
        }
        return ScheduleTimeline.merge(result)
    }

    /// Lanes for the day containing `day`. `states` supplies today's live state.
    static func lanes(
        for rules: [BlockStatusCalendarRule],
        day: Date,
        now: Date,
        states: [UUID: GroupNowState] = [:],
        calendar: Calendar = .current
    ) -> [Lane] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? day
        let isToday = calendar.isDate(day, inSameDayAs: now)
        var seen = Set<UUID>()
        let lanes = rules.compactMap { entry -> Lane? in
            guard seen.insert(entry.rule.id).inserted else { return nil }
            return Lane(
                id: entry.rule.id,
                name: entry.rule.name,
                intervals: intervals(for: entry, from: dayStart, to: dayEnd, calendar: calendar),
                state: isToday ? states[entry.rule.id] : nil
            )
        }
        return sorted(lanes)
    }

    /// Today: in force first, then soonest change. Other days: earliest block
    /// first, free groups last.
    static func sorted(_ lanes: [Lane]) -> [Lane] {
        lanes.sorted { a, b in
            if let sa = a.state, let sb = b.state {
                if sa.sortRank != sb.sortRank { return sa.sortRank < sb.sortRank }
                let x = sa.changesAt ?? .distantFuture, y = sb.changesAt ?? .distantFuture
                if x != y { return x < y }
            } else {
                let x = a.intervals.first?.start ?? .distantFuture
                let y = b.intervals.first?.start ?? .distantFuture
                if x != y { return x < y }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Position of `date` within the 24 hours after `dayStart`, clamped to 0...1.
    static func fraction(of date: Date, dayStart: Date, calendar: Calendar = .current) -> Double {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let total = dayEnd.timeIntervalSince(dayStart)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(dayStart) / total))
    }

    /// "5h 30m", "45m", or "Free".
    static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "Free" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
