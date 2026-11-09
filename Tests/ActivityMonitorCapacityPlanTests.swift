import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class ActivityMonitorCapacityPlanTests: XCTestCase {
    func testAllocationNeverExceedsAvailableActivities() {
        let plan = ActivityMonitorCapacityPlan(
            maximumActivities: 20,
            occupiedActivities: 3,
            allowanceCount: 4,
            needsUsageActivity: true,
            windowCount: 30
        )

        XCTAssertEqual(plan.availableActivities, 17)
        XCTAssertEqual(plan.scheduledAllowanceCount, 4)
        XCTAssertTrue(plan.schedulesUsage)
        XCTAssertEqual(plan.scheduledWindowCount, 12)
        XCTAssertEqual(plan.skippedWindowCount, 18)
    }

    func testAllowancesWithExpiryRestorationTakeCapacityPriority() {
        let plan = ActivityMonitorCapacityPlan(
            maximumActivities: 3,
            occupiedActivities: 0,
            allowanceCount: 5,
            needsUsageActivity: true,
            windowCount: 10
        )

        XCTAssertEqual(plan.scheduledAllowanceCount, 3)
        XCTAssertEqual(plan.skippedAllowanceCount, 2)
        XCTAssertFalse(plan.schedulesUsage)
        XCTAssertEqual(plan.scheduledWindowCount, 0)
    }

    func testOccupiedActivitiesAreClampedAndCannotProduceNegativeCounts() {
        let plan = ActivityMonitorCapacityPlan(
            maximumActivities: 20,
            occupiedActivities: 30,
            allowanceCount: 1,
            needsUsageActivity: true,
            windowCount: 1
        )

        XCTAssertEqual(plan.availableActivities, 0)
        XCTAssertEqual(plan.scheduledAllowanceCount, 0)
        XCTAssertFalse(plan.schedulesUsage)
        XCTAssertEqual(plan.scheduledWindowCount, 0)
    }
}
