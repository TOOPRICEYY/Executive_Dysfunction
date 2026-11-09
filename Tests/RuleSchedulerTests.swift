import XCTest
@testable import Holdfast

final class RuleSchedulerTests: XCTestCase {
    func testRejectedExpiryMonitorCancelsOnlyItsPauseAndDoesNotAuthorizeSuspension() {
        enum Rejected: Error { case interval }
        let allowances = (0..<3).map { _ in RuleTimeAllowance(
            ruleID: UUID(), expiresAt: Date().addingTimeInterval(600),
            totalMinutesGranted: 10, grantCount: 1, restoreUsageShield: true
        ) }
        var attempted: [UUID] = []
        var cancelled: [UUID] = []
        let admitted = RuleScheduler.registerAllowances(allowances, startMonitoring: {
            attempted.append($0.ruleID)
            if $0.ruleID == allowances[1].ruleID { throw Rejected.interval }
        }, cancel: { allowance, _ in cancelled.append(allowance.ruleID) })
        XCTAssertEqual(attempted, allowances.map(\.ruleID))
        XCTAssertEqual(cancelled, [allowances[1].ruleID])
        XCTAssertEqual(admitted.map(\.ruleID), [allowances[0].ruleID, allowances[2].ruleID])
    }
    func testPortableEndOfDayBoundaryNeverEmitsHourTwentyFour() {
        let boundary = RuleScheduler.deviceActivityBoundary(minutes: 1_440, isEnd: true)

        XCTAssertEqual(boundary.hour, 23)
        XCTAssertEqual(boundary.minute, 59)
        XCTAssertEqual(boundary.second, 59)
    }

    func testHalfHourBoundaryRemainsExact() {
        let boundary = RuleScheduler.deviceActivityBoundary(minutes: 18 * 60 + 30, isEnd: true)

        XCTAssertEqual(boundary.hour, 18)
        XCTAssertEqual(boundary.minute, 30)
        XCTAssertEqual(boundary.second, 0)
    }

    func testStartBoundaryIsClampedBelowPortableEndOfDaySentinel() {
        let boundary = RuleScheduler.deviceActivityBoundary(minutes: 1_440, isEnd: false)

        XCTAssertEqual(boundary.hour, 23)
        XCTAssertEqual(boundary.minute, 59)
        XCTAssertEqual(boundary.second, 0)
    }
}

extension RuleSchedulerTests {
    private func rule(windows: [TimeWindow], isEnabled: Bool = true) -> BlockingRule {
        var rule = BlockingRule()
        rule.isEnabled = isEnabled
        rule.windows = windows
        return rule
    }

    private func wednesdayAt(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components)
        XCTAssertNotNil(date)
        XCTAssertEqual(Calendar.current.component(.weekday, from: date ?? Date()), 4, "Expected a Wednesday")
        return date ?? Date()
    }

    /// The monitor's `intervalDidEnd` is the only thing that lifts a time block
    /// shield. A window Screen Time had no monitor slot for would otherwise be
    /// shielded with nothing left to release it, and the block would outstay its
    /// schedule until the app was next opened by hand.
    func testWindowWithoutAMonitorIsNeverShielded() {
        let window = TimeWindow(weekdays: [4], startMinutes: 9 * 60, endMinutes: 17 * 60)
        let subject = rule(windows: [window])

        XCTAssertFalse(RuleScheduler.shouldShieldWindow(
            rule: subject,
            window: window,
            hasMonitor: false,
            isSuspended: false,
            now: wednesdayAt(12)
        ))
    }

    func testActiveWindowWithAMonitorIsShielded() {
        let window = TimeWindow(weekdays: [4], startMinutes: 9 * 60, endMinutes: 17 * 60)
        let subject = rule(windows: [window])

        XCTAssertTrue(RuleScheduler.shouldShieldWindow(
            rule: subject,
            window: window,
            hasMonitor: true,
            isSuspended: false,
            now: wednesdayAt(12)
        ))
    }

    func testWindowOutsideItsHoursIsNotShieldedEvenWithAMonitor() {
        let window = TimeWindow(weekdays: [4], startMinutes: 9 * 60, endMinutes: 17 * 60)
        let subject = rule(windows: [window])

        XCTAssertFalse(RuleScheduler.shouldShieldWindow(
            rule: subject,
            window: window,
            hasMonitor: true,
            isSuspended: false,
            now: wednesdayAt(17)
        ))
    }

    func testSuspendedAndDisabledRulesAreNotShielded() {
        let window = TimeWindow(weekdays: [4], startMinutes: 9 * 60, endMinutes: 17 * 60)
        let noon = wednesdayAt(12)

        XCTAssertFalse(RuleScheduler.shouldShieldWindow(
            rule: rule(windows: [window]),
            window: window,
            hasMonitor: true,
            isSuspended: true,
            now: noon
        ))
        XCTAssertFalse(RuleScheduler.shouldShieldWindow(
            rule: rule(windows: [window], isEnabled: false),
            window: window,
            hasMonitor: true,
            isSuspended: false,
            now: noon
        ))
    }

    /// The capacity plan is what decides a window goes unmonitored, so the two
    /// have to agree: everything past the budget must fall on the unshielded
    /// side rather than becoming a block that cannot be released.
    func testWindowsBeyondTheMonitorBudgetAreLeftUnshielded() {
        let windows = (0..<25).map { _ in
            TimeWindow(weekdays: [4], startMinutes: 9 * 60, endMinutes: 17 * 60)
        }
        let subject = rule(windows: windows)
        let plan = ActivityMonitorCapacityPlan(
            maximumActivities: RuleScheduler.maximumConcurrentActivities,
            occupiedActivities: 0,
            allowanceCount: 0,
            needsUsageActivity: false,
            windowCount: windows.count
        )
        let monitored = Set(windows.prefix(plan.scheduledWindowCount).map(\.id))
        let noon = wednesdayAt(12)

        XCTAssertEqual(plan.skippedWindowCount, 5)
        let shielded = windows.filter {
            RuleScheduler.shouldShieldWindow(
                rule: subject,
                window: $0,
                hasMonitor: monitored.contains($0.id),
                isSuspended: false,
                now: noon
            )
        }
        XCTAssertEqual(shielded.count, plan.scheduledWindowCount)
    }
}
