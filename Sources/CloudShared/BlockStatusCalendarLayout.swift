import Foundation

/// A Blocking Group as displayed on the dashboard calendar. Retreat-backed
/// groups carry their planned enforcement interval so recurring windows are
/// not painted before a Retreat begins or after it ends.
struct BlockStatusCalendarRule: Equatable {
    let rule: CloudRulePreference
    let enforcementInterval: DateInterval?
    let forcedIntervals: [DateInterval]

    init(rule: CloudRulePreference, enforcementInterval: DateInterval? = nil, forcedIntervals: [DateInterval] = []) {
        self.rule = rule
        self.enforcementInterval = enforcementInterval
        self.forcedIntervals = forcedIntervals
    }

    /// Keep the saved schedule intact. Lockdowns add coverage even for disabled
    /// groups and outside a retreat's lifetime.
    static func applyingLockdowns(
        to scheduled: [Self], rules: [CloudRulePreference], intervals: [UUID: [DateInterval]]
    ) -> [Self] {
        let known = Set(scheduled.map { $0.rule.id })
        let all = scheduled + rules.filter { !known.contains($0.id) && intervals[$0.id] != nil }.map { Self(rule: $0) }
        return all.map { Self(rule: $0.rule, enforcementInterval: $0.enforcementInterval, forcedIntervals: intervals[$0.rule.id] ?? []) }
    }
}

struct BlockStatusCalendarSnapshot: Equatable {
    struct Day: Equatable, Identifiable {
        let date: Date
        let events: [Event]

        var id: Date { date }
    }

    struct Event: Equatable, Identifiable {
        struct ID: Hashable {
            let date: Date
            let ruleID: UUID
            let colorIndex: Int
            let startMinute: Int
            let endMinute: Int
        }

        let date: Date
        let ruleID: UUID
        let ruleName: String
        let colorIndex: Int
        let startMinute: Int
        let endMinute: Int
        let lane: Int
        let laneCount: Int

        var id: ID {
            ID(
                date: date,
                ruleID: ruleID,
                colorIndex: colorIndex,
                startMinute: startMinute,
                endMinute: endMinute
            )
        }

        var durationMinutes: Int { endMinute - startMinute }
    }

    let days: [Day]
    let totalMinutesByRuleID: [UUID: Int]

    static let empty = Self(days: [], totalMinutesByRuleID: [:])
}

struct BlockStatusCalendarEventGeometry: Equatable {
    let x: Double
    let width: Double

    static func stacked(
        dayWidth: Double,
        lane: Int,
        laneCount: Int,
        horizontalInset: Double
    ) -> Self {
        let usableWidth = max(2, dayWidth - horizontalInset * 2)
        let normalizedLaneCount = max(1, laneCount)
        let cascadeWidth = normalizedLaneCount > 1
            ? min(20, usableWidth * 0.18)
            : 0
        let step = normalizedLaneCount > 1
            ? cascadeWidth / Double(normalizedLaneCount - 1)
            : 0
        let normalizedLane = min(max(0, lane), normalizedLaneCount - 1)

        return Self(
            x: horizontalInset + Double(normalizedLane) * step,
            width: max(2, usableWidth - cascadeWidth)
        )
    }
}

private struct BlockStatusMinHeap<Element> {
    private var values: [Element] = []
    private let orderedBefore: (Element, Element) -> Bool

    init(orderedBefore: @escaping (Element, Element) -> Bool) {
        self.orderedBefore = orderedBefore
    }

    var first: Element? { values.first }

    mutating func insert(_ value: Element) {
        values.append(value)
        var child = values.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard orderedBefore(values[child], values[parent]) else { break }
            values.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeFirst() -> Element? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]
        values[0] = values.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < values.count else { break }
            let right = left + 1
            let child = right < values.count && orderedBefore(values[right], values[left])
                ? right
                : left
            guard orderedBefore(values[child], values[parent]) else { break }
            values.swapAt(parent, child)
            parent = child
        }
        return result
    }
}

enum BlockStatusCalendarLayout {
    private struct Interval {
        let start: Int
        let end: Int
    }

    private struct UnplacedEvent {
        let date: Date
        let ruleID: UUID
        let ruleName: String
        let colorIndex: Int
        let startMinute: Int
        let endMinute: Int
    }

    static func makeSnapshot(
        rules: [CloudRulePreference],
        dates: [Date],
        calendar: Calendar
    ) -> BlockStatusCalendarSnapshot {
        makeSnapshot(
            calendarRules: rules.map { BlockStatusCalendarRule(rule: $0) },
            dates: dates,
            calendar: calendar
        )
    }

    static func makeSnapshot(
        calendarRules: [BlockStatusCalendarRule],
        dates: [Date],
        calendar: Calendar
    ) -> BlockStatusCalendarSnapshot {
        var totals: [UUID: Int] = [:]
        let days = dates.map { date in
            var unplaced: [UnplacedEvent] = []
            for (colorIndex, calendarRule) in calendarRules.enumerated() {
                let rule = calendarRule.rule
                for interval in blockingIntervals(for: calendarRule, on: date, calendar: calendar) {
                    totals[rule.id, default: 0] += interval.end - interval.start
                    unplaced.append(UnplacedEvent(
                        date: date,
                        ruleID: rule.id,
                        ruleName: rule.name,
                        colorIndex: colorIndex,
                        startMinute: interval.start,
                        endMinute: interval.end
                    ))
                }
            }
            return BlockStatusCalendarSnapshot.Day(
                date: date,
                events: placeInOverlapLanes(unplaced)
            )
        }
        return BlockStatusCalendarSnapshot(days: days, totalMinutesByRuleID: totals)
    }

