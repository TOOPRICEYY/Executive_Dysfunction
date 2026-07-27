import XCTest
@testable import ExecutiveDysfunction

final class TimeWindowTests: XCTestCase {
    func testWeekdayWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let mondayAtNoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 12
        )))
        let window = TimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)
        XCTAssertTrue(window.isActive(at: mondayAtNoon, calendar: calendar))
    }

    func testOvernightWindowIncludesFollowingMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let tuesdayAtOne = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 1
        )))
        let window = TimeWindow(weekdays: [2], startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(window.isActive(at: tuesdayAtOne, calendar: calendar))
    }

    func testOvernightOccurrenceIsPerStartWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let window = TimeWindow(weekdays: [2, 3], startMinutes: 22 * 60, endMinutes: 7 * 60)

        // Tuesday 01:00 belongs to Monday's occurrence, not Tuesday's.
        let tuesdayAtOne = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 1
        )))
        XCTAssertTrue(window.occurrenceIsActive(startingOn: 2, at: tuesdayAtOne, calendar: calendar))
        XCTAssertFalse(window.occurrenceIsActive(startingOn: 3, at: tuesdayAtOne, calendar: calendar))

        // Tuesday 13:00 is outside every occurrence.
        let tuesdayAfternoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 13
        )))
        XCTAssertFalse(window.isActive(at: tuesdayAfternoon, calendar: calendar))
        XCTAssertFalse(window.occurrenceIsActive(startingOn: 2, at: tuesdayAfternoon, calendar: calendar))
        XCTAssertFalse(window.occurrenceIsActive(startingOn: 3, at: tuesdayAfternoon, calendar: calendar))

        // Tuesday 23:00 belongs to Tuesday's occurrence.
        let tuesdayNight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 14, hour: 23
        )))
        XCTAssertFalse(window.occurrenceIsActive(startingOn: 2, at: tuesdayNight, calendar: calendar))
        XCTAssertTrue(window.occurrenceIsActive(startingOn: 3, at: tuesdayNight, calendar: calendar))
    }

    func testAllDayWindowWrapsSaturdayIntoSunday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        // Equal start and end means a 24-hour window; Saturday (7) wraps into Sunday (1).
        let window = TimeWindow(weekdays: [7], startMinutes: 9 * 60, endMinutes: 9 * 60)
        let sundayMorning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 19, hour: 8
        )))
        XCTAssertTrue(window.occurrenceIsActive(startingOn: 7, at: sundayMorning, calendar: calendar))
        XCTAssertTrue(window.isActive(at: sundayMorning, calendar: calendar))

        let sundayAfternoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 19, hour: 10
        )))
        XCTAssertFalse(window.isActive(at: sundayAfternoon, calendar: calendar))
    }

    func testSchedulerUsesOneActivityPerWindowInsteadOfOnePerWeekday() {
        var rule = BlockingRule()
        rule.windows = [TimeWindow(weekdays: Set(1...7), startMinutes: 9 * 60, endMinutes: 17 * 60)]
        XCTAssertEqual(RuleScheduler.requiredActivityCount(for: [rule]), 1)
    }

    func testAllUsageLimitsShareOneActivity() {
        var first = BlockingRule()
        first.windows = []
        first.usageLimitEnabled = true
        var second = BlockingRule()
        second.windows = []
        second.usageLimitEnabled = true
        XCTAssertEqual(RuleScheduler.requiredActivityCount(for: [first, second]), 1)
    }

    func testWindowAndUsageActivityCount() {
        var rule = BlockingRule()
        rule.windows = [TimeWindow(), TimeWindow()]
        rule.usageLimitEnabled = true
        XCTAssertEqual(RuleScheduler.requiredActivityCount(for: [rule]), 3)
    }

    func testAllowanceMonitorDescriptorRoundTrips() {
        let id = UUID()
        let descriptor = MonitorDescriptor.allowance(ruleID: id)
        XCTAssertEqual(MonitorDescriptor.parse(descriptor.activityName), descriptor)
    }
}
