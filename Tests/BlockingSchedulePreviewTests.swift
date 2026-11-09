import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class BlockingSchedulePreviewTests: XCTestCase {
    func testAllowanceWindowsAreShownAsGapsWithoutRoundingMinutes() {
        let plan = CloudTimeWindowPlan(paintMode: .allow, slots: [.init(weekdays: [2], startMinutes: 607, endMinutes: 643)])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 2, plan: plan), [.init(start: 0, end: 607), .init(start: 643, end: 1440)])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 3, plan: plan), [.init(start: 0, end: 1440)])
    }

    func testOvernightBlocksWrapIntoSundayAndMergeOverlaps() {
        let plan = CloudTimeWindowPlan(paintMode: .block, slots: [
            .init(weekdays: [7], startMinutes: 1380, endMinutes: 60),
            .init(weekdays: [1], startMinutes: 30, endMinutes: 120)
        ])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 7, plan: plan), [.init(start: 1380, end: 1440)])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 1, plan: plan), [.init(start: 0, end: 120)])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 2, plan: plan), [])
    }

    func testEmptyModesAndFullDayHaveDistinctSummaries() {
        let blocked = BlockingSchedulePreview.spans(for: 2, plan: .init(paintMode: .allow, slots: []))
        let allowed = BlockingSchedulePreview.spans(for: 2, plan: .init(paintMode: .block, slots: []))
        XCTAssertEqual(BlockingSchedulePreview.summary(blocked), "Blocked all day")
        XCTAssertEqual(BlockingSchedulePreview.summary(allowed), "No scheduled blocking")
        let allDay = CloudTimeWindowPlan(paintMode: .block, slots: [.init(weekdays: [2], startMinutes: 0, endMinutes: 0)])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 2, plan: allDay), blocked)
        XCTAssertEqual(BlockingSchedulePreview.summary([.init(start: 607, end: 643)]), "Blocked 10:07–10:43")
    }

    func testInvalidWindowsAreIgnored() {
        let plan = CloudTimeWindowPlan(paintMode: .block, slots: [
            .init(weekdays: [2], startMinutes: -1, endMinutes: 60),
            .init(weekdays: [0, 8], startMinutes: 0, endMinutes: 60)
        ])
        XCTAssertEqual(BlockingSchedulePreview.spans(for: 2, plan: plan), [])
    }
}
