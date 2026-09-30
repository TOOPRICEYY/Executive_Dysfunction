import Foundation

enum AllowanceScheduleLayoutMode: Equatable, Sendable {
    case compact
    case threeColumn
}

enum AllowanceScheduleResponsiveLayout {
    /// The three-column editor needs enough room for both inspectors and a
    /// useful, independently scrollable portion of the schedule grid.
    static let threeColumnMinimumWidth = 1_040.0

    static func mode(for availableWidth: Double) -> AllowanceScheduleLayoutMode {
        availableWidth >= threeColumnMinimumWidth ? .threeColumn : .compact
    }
}

enum AllowanceScheduleGridGeometry {
    static let columnWidth = 84.0
    static let rowHeight = 24.0
    static let columnCount = AllowanceSchedulePainterCodec.orderedWeekdays.count
    static let rowCount = AllowanceSchedulePainterCodec.slotCount

    static func topDownY(forAppKitY y: Double, height: Double) -> Double {
        height - y
    }

    static func showsTimeLabel(forSlot slot: Int) -> Bool {
        let slotsPerHour = 60 / AllowanceSchedulePainterCodec.slotMinutes
        return (0..<rowCount).contains(slot) && slot.isMultiple(of: slotsPerHour)
    }

    static func cell(atX x: Double, y: Double) -> AllowanceScheduleCell? {
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / columnWidth)
        let row = Int(y / rowHeight)
        guard (0..<columnCount).contains(column), (0..<rowCount).contains(row) else {
            return nil
        }
        return AllowanceScheduleCell(
            weekday: AllowanceSchedulePainterCodec.orderedWeekdays[column],
            slot: row
        )
    }
}
