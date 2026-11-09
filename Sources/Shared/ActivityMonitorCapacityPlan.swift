import Foundation

struct ActivityMonitorCapacityPlan: Equatable {
    let availableActivities: Int
    let scheduledAllowanceCount: Int
    let schedulesUsage: Bool
    let scheduledWindowCount: Int
    let skippedAllowanceCount: Int
    let skippedWindowCount: Int

    init(
        maximumActivities: Int,
        occupiedActivities: Int,
        allowanceCount: Int,
        needsUsageActivity: Bool,
        windowCount: Int
    ) {
        let available = max(0, maximumActivities - max(0, occupiedActivities))
        var remaining = available

        let allowances = min(max(0, allowanceCount), remaining)
        remaining -= allowances

        let usage = needsUsageActivity && remaining > 0
        if usage { remaining -= 1 }

        let windows = min(max(0, windowCount), remaining)

        availableActivities = available
        scheduledAllowanceCount = allowances
        schedulesUsage = usage
        scheduledWindowCount = windows
        skippedAllowanceCount = max(0, allowanceCount - allowances)
        skippedWindowCount = max(0, windowCount - windows)
    }
}
