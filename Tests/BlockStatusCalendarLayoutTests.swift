import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class BlockStatusCalendarLayoutTests: XCTestCase {
    func testLockdownOverridesDisabledScheduleAndRetreatBoundsAcrossMidnight() {
        var disabled = rule("Held", start: 9 * 60, end: 10 * 60)
        disabled.isEnabled = false
        let start = monday.addingTimeInterval(23 * 3_600)
        let end = monday.addingTimeInterval(26 * 3_600)
        let entry = BlockStatusCalendarRule(rule: disabled,
            enforcementInterval: DateInterval(start: monday.addingTimeInterval(-86_400), end: monday),
            forcedIntervals: [DateInterval(start: start, end: end)])
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(calendarRules: [entry],
            dates: [monday, monday.addingTimeInterval(86_400), monday.addingTimeInterval(172_800)], calendar: calendar)
        XCTAssertEqual(snapshot.days[0].events.first?.startMinute, 23 * 60)
        XCTAssertEqual(snapshot.days[0].events.first?.endMinute, 1_440)
        XCTAssertEqual(snapshot.days[1].events.first?.startMinute, 0)
        XCTAssertEqual(snapshot.days[1].events.first?.endMinute, 120)
        XCTAssertTrue(snapshot.days[2].events.isEmpty)
        XCTAssertEqual(snapshot.totalMinutesByRuleID[disabled.id], 180)
    }

    func testOverlappingLockdownsAndSavedWindowsMergeWithoutDoubleCounting() {
        let item = rule("Held", start: 9 * 60, end: 10 * 60)
        let entries = BlockStatusCalendarRule.applyingLockdowns(to: [BlockStatusCalendarRule(rule: item)], rules: [item],
            intervals: [item.id: [DateInterval(start: monday.addingTimeInterval(8 * 3_600), end: monday.addingTimeInterval(11 * 3_600)),
                                DateInterval(start: monday.addingTimeInterval(10 * 3_600), end: monday.addingTimeInterval(12 * 3_600))]])
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(calendarRules: entries, dates: [monday], calendar: calendar)
        XCTAssertEqual(snapshot.days[0].events.count, 1)
        XCTAssertEqual(snapshot.totalMinutesByRuleID[item.id], 240)
        XCTAssertEqual(entries[0].rule.windows, item.windows)
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var monday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!
    }

    func testSimultaneousEventsArePackedIntoSideBySideLanes() {
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: [
                rule("A", start: 9 * 60, end: 12 * 60),
                rule("B", start: 10 * 60, end: 11 * 60),
                rule("C", start: 10 * 60 + 30, end: 13 * 60)
            ],
            dates: [monday],
            calendar: calendar
        )

        let events = snapshot.days[0].events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.lane)), [0, 1, 2])
        XCTAssertEqual(Set(events.map(\.laneCount)), [3])
    }

    func testChainedOverlapReusesTheFirstAvailableLane() {
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: [
                rule("A", start: 9 * 60, end: 11 * 60),
                rule("B", start: 10 * 60, end: 12 * 60),
                rule("C", start: 11 * 60, end: 13 * 60)
            ],
            dates: [monday],
            calendar: calendar
        )

        let events = snapshot.days[0].events
        XCTAssertEqual(events.map(\.lane), [0, 1, 0])
        XCTAssertEqual(Set(events.map(\.laneCount)), [2])
    }

    func testTouchingEventsDoNotConsumeOverlapLanes() {
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: [
                rule("A", start: 9 * 60, end: 10 * 60),
                rule("B", start: 10 * 60, end: 11 * 60)
            ],
            dates: [monday],
            calendar: calendar
        )

        XCTAssertEqual(snapshot.days[0].events.map(\.lane), [0, 0])
        XCTAssertEqual(snapshot.days[0].events.map(\.laneCount), [1, 1])
    }

    func testOvernightWindowSplitsAcrossAdjacentDays() {
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        var overnight = rule("Overnight", start: 22 * 60, end: 2 * 60)
        overnight.windows[0].weekdays = [2]

        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: [overnight],
            dates: [monday, tuesday],
            calendar: calendar
        )

        XCTAssertEqual(snapshot.days[0].events.map(\.startMinute), [22 * 60])
        XCTAssertEqual(snapshot.days[0].events.map(\.endMinute), [1_440])
        XCTAssertEqual(snapshot.days[1].events.map(\.startMinute), [0])
        XCTAssertEqual(snapshot.days[1].events.map(\.endMinute), [2 * 60])
        XCTAssertEqual(snapshot.totalMinutesByRuleID[overnight.id], 4 * 60)
    }

    func testRetreatIntervalClipsRecurringWindowsToItsActualEnforcementTimeframe() {
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        var retreatRule = rule("Retreat", start: 9 * 60, end: 17 * 60)
        retreatRule.windows[0].weekdays = [2, 3]
        let retreatStart = calendar.date(byAdding: .minute, value: 12 * 60, to: monday)!
        let retreatEnd = calendar.date(byAdding: .minute, value: 11 * 60, to: tuesday)!

        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            calendarRules: [BlockStatusCalendarRule(
                rule: retreatRule,
                enforcementInterval: DateInterval(start: retreatStart, end: retreatEnd)
            )],
            dates: [monday, tuesday],
            calendar: calendar
        )

        XCTAssertEqual(snapshot.days[0].events.map(\.startMinute), [12 * 60])
        XCTAssertEqual(snapshot.days[0].events.map(\.endMinute), [17 * 60])
        XCTAssertEqual(snapshot.days[1].events.map(\.startMinute), [9 * 60])
        XCTAssertEqual(snapshot.days[1].events.map(\.endMinute), [11 * 60])
        XCTAssertEqual(snapshot.totalMinutesByRuleID[retreatRule.id], 7 * 60)
    }

    func testManySimultaneousGroupsUseOneCalendarWithDeterministicLanes() {
        let rules = (0..<100).map { index in
            rule("Group \(index)", start: 9 * 60, end: 17 * 60)
        }

        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: rules,
            dates: [monday],
            calendar: calendar
        )

        let events = snapshot.days[0].events
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.map(\.lane), Array(0..<100))
        XCTAssertEqual(Set(events.map(\.laneCount)), [100])
        XCTAssertEqual(snapshot.totalMinutesByRuleID.count, 100)
    }

    func testDuplicateSyncedRuleIdentifiersStillProduceDistinctViewEvents() {
        let id = UUID()
        var first = rule("First", start: 9 * 60, end: 10 * 60)
        first.id = id
        var second = rule("Second", start: 9 * 60, end: 10 * 60)
        second.id = id

        let snapshot = BlockStatusCalendarLayout.makeSnapshot(
            rules: [first, second],
            dates: [monday],
            calendar: calendar
        )

        XCTAssertEqual(snapshot.days[0].events.count, 2)
        XCTAssertEqual(Set(snapshot.days[0].events.map(\.id)).count, 2)
    }

    func testOverlappingGroupsStackAtNearlyFullDayWidth() {
        let geometries = (0..<3).map { lane in
            BlockStatusCalendarEventGeometry.stacked(
                dayWidth: 146,
                lane: lane,
                laneCount: 3,
                horizontalInset: 4
            )
        }

        XCTAssertEqual(Set(geometries.map(\.width)).count, 1)
        XCTAssertGreaterThan(geometries[0].width, 110)
        XCTAssertLessThan(geometries[0].x, geometries[1].x)
        XCTAssertLessThan(geometries[1].x, geometries[2].x)
        XCTAssertLessThanOrEqual(geometries[2].x + geometries[2].width, 142)
    }

    func testHundredOverlapsRemainStackedInsideOneDayColumn() {
        let first = BlockStatusCalendarEventGeometry.stacked(
            dayWidth: 64,
            lane: 0,
            laneCount: 100,
            horizontalInset: 3
        )
        let last = BlockStatusCalendarEventGeometry.stacked(
            dayWidth: 64,
            lane: 99,
            laneCount: 100,
            horizontalInset: 3
        )

        XCTAssertEqual(first.width, last.width)
        XCTAssertGreaterThan(first.width, 45)
        XCTAssertLessThanOrEqual(last.x + last.width, 61)
    }

    private func rule(_ name: String, start: Int, end: Int) -> CloudRulePreference {
        CloudRulePreference(
            name: name,
            windows: [CloudTimeWindow(weekdays: [2], startMinutes: start, endMinutes: end)]
        )
    }

    func testRetreatEdgesUseLocalClockOnBothDaylightSavingTransitions() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for (month, day) in [(3, 8), (11, 1)] {
            let start = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9)))
            let end = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 17)))
            var subject = rule("Retreat", start: 0, end: 1_440)
            subject.windows[0].weekdays = [1]
            let snapshot = BlockStatusCalendarLayout.makeSnapshot(
                calendarRules: [.init(rule: subject, enforcementInterval: DateInterval(start: start, end: end))],
                dates: [local.startOfDay(for: start)], calendar: local
            )
            XCTAssertEqual(snapshot.days[0].events.map(\.startMinute), [540])
            XCTAssertEqual(snapshot.days[0].events.map(\.endMinute), [1_020])
        }
    }

    func testRetreatIntervalIsPartOfSnapshotInputEvenWhenRulesAreUnchanged() {
        let subject = rule("Retreat", start: 0, end: 1_440)
        let first = BlockStatusCalendarRule(rule: subject, enforcementInterval: DateInterval(
            start: monday.addingTimeInterval(9 * 3_600), end: monday.addingTimeInterval(12 * 3_600)
        ))
        let edited = BlockStatusCalendarRule(rule: subject, enforcementInterval: DateInterval(
            start: monday.addingTimeInterval(10 * 3_600), end: monday.addingTimeInterval(14 * 3_600)
        ))
        XCTAssertEqual(first.rule, edited.rule)
        XCTAssertNotEqual(first, edited)
        let before = BlockStatusCalendarLayout.makeSnapshot(calendarRules: [first], dates: [monday], calendar: calendar)
        let after = BlockStatusCalendarLayout.makeSnapshot(calendarRules: [edited], dates: [monday], calendar: calendar)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.days[0].events.map(\.startMinute), [600])
        XCTAssertEqual(after.days[0].events.map(\.endMinute), [840])
    }

    func testDisabledRuleDoesNotPaintCalendarOrContributeHours() {
        var disabled = rule("Disabled", start: 540, end: 1_020)
        disabled.isEnabled = false
        let snapshot = BlockStatusCalendarLayout.makeSnapshot(rules: [disabled], dates: [monday], calendar: calendar)
        XCTAssertTrue(snapshot.days[0].events.isEmpty)
        XCTAssertTrue(snapshot.totalMinutesByRuleID.isEmpty)
    }
}
