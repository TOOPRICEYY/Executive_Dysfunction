import Foundation

/// User-facing summaries only. This layer never decides or changes enforcement.
enum HoldfastPresentation {
    static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func targets(_ targets: CloudBlockingTargets?) -> String {
        guard let targets else { return "Waiting for synced targets" }
        var parts: [String] = []
        if !targets.domains.isEmpty { parts.append(count(targets.domains.count, "website")) }
        if !targets.macApplicationIdentifiers.isEmpty { parts.append(count(targets.macApplicationIdentifiers.count, "Mac app")) }
        let windows = targets.windowsExecutablePaths.count + targets.windowsPublisherRules.count
        if windows > 0 { parts.append(count(windows, "Windows target")) }
        if targets.deviceLocalSelectionCount > 0 { parts.append(count(targets.deviceLocalSelectionCount, "Screen Time selection")) }
        return parts.isEmpty ? "No apps or websites selected" : parts.joined(separator: " · ")
    }

    static func schedule(_ plan: CloudTimeWindowPlan) -> String {
        let slots = plan.effectiveAllowedSlots()
        return slots.isEmpty ? "No allowance windows" : count(slots.count, "allowance window")
    }

    static func targets(rule: CloudRulePreference) -> String {
        targets(CloudBlockingTargets(domains: rule.domains, websiteCategories: rule.websiteCategories,
            macApplicationIdentifiers: rule.macApplicationIdentifiers,
            windowsExecutablePaths: rule.windowsExecutablePaths,
            windowsPublisherRules: rule.windowsPublisherRules,
            deviceLocalSelectionCount: rule.deviceLocalSelectionCount))
    }

    static func policy(_ severity: String) -> String {
        switch severity {
        case "none": "No confirmation required"
        case "passageOnly": "Type a passage"
        case "delayed": "Wait, then type a passage"
        case "repeatedConfirmations": "Wait and confirm at each checkpoint"
        default: "Use the app-wide change policy"
        }
    }

    static func state(_ state: CloudRetreatState) -> String {
        switch state {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .active: "Active"
        case .completed: "Completed"
        case .endedEarly: "Ended early"
        }
    }
}
