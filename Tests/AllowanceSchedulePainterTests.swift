import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class AllowanceSchedulePainterTests: XCTestCase {
    func testGridGeometryMapsPointerLocationsToScheduleCells() {
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.cell(atX: 0, y: 0),
            AllowanceScheduleCell(weekday: 2, slot: 0)
        )
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.cell(atX: 83.99, y: 23.99),
            AllowanceScheduleCell(weekday: 2, slot: 0)
        )
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.cell(atX: 84, y: 24),
            AllowanceScheduleCell(weekday: 3, slot: 1)
        )
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.cell(atX: 587.99, y: 1_151.99),
            AllowanceScheduleCell(weekday: 1, slot: 47)
        )
    }

    func testGridGeometryRejectsPointerLocationsOutsidePaintableCells() {
        XCTAssertNil(AllowanceScheduleGridGeometry.cell(atX: -0.01, y: 0))
        XCTAssertNil(AllowanceScheduleGridGeometry.cell(atX: 0, y: -0.01))
        XCTAssertNil(AllowanceScheduleGridGeometry.cell(atX: 588, y: 0))
        XCTAssertNil(AllowanceScheduleGridGeometry.cell(atX: 0, y: 1_152))
    }

    func testGridGeometryConvertsAppKitBottomOriginToVisualTopOrigin() {
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.topDownY(forAppKitY: 1_152, height: 1_152),
            0
        )
        XCTAssertEqual(
            AllowanceScheduleGridGeometry.topDownY(forAppKitY: 102, height: 1_152),
            1_050
        )
    }

    func testGridShowsLabelsOnlyOnWholeHours() {
        XCTAssertTrue(AllowanceScheduleGridGeometry.showsTimeLabel(forSlot: 0))
        XCTAssertFalse(AllowanceScheduleGridGeometry.showsTimeLabel(forSlot: 1))
        XCTAssertTrue(AllowanceScheduleGridGeometry.showsTimeLabel(forSlot: 2))
        XCTAssertFalse(AllowanceScheduleGridGeometry.showsTimeLabel(forSlot: 47))
    }

    func testResponsiveLayoutUsesCompactModeWhenThreeColumnsWouldCrushGrid() {
        XCTAssertEqual(
            AllowanceScheduleResponsiveLayout.mode(for: 1_039),
            .compact
        )
        XCTAssertEqual(
            AllowanceScheduleResponsiveLayout.mode(for: 720),
            .compact
        )
    }

    func testResponsiveLayoutKeepsThreeColumnsAtComfortableWidth() {
        XCTAssertEqual(
            AllowanceScheduleResponsiveLayout.mode(for: 1_040),
            .threeColumn
        )
        XCTAssertEqual(
            AllowanceScheduleResponsiveLayout.mode(for: 1_400),
            .threeColumn
        )
    }

    func testWeekdayEveningWindowRoundTripsThroughPaintCells() {
        let source = CloudTimeWindow(
            weekdays: [2, 3, 4, 5, 6],
            startMinutes: 18 * 60,
            endMinutes: 22 * 60
        )

        let cells = AllowanceSchedulePainterCodec.cells(from: [source])
        XCTAssertEqual(cells.count, 40)
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 2, slot: 36)))
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 6, slot: 43)))

        let windows = AllowanceSchedulePainterCodec.windows(from: cells)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].weekdays, source.weekdays)
        XCTAssertEqual(windows[0].startMinutes, source.startMinutes)
        XCTAssertEqual(windows[0].endMinutes, source.endMinutes)
    }

    func testSeparatedPaintRunsRemainSeparateWindows() {
        let cells: Set<AllowanceScheduleCell> = [
            .init(weekday: 2, slot: 16),
            .init(weekday: 2, slot: 17),
            .init(weekday: 2, slot: 37)
        ]

        let windows = AllowanceSchedulePainterCodec.windows(from: cells)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.startMinutes), [8 * 60, 18 * 60 + 30])
        XCTAssertEqual(windows.map(\.endMinutes), [9 * 60, 19 * 60])
        XCTAssertEqual(windows.map(\.weekdays), [[2], [2]])
    }

    func testSamePaintRunAcrossDaysProducesOneReusableWindow() {
        let cells: Set<AllowanceScheduleCell> = Set(
            AllowanceSchedulePainterCodec.orderedWeekdays.flatMap { weekday in
                (36..<44).map { slot in
                    AllowanceScheduleCell(weekday: weekday, slot: slot)
                }
            }
        )

        let windows = AllowanceSchedulePainterCodec.windows(from: cells)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].weekdays, Set(AllowanceSchedulePainterCodec.orderedWeekdays))
        XCTAssertEqual(windows[0].startMinutes, 18 * 60)
        XCTAssertEqual(windows[0].endMinutes, 22 * 60)
    }

    func testHalfHourWindowRoundTripsWithoutExpansion() {
        let source = CloudTimeWindow(
            weekdays: [2],
            startMinutes: 9 * 60 + 30,
            endMinutes: 11 * 60
        )

        let cells = AllowanceSchedulePainterCodec.cells(from: [source])
        XCTAssertEqual(
            cells,
            [
                AllowanceScheduleCell(weekday: 2, slot: 19),
                AllowanceScheduleCell(weekday: 2, slot: 20),
                AllowanceScheduleCell(weekday: 2, slot: 21)
            ]
        )
        let windows = AllowanceSchedulePainterCodec.windows(from: cells)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].weekdays, source.weekdays)
        XCTAssertEqual(windows[0].startMinutes, source.startMinutes)
        XCTAssertEqual(windows[0].endMinutes, source.endMinutes)
    }

    func testFinalHalfHourEndsExactlyAtMidnight() {
        let cells: Set<AllowanceScheduleCell> = [
            .init(weekday: 2, slot: AllowanceSchedulePainterCodec.slotCount - 1)
        ]

        let windows = AllowanceSchedulePainterCodec.windows(from: cells)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].startMinutes, 23 * 60 + 30)
        XCTAssertEqual(windows[0].endMinutes, 24 * 60)
    }

    func testChangingPaintMeaningPreservesEffectiveBlockingSchedule() {
        let allowedCells: Set<AllowanceScheduleCell> = [
            .init(weekday: 2, slot: 18),
            .init(weekday: 2, slot: 19)
        ]
        let disallowedCells = AllowanceSchedulePainterCodec.cells(
            preservingSchedule: allowedCells,
            from: .allow,
            to: .block
        )

        XCTAssertEqual(disallowedCells.count, 7 * 48 - allowedCells.count)
        XCTAssertFalse(disallowedCells.contains(.init(weekday: 2, slot: 18)))
        XCTAssertTrue(disallowedCells.contains(.init(weekday: 3, slot: 18)))

        let allowancePlan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: AllowanceSchedulePainterCodec.windows(from: allowedCells)
        )
        let blockingPlan = CloudTimeWindowPlan(
            paintMode: .block,
            slots: AllowanceSchedulePainterCodec.windows(from: disallowedCells)
        )
        XCTAssertEqual(
            AllowanceSchedulePainterCodec.cells(from: allowancePlan.effectiveBlockingSlots()),
            AllowanceSchedulePainterCodec.cells(from: blockingPlan.effectiveBlockingSlots())
        )
    }
}