    private static func blockingIntervals(
        for calendarRule: BlockStatusCalendarRule,
        on date: Date,
        calendar: Calendar
    ) -> [Interval] {
        let rule = calendarRule.rule
        let weekday = calendar.component(.weekday, from: date)
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        var values: [Interval] = []

        for window in rule.isEnabled ? rule.windows : [] {
            if window.startMinutes < window.endMinutes {
                if window.weekdays.contains(weekday) {
                    values.append(Interval(start: window.startMinutes, end: window.endMinutes))
                }
            } else {
                if window.weekdays.contains(weekday), window.startMinutes < 1_440 {
                    values.append(Interval(start: window.startMinutes, end: 1_440))
                }
                if window.weekdays.contains(previousWeekday), window.endMinutes > 0 {
                    values.append(Interval(start: 0, end: window.endMinutes))
                }
            }
        }
        if let enforcementInterval = calendarRule.enforcementInterval {
            values = clip(values, to: enforcementInterval, on: date, calendar: calendar)
        }
        for interval in calendarRule.forcedIntervals {
            values += clip([Interval(start: 0, end: 1_440)], to: interval, on: date, calendar: calendar)
        }
        return merge(values)
    }

    private static func clip(
        _ values: [Interval],
        to enforcementInterval: DateInterval,
        on date: Date,
        calendar: Calendar
    ) -> [Interval] {
        let dayStart = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let dayInterval = DateInterval(start: dayStart, end: nextDay).intersection(with: enforcementInterval)
        else { return [] }

        let lower = minuteOffset(of: dayInterval.start, from: dayStart, calendar: calendar)
        let upper = dayInterval.end == nextDay
            ? 1_440
            : minuteOffset(of: dayInterval.end, from: dayStart, calendar: calendar)
        return values.compactMap { value in
            let start = max(value.start, lower)
            let end = min(value.end, upper)
            return start < end ? Interval(start: start, end: end) : nil
        }
    }

    private static func minuteOffset(of date: Date, from dayStart: Date, calendar: Calendar) -> Int {
        // The grid represents wall-clock labels. Elapsed hours from midnight
        // shift all Retreat edges by an hour on daylight-saving change days.
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return max(0, min(1_440, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private static func merge(_ values: [Interval]) -> [Interval] {
        let sorted = values.compactMap { value -> Interval? in
            let start = max(0, min(1_440, value.start))
            let end = max(0, min(1_440, value.end))
            return start < end ? Interval(start: start, end: end) : nil
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        guard var current = sorted.first else { return [] }
        var result: [Interval] = []
        for value in sorted.dropFirst() {
            if value.start <= current.end {
                current = Interval(start: current.start, end: max(current.end, value.end))
            } else {
                result.append(current)
                current = value
            }
        }
        result.append(current)
        return result
    }

    private static func placeInOverlapLanes(
        _ source: [UnplacedEvent]
    ) -> [BlockStatusCalendarSnapshot.Event] {
        let sorted = source.sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            if lhs.endMinute != rhs.endMinute { return lhs.endMinute > rhs.endMinute }
            if lhs.colorIndex != rhs.colorIndex { return lhs.colorIndex < rhs.colorIndex }
            return lhs.ruleID.uuidString < rhs.ruleID.uuidString
        }

        var result: [BlockStatusCalendarSnapshot.Event] = []
        var cluster: [UnplacedEvent] = []
        var clusterEnd = -1

        func appendCluster(_ values: [UnplacedEvent]) {
            guard !values.isEmpty else { return }
            struct ActiveLane {
                let endMinute: Int
                let lane: Int
            }
            var active = BlockStatusMinHeap<ActiveLane> { lhs, rhs in
                lhs.endMinute == rhs.endMinute
                    ? lhs.lane < rhs.lane
                    : lhs.endMinute < rhs.endMinute
            }
            var available = BlockStatusMinHeap<Int>(orderedBefore: <)
            var nextLane = 0
            var assignments: [(event: UnplacedEvent, lane: Int)] = []

            for event in values {
                while let earliest = active.first,
                      earliest.endMinute <= event.startMinute {
                    _ = active.removeFirst()
                    available.insert(earliest.lane)
                }
                let lane: Int
                if let reusable = available.removeFirst() {
                    lane = reusable
                } else {
                    lane = nextLane
                    nextLane += 1
                }
                active.insert(ActiveLane(endMinute: event.endMinute, lane: lane))
                assignments.append((event, lane))
            }

            let laneCount = max(1, nextLane)
            result.append(contentsOf: assignments.map { assignment in
                let event = assignment.event
                return BlockStatusCalendarSnapshot.Event(
                    date: event.date,
                    ruleID: event.ruleID,
                    ruleName: event.ruleName,
                    colorIndex: event.colorIndex,
                    startMinute: event.startMinute,
                    endMinute: event.endMinute,
                    lane: assignment.lane,
                    laneCount: laneCount
                )
            })
        }

        for event in sorted {
            if cluster.isEmpty || event.startMinute < clusterEnd {
                cluster.append(event)
                clusterEnd = max(clusterEnd, event.endMinute)
            } else {
                appendCluster(cluster)
                cluster = [event]
                clusterEnd = event.endMinute
            }
        }
        appendCluster(cluster)
        return result
    }
}
