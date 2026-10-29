import Foundation

/// A deliberately partial presentation DTO. Updates merge into the native
/// group, preserving budgets, categories, other-platform targets, and tokens.
struct SharedInterfaceGroup: Codable {
    struct Schedule: Codable { var mode: String; var slots: [CloudTimeWindow] }
    struct Change: Codable { var kind: String; var words: Int; var delayDays: Int }
    struct Temporary: Codable { var allowed: Bool; var words: Int; var maximumMinutes: Int; var resetDays: Int? }
    var id: UUID
    var name: String
    var enabled: Bool
    var domains: [String]
    var applications: [String]
    var selectionToken: String? = nil
    var schedule: Schedule
    var changePolicy: Change
    var temporaryPolicy: Temporary

    init(_ group: CloudBlockingGroup) {
        id = group.id; name = group.name; enabled = group.isEnabled
        domains = group.targets?.domains.map(\.domain) ?? []
        #if os(macOS)
        applications = (group.targets?.macApplicationIdentifiers ?? []).sorted()
        #else
        // Opaque Screen Time tokens never travel through JavaScript. The
        // system picker is the only authority for these selections.
        applications = []
        #endif
        schedule = .init(mode: group.timeWindow.paintMode.rawValue, slots: group.timeWindow.slots)
        let p = group.modificationPolicy
        let kind = ["none": "none", "passageOnly": "passage", "delayed": "delay", "repeatedConfirmations": "checkpoints"][p.severity] ?? "inherited"
        changePolicy = .init(kind: kind, words: p.passageWordCount, delayDays: p.unlockDelayDays)
        temporaryPolicy = .init(allowed: p.allowsTimeExtensions, words: p.effectiveTemporaryAccessPassageWordCount,
                                maximumMinutes: p.maximumTimeExtensionHours * 60, resetDays: p.temporaryAllowanceResetDays)
    }

    func merging(into existing: CloudBlockingGroup?) throws -> CloudBlockingGroup {
        func check(_ valid: Bool, _ message: String) throws {
            if !valid { throw SharedInterfaceError(message) }
        }
        try check(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120, "Enter a group name of at most 120 characters.")
        try check((20...300).contains(changePolicy.words) && (0...365).contains(changePolicy.delayDays), "Invalid change policy.")
        try check((20...300).contains(temporaryPolicy.words) && (60...480).contains(temporaryPolicy.maximumMinutes)
                  && temporaryPolicy.maximumMinutes % 60 == 0, "Choose a temporary-access maximum in whole hours, from one to eight.")
        try check(temporaryPolicy.resetDays.map { (1...365).contains($0) } ?? true, "Invalid backoff reset interval.")
        try check(["block", "allow"].contains(schedule.mode) && schedule.slots.count <= 128, "Invalid schedule.")
        for slot in schedule.slots {
            try check(!slot.weekdays.isEmpty && slot.weekdays.allSatisfy { (1...7).contains($0) }
                && (0...1439).contains(slot.startMinutes) && (0...1440).contains(slot.endMinutes), "Invalid time window.")
        }
        try check(domains.count <= 1000 && applications.count <= 1000, "Too many targets.")
        var group = existing ?? CloudBlockingGroup(id: id)
        try check(group.id == id, "Group identity changed.")
        try check(existing == nil || group.targets != nil, "Some imported targets have not synced yet. Wait for sync before editing this group.")
        var targets = group.targets ?? CloudBlockingTargets()
        var seen: Set<String> = []
        targets.domains = try domains.compactMap { input in
            guard let domain = BlockingTargetInput.domain(from: input) else { throw SharedInterfaceError("Invalid website: \(input)") }
            guard seen.insert(domain).inserted else { return nil }
            return targets.domains.first { $0.domain == domain } ?? CloudDomainPreference(domain: domain, category: "other", source: "manual")
        }
        #if os(macOS)
        try check(applications.allSatisfy { !$0.isEmpty && $0.count <= 255 && !$0.contains("/") && !$0.contains("\0") }, "Choose installed applications using the app picker.")
        targets.macApplicationIdentifiers = Set(applications)
        #else
        try check(applications.isEmpty, "Screen Time selections must be changed using the system picker.")
        #endif
        group.targets = targets
        group.name = name.trimmingCharacters(in: .whitespacesAndNewlines); group.isEnabled = enabled
        group.timeWindow.paintMode = schedule.mode == "allow" ? .allow : .block
        group.timeWindow.slots = schedule.slots
        let severities = ["none": "none", "passage": "passageOnly", "delay": "delayed", "checkpoints": "repeatedConfirmations"]
        if changePolicy.kind == "inherited" {
            try check(existing?.modificationPolicy.severity == "appDefault", "Only an existing inherited policy can remain inherited.")
        } else {
            guard let severity = severities[changePolicy.kind] else { throw SharedInterfaceError("Invalid change policy.") }
            group.modificationPolicy.severity = severity
        }
        group.modificationPolicy.passageWordCount = changePolicy.words
        group.modificationPolicy.unlockDelayDays = changePolicy.delayDays
        group.modificationPolicy.allowsTimeExtensions = temporaryPolicy.allowed
        group.modificationPolicy.maximumTimeExtensionHours = temporaryPolicy.maximumMinutes / 60
        group.modificationPolicy.temporaryAllowanceResetDays = temporaryPolicy.resetDays
        // Preserve inheritance when it has not actually changed. Re-encoding a
        // legacy policy is not a user request to pin a formerly inherited value.
        if temporaryPolicy.words != existing?.modificationPolicy.effectiveTemporaryAccessPassageWordCount || existing == nil {
            group.modificationPolicy.temporaryAccessPassageWordCount = temporaryPolicy.words
        }
        return group
    }
}

struct SharedInterfaceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