extension AllowanceSchedulePainterTests {
    /// Legacy `TimeWindow` documents overnight windows as "end at or before
    /// start, running into the following weekday", and rule migration copies
    /// them verbatim into a `.block` plan. The painter has to decode them, or
    /// the Mac editor seeds an empty grid and its save writes the block away.
    func testDecodesOvernightWindowIntoBothWeekdays() {
        let overnight = CloudTimeWindow(
            weekdays: [6],
            startMinutes: 22 * 60,
            endMinutes: 6 * 60
        )
        let cells = AllowanceSchedulePainterCodec.cells(from: [overnight])

        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 6, slot: 44)), "22:00 Friday")
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 6, slot: 47)), "23:30 Friday")
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 7, slot: 0)), "00:00 Saturday")
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 7, slot: 11)), "05:30 Saturday")
        XCTAssertFalse(cells.contains(AllowanceScheduleCell(weekday: 7, slot: 12)), "06:00 Saturday is clear")
        XCTAssertFalse(cells.contains(AllowanceScheduleCell(weekday: 6, slot: 43)), "21:30 Friday is clear")
        XCTAssertEqual(cells.count, 4 + 12)
    }

    func testOvernightWindowWrapsFromSaturdayToSunday() {
        let overnight = CloudTimeWindow(
            weekdays: [7],
            startMinutes: 23 * 60,
            endMinutes: 60
        )
        let cells = AllowanceSchedulePainterCodec.cells(from: [overnight])

        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 7, slot: 46)))
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 1, slot: 0)))
        XCTAssertTrue(cells.contains(AllowanceScheduleCell(weekday: 1, slot: 1)))
        XCTAssertEqual(cells.count, 4)
    }

    /// A window that starts and ends at the same minute covers the whole day in
    /// `effectiveBlockingSlots`, so the grid has to agree with enforcement.
    func testDecodesFullDayWindowExpressedAsEqualBounds() {
        let allDay = CloudTimeWindow(weekdays: [3], startMinutes: 0, endMinutes: 0)
        let cells = AllowanceSchedulePainterCodec.cells(from: [allDay])

        XCTAssertEqual(cells.count, AllowanceSchedulePainterCodec.slotCount)
        XCTAssertTrue(cells.allSatisfy { $0.weekday == 3 })
    }
}
