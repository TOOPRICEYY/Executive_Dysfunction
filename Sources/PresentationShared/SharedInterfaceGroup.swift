import Foundation

/// A deliberately partial presentation DTO. Updates merge into the native
/// group, preserving budgets, categories, other-platform targets, and tokens.
struct SharedInterfaceGroup: Codable {
    struct Schedule: Codable { var mode: String; var slots: [CloudTimeWindow] }
    struct Change: Codable {
        var kind: String; var words: Int; var delayDays: Int
        // Optional so a host or screen that does not know them leaves them alone.
        var editWindowHours: Int? = nil; var confirmationWindowHours: Int? = nil
    }
    struct Budget: Codable { var dailyMinutes: Int?; var weeklyMinutes: Int? }
    struct DomainCategory: Codable { var domain: String; var category: String; var source: String }
    struct OtherTargets: Codable { var windowsPaths: [String]; var windowsPublishers: [String] }
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
    /// "block" or "allowOnly" (the fortress allow-list). Absent: unchanged.
    var mode: String? = nil
    /// Website categories, from `BlockingTargetInput.categories`. Absent: unchanged.
    var categories: [String]? = nil
    /// Absent: unchanged. A nil member removes that limit.
    var budget: Budget? = nil
    /// Input only: categories found by on-device classification. Absent: unchanged.
    var domainCategories: [DomainCategory]? = nil
    /// Targets for another platform's enforcement (the Mac editor's cross-platform lists).
    var otherTargets: OtherTargets? = nil

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
        changePolicy = .init(kind: kind, words: p.passageWordCount, delayDays: p.unlockDelayDays,
                             editWindowHours: min(72, max(1, p.editWindowHours)),
                             confirmationWindowHours: min(48, max(1, p.confirmationWindowHours)))
        mode = group.enforcementMode == "fortressAllowList" ? "allowOnly" : "block"
        categories = (group.targets?.websiteCategories ?? []).filter(BlockingTargetInput.categories.contains).sorted()
        budget = .init(dailyMinutes: group.usageBudget.dailyLimitMinutes, weeklyMinutes: group.usageBudget.weeklyLimitMinutes)
        #if os(macOS)
        otherTargets = .init(windowsPaths: (group.targets?.windowsExecutablePaths ?? []).sorted(),
                             windowsPublishers: (group.targets?.windowsPublisherRules ?? []).sorted())
        #endif
        temporaryPolicy = .init(allowed: p.allowsTimeExtensions, words: p.effectiveTemporaryAccessPassageWordCount,
                                maximumMinutes: p.effectiveMaximumTemporaryAccessMinutes, resetDays: p.temporaryAllowanceResetDays)
    }

    func merging(into existing: CloudBlockingGroup?) throws -> CloudBlockingGroup {
        func check(_ valid: Bool, _ message: String) throws {
            if !valid { throw SharedInterfaceError(message) }
        }
        try check(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120, "Enter a group name of at most 120 characters.")
        try check((20...300).contains(changePolicy.words) && (0...365).contains(changePolicy.delayDays), "Invalid change policy.")
        try check((20...300).contains(temporaryPolicy.words) && (1...480).contains(temporaryPolicy.maximumMinutes),
                  "Choose a temporary-access maximum between one minute and eight hours.")
        try check(temporaryPolicy.resetDays.map { (1...365).contains($0) } ?? true, "Invalid backoff reset interval.")
        try check(["block", "allow"].contains(schedule.mode) && schedule.slots.count <= 128, "Invalid schedule.")
        for slot in schedule.slots {
            try check(!slot.weekdays.isEmpty && slot.weekdays.allSatisfy { (1...7).contains($0) }
                && (0...1439).contains(slot.startMinutes) && (0...1440).contains(slot.endMinutes), "Invalid time window.")
        }
        try check(domains.count <= 1000 && applications.count <= 1000, "Too many targets.")
        try check(mode.map { ["block", "allowOnly"].contains($0) } ?? true, "Choose whether this group blocks or allows only its targets.")
        try check(categories.map { $0.count <= 64 && $0.allSatisfy(BlockingTargetInput.categories.contains) } ?? true, "Choose supported website categories.")
        try check(budget.map { b in (b.dailyMinutes.map { (1...1440).contains($0) } ?? true) && (b.weeklyMinutes.map { (1...10080).contains($0) } ?? true) } ?? true,
                  "Daily limits run from 1 to 1,440 minutes and weekly limits from 1 to 10,080.")
        try check(changePolicy.editWindowHours.map { (1...72).contains($0) } ?? true, "The edit window runs from 1 to 72 hours.")
        try check(domainCategories.map { $0.count <= 1000 && $0.allSatisfy { BlockingTargetInput.categories.contains($0.category) && ["appleIntelligence", "heuristic", "user"].contains($0.source) } } ?? true,
                  "Invalid website classification.")
        try check(otherTargets.map { t in (t.windowsPaths + t.windowsPublishers).allSatisfy { !$0.isEmpty && $0.count <= 1024 && !$0.contains("\0") }
            && t.windowsPaths.count <= 1000 && t.windowsPublishers.count <= 1000 } ?? true, "Invalid Windows target.")
        try check(changePolicy.confirmationWindowHours.map { (1...48).contains($0) } ?? true, "The confirmation window runs from 1 to 48 hours.")
        var group = existing ?? CloudBlockingGroup(id: id)
        try check(group.id == id, "Group identity changed.")
        try check(existing == nil || group.targets != nil, "Some imported targets have not synced yet. Wait for sync before editing this group.")
        var targets = group.targets ?? CloudBlockingTargets()
        var seen: Set<String> = []
        let known = Set(targets.domains.map(\.domain))
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
        if let categories { targets.websiteCategories = Set(categories) }
        if let domainCategories {
            for item in domainCategories {
                guard let domain = BlockingTargetInput.domain(from: item.domain),
                      let index = targets.domains.firstIndex(where: { $0.domain == domain }) else { continue }
                targets.domains[index] = CloudDomainPreference(domain: domain, category: item.category, source: item.source)
                targets.websiteCategories.insert(item.category)
            }
        }
        // A website is enforced only while its category is on. Adding one turns
        // its category on, exactly as the native editors' add does, so a site
        // typed here is never silently left out on iPhone.
        for added in targets.domains where !known.contains(added.domain) {
            targets.websiteCategories.insert(added.category)
        }
        if let otherTargets {
            targets.windowsExecutablePaths = Set(otherTargets.windowsPaths)
            targets.windowsPublisherRules = Set(otherTargets.windowsPublishers)
        }
        group.targets = targets
        if let mode { group.enforcementMode = mode == "allowOnly" ? "fortressAllowList" : "blockList" }
        if let budget { group.usageBudget = CloudUsageBudget(dailyLimitMinutes: budget.dailyMinutes, weeklyLimitMinutes: budget.weeklyMinutes) }
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
        if let hours = changePolicy.editWindowHours { group.modificationPolicy.editWindowHours = hours }
        if let hours = changePolicy.confirmationWindowHours { group.modificationPolicy.confirmationWindowHours = hours }
        group.modificationPolicy.allowsTimeExtensions = temporaryPolicy.allowed
        group.modificationPolicy.setMaximumTemporaryAccess(minutes: temporaryPolicy.maximumMinutes)
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

/// Dates cross the shared screen as ISO-8601 with whole seconds, while a
/// native retreat keeps `Date()` precision. A date sent back within a second
/// of the stored one is that stored date unchanged, so it must not read as a
/// shorter run (`weakensPlannedInterval`). Snapping only ever restores the
/// stored value, so it can never loosen anything.
enum SharedInterfaceInstant {
    static func keepingStored(_ proposed: Date, stored: Date?) -> Date {
        guard let stored, abs(proposed.timeIntervalSince(stored)) < 1 else { return proposed }
        return stored
    }
}
