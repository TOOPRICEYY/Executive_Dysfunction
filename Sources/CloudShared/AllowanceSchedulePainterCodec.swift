import Foundation

// The schedule painter's cell model and codec are shared: the iPhone editor and
// the Mac editor have to agree on exactly which half-hours a stored window
// covers. Keeping a second copy on one platform is what let an overnight window
// decode to an empty grid on the Mac while the iPhone read it correctly.

struct AllowanceScheduleCell: Hashable, Sendable {
    var weekday: Int
    var slot: Int
}

enum AllowanceSchedulePainterCodec {
    static let slotMinutes = 30
    static let slotCount = 24 * 60 / slotMinutes
    static let orderedWeekdays = [2, 3, 4, 5, 6, 7, 1]

    static var allCells: Set<AllowanceScheduleCell> {
        Set(orderedWeekdays.flatMap { weekday in
            (0..<slotCount).map { AllowanceScheduleCell(weekday: weekday, slot: $0) }
        })
    }

    /// Changing whether painted cells mean allowed or blocked should not alter
    /// the effective schedule. The visual selection therefore becomes its
    /// complement whenever the semantic mode changes.
    static func cells(
        preservingSchedule cells: Set<AllowanceScheduleCell>,
        from oldMode: CloudTimeWindowPaintMode,
        to newMode: CloudTimeWindowPaintMode
    ) -> Set<AllowanceScheduleCell> {
        oldMode == newMode ? cells : allCells.subtracting(cells)
    }

    /// A window whose end is at or before its start runs into the following
    /// weekday, and equal bounds mean the whole day -- the same reading
    /// `CloudTimeWindowPlan.effectiveBlockingSlots` and legacy `TimeWindow`
    /// enforcement use. Decoding these as an empty grid would let the editor's
    /// save write a migrated overnight block away.
    static func cells(from windows: [CloudTimeWindow]) -> Set<AllowanceScheduleCell> {
        var result: Set<AllowanceScheduleCell> = []
        for window in windows {
            for weekday in window.weekdays where (1...7).contains(weekday) {
                if window.startMinutes < window.endMinutes {
                    result.formUnion(cells(
                        weekday: weekday,
                        from: window.startMinutes,
                        to: window.endMinutes
                    ))
                } else {
                    result.formUnion(cells(
                        weekday: weekday,
                        from: window.startMinutes,
                        to: 24 * 60
                    ))
                    result.formUnion(cells(
                        weekday: nextWeekday(after: weekday),
                        from: 0,
                        to: window.endMinutes
                    ))
                }
            }
        }
        return result
    }

    static func nextWeekday(after weekday: Int) -> Int {
        weekday == 7 ? 1 : weekday + 1
    }

    private static func cells(
        weekday: Int,
        from startMinutes: Int,
        to endMinutes: Int
    ) -> Set<AllowanceScheduleCell> {
        var result: Set<AllowanceScheduleCell> = []
        for slot in 0..<slotCount {
            let start = slot * slotMinutes
            let end = start + slotMinutes
            if start < endMinutes && end > startMinutes {
                result.insert(AllowanceScheduleCell(weekday: weekday, slot: slot))
            }
        }
        return result
    }

    static func windows(from cells: Set<AllowanceScheduleCell>) -> [CloudTimeWindow] {
        struct RangeKey: Hashable {
            var startMinutes: Int
            var endMinutes: Int
        }

        var grouped: [RangeKey: Set<Int>] = [:]
        for weekday in orderedWeekdays {
            let slots = cells
                .filter { $0.weekday == weekday && (0..<slotCount).contains($0.slot) }
                .map(\.slot)
                .sorted()
            guard var start = slots.first else { continue }
            var previous = start

            for slot in slots.dropFirst() {
                if slot == previous + 1 {
                    previous = slot
                } else {
                    let key = RangeKey(
                        startMinutes: start * slotMinutes,
                        endMinutes: (previous + 1) * slotMinutes
                    )
                    grouped[key, default: []].insert(weekday)
                    start = slot
                    previous = slot
                }
            }

            let key = RangeKey(
                startMinutes: start * slotMinutes,
                endMinutes: min(24 * 60, (previous + 1) * slotMinutes)
            )
            grouped[key, default: []].insert(weekday)
        }

        return grouped.map { key, weekdays in
            CloudTimeWindow(
                weekdays: weekdays,
                startMinutes: key.startMinutes,
                endMinutes: key.endMinutes
            )
        }
        .sorted { lhs, rhs in
            lhs.startMinutes == rhs.startMinutes
                ? lhs.endMinutes < rhs.endMinutes
                : lhs.startMinutes < rhs.startMinutes
        }
    }
}
