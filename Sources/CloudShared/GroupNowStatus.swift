import Foundation

/// A span of time during which a group's schedule blocks.
struct BlockingInterval: Equatable, Sendable {
    var start: Date
    var end: Date
}

/// Turns weekly clock windows into concrete dated intervals.
///
/// Times are placed by clock components, not by elapsed minutes from
/// midnight, so a 09:00 window stays at 09:00 on daylight-saving days.
enum ScheduleTimeline {
    static func intervals(
        windows: [CloudTimeWindow],
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) -> [BlockingInterval] {
        guard from < to else { return [] }
        var raw: [BlockingInterval] = []
        let firstDay = calendar.startOfDay(for: from)
        // One day earlier catches overnight windows that started yesterday.
        var day = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        while day < to {
            let weekday = calendar.component(.weekday, from: day)
            for window in windows where window.weekdays.contains(weekday) {
                guard let start = clockDate(day, minutes: window.startMinutes, calendar: calendar) else { continue }
                let endDay = window.endMinutes > window.startMinutes
                    ? day
                    : (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
                guard let end = clockDate(endDay, minutes: window.endMinutes, calendar: calendar), end > start else { continue }
                raw.append(BlockingInterval(start: start, end: end))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return clip(merge(raw), from: from, to: to)
    }

    static func merge(_ intervals: [BlockingInterval]) -> [BlockingInterval] {
        var merged: [BlockingInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func clip(_ intervals: [BlockingInterval], from: Date, to: Date) -> [BlockingInterval] {
        intervals.compactMap {
            let start = max($0.start, from), end = min($0.end, to)
            return start < end ? BlockingInterval(start: start, end: end) : nil
        }
    }

    /// `minutes` of 1440 means the following midnight.
    private static func clockDate(_ day: Date, minutes: Int, calendar: Calendar) -> Date? {
        guard (0...1_440).contains(minutes) else { return nil }
        if minutes == 1_440 { return calendar.date(byAdding: .day, value: 1, to: day) }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }
}

/// What a Blocking Group is doing right now, in words a person can act on.
///
/// The dashboard used to say "Schedule enabled · Baseline", which answers a
/// configuration question. The question people open the app with is "is this
/// blocking right now, and until when?".
enum GroupNowState: Equatable, Sendable {
    case lockdown(until: Date)
    case paused(until: Date)
    /// `until` is nil when the block does not end within the look-ahead.
    case blocking(until: Date?)
    case upcoming(at: Date)
    case idle
    case off

    var isBlocking: Bool {
        switch self {
        case .lockdown, .blocking: true
        default: false
        }
    }

    /// Sort order for lists: what is in force first, then what comes soonest.
    var sortRank: Int {
        switch self {
        case .lockdown: 0
        case .blocking: 1
        case .paused: 2
        case .upcoming: 3
        case .idle: 4
        case .off: 5
        }
    }

    /// When this state next changes, if that is known.
    var changesAt: Date? {
        switch self {
        case let .lockdown(until), let .paused(until): until
        case let .blocking(until): until
        case let .upcoming(at): at
        case .idle, .off: nil
        }
    }
}

enum GroupNowStatus {
    static let lookAhead: TimeInterval = 8 * 86_400

    static func evaluate(
        isEnabled: Bool,
        windows: [CloudTimeWindow],
        now: Date,
        allowanceUntil: Date? = nil,
        lockdownUntil: Date? = nil,
        calendar: Calendar = .current
    ) -> GroupNowState {
        if let lockdownUntil, lockdownUntil > now { return .lockdown(until: lockdownUntil) }
        guard isEnabled else { return .off }
        let horizon = now.addingTimeInterval(lookAhead)
        let intervals = ScheduleTimeline.intervals(windows: windows, from: now, to: horizon, calendar: calendar)
        if let allowanceUntil, allowanceUntil > now {
            return .paused(until: allowanceUntil)
        }
        if let current = intervals.first(where: { $0.start <= now && now < $0.end }) {
            return .blocking(until: current.end >= horizon ? nil : current.end)
        }
        if let next = intervals.first(where: { $0.start > now }) {
            return .upcoming(at: next.start)
        }
        return .idle
    }

    static func headline(_ state: GroupNowState, now: Date, calendar: Calendar = .current) -> String {
        switch state {
        case let .lockdown(until):
            "Locked down · until \(moment(until, now: now, calendar: calendar))"
        case let .paused(until):
            "Paused · blocks again \(moment(until, now: now, calendar: calendar, preposition: true))"
        case let .blocking(until):
            until.map { "Blocking now · until \(moment($0, now: now, calendar: calendar))" } ?? "Blocking now · always on"
        case let .upcoming(at):
            "Next block · \(moment(at, now: now, calendar: calendar))"
        case .idle:
            "No blocks in the next week"
        case .off:
            "Off"
        }
    }

    /// "14:00", "tomorrow 09:00", "Fri 09:00". With `preposition`, "at 14:00".
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current, preposition: Bool = false) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return preposition ? "at \(time)" : time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(time)"
    }
}

/// One line that answers "what is happening, and what happens next?".
struct DashboardNowSummary: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        var name: String
        var state: GroupNowState
    }

    var blockingCount: Int
    var pausedCount: Int
    var nextChange: Date?
    var nextChangeDescription: String?

    init(groups: [Group]) {
        blockingCount = groups.filter { $0.state.isBlocking }.count
        pausedCount = groups.filter { if case .paused = $0.state { return true } else { return false } }.count
        let next = groups.compactMap { group -> (Date, String)? in
            guard let date = group.state.changesAt else { return nil }
            let verb: String
            switch group.state {
            case .upcoming: verb = "starts"
            case .paused: verb = "resumes"
            default: verb = "ends"
            }
            return (date, "\(group.name) \(verb)")
        }.min { $0.0 < $1.0 }
        nextChange = next?.0
        nextChangeDescription = next?.1
    }

    var headline: String {
        switch (blockingCount, pausedCount) {
        case (0, 0): "Nothing is blocked right now"
        case (0, _): "\(HoldfastPresentation.count(pausedCount, "group")) paused"
        default: "\(HoldfastPresentation.count(blockingCount, "group")) blocking now"
        }
    }

    func nextLine(now: Date, calendar: Calendar = .current) -> String? {
        guard let nextChange, let nextChangeDescription else { return nil }
        return "Next: \(nextChangeDescription) \(GroupNowStatus.moment(nextChange, now: now, calendar: calendar, preposition: true))"
    }
}
