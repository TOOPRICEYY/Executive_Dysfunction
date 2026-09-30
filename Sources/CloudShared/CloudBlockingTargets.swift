import Foundation

/// The iOS projection does not contain desktop app targets. Check these before
/// admitting an otherwise equivalent local edit, so a rename/serialization
/// change is free but removing another platform's targets is not.
enum CloudPortableTargetRestriction {
    static func canReplace(_ old: CloudRulePreference?, with new: CloudRulePreference?) -> Bool {
        guard let old, let new, old.enforcementMode == new.enforcementMode else { return false }
        let pairs = [(old.macApplicationIdentifiers, new.macApplicationIdentifiers),
                     (old.windowsExecutablePaths, new.windowsExecutablePaths),
                     (old.windowsPublisherRules, new.windowsPublisherRules)]
        return pairs.allSatisfy { oldValues, newValues in
            let oldSet = Set(oldValues.map { $0.lowercased() })
            let newSet = Set(newValues.map { $0.lowercased() })
            return old.enforcementMode == "fortressAllowList"
                ? newSet.isSubset(of: oldSet) : newSet.isSuperset(of: oldSet)
        }
    }
}

/// Owned by one Blocking Group. Legacy Activity Groups are read only as an
/// import source; new edits never change another group's targets or policy.
struct CloudBlockingTargets: Codable, Equatable {
    var domains: [CloudDomainPreference] = []
    var websiteCategories: Set<String> = []
    var macApplicationIdentifiers: Set<String> = []
    var windowsExecutablePaths: Set<String> = []
    var windowsPublisherRules: Set<String> = []
    var deviceLocalSelectionCount = 0
}

/// Shared URL entry behavior for the native target editors.
enum BlockingTargetInput {
    static let categories = ["social", "video", "news", "shopping", "gaming", "adult", "aiTools", "productivity", "education", "finance", "health", "other"]

    static func domain(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return host
    }

    struct Result {
        var added = 0
        var duplicates = 0
        var invalid: [String] = []
        var message: String {
            var parts: [String] = []
            if added > 0 { parts.append("Added \(added) website\(added == 1 ? "" : "s").") }
            if duplicates > 0 { parts.append("\(duplicates) already in this group.") }
            if !invalid.isEmpty { parts.append("Check \(invalid.count) invalid entr\(invalid.count == 1 ? "y" : "ies"). Use a domain or website URL.") }
            return parts.joined(separator: " ")
        }
    }

    static func add(_ input: String, to targets: inout CloudBlockingTargets) -> Result {
        var result = Result()
        var existing = Set(targets.domains.map { $0.domain.lowercased() })
        for entry in input.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).map(String.init) {
            guard let domain = domain(from: entry) else { result.invalid.append(entry); continue }
            guard existing.insert(domain).inserted else { result.duplicates += 1; continue }
            targets.domains.append(CloudDomainPreference(domain: domain, category: "other", source: "user"))
            targets.websiteCategories.insert("other")
            result.added += 1
        }
        return result
    }
}

extension CloudPreferencesDocument {
    mutating func migrateBlockingGroupOwnership() {
        let importUnused = schemaVersion < 3
        baseline.blockingGroups = baseline.blockingGroups.map {
            $0.owningTargets(from: activityGroups, containerPolicy: baseline.modificationPolicy)
        }
        // Retain unused collections as disabled groups, not silently lost data.
        let imported = Set(baseline.blockingGroups.flatMap(\.activityGroupIDs))
        let ids = Set(baseline.blockingGroups.map(\.id))
        for source in activityGroups where importUnused && !imported.contains(source.id) && !ids.contains(source.id) {
            let group = CloudBlockingGroup(id: source.id, modifiedAt: source.modifiedAt, name: source.name,
                                          activityGroupIDs: [source.id], isEnabled: false)
            baseline.blockingGroups.append(group.owningTargets(from: activityGroups, containerPolicy: baseline.modificationPolicy))
        }
        schemaVersion = max(3, schemaVersion)
    }
}

extension CloudBlockingGroup {
    func owningTargets(from activities: [CloudActivityGroup], containerPolicy: CloudRuleLockdownPreference = .init(severity: "none")) -> CloudBlockingGroup {
        guard targets == nil else { return self }
        var seen: Set<UUID> = []
        let linked = activityGroupIDs.filter { seen.insert($0).inserted }.compactMap { id in activities.first { $0.id == id } }
        // Preserve unresolved imports for later sync rather than discarding
        // targets whose source has not arrived on this device yet.
        guard linked.count == Set(activityGroupIDs).count else { return self }
        var result = self
        var owned = CloudBlockingTargets()
        var domainsSeen: Set<String> = []
        owned.domains = linked.flatMap(\.domains).filter { domainsSeen.insert($0.domain).inserted }
        for source in linked {
            owned.websiteCategories.formUnion(source.websiteCategories)
            owned.macApplicationIdentifiers.formUnion(source.macApplicationIdentifiers)
            owned.windowsExecutablePaths.formUnion(source.windowsExecutablePaths)
            owned.windowsPublisherRules.formUnion(source.windowsPublisherRules)
            owned.deviceLocalSelectionCount += source.deviceLocalSelectionCount
        }
        result.targets = owned
        result.modificationPolicy = CloudRuleLockdownPreference.restrictiveMaximum(
            [containerPolicy, modificationPolicy] + linked.map(\.modificationPolicy))
        result.modifiedAt = max(modifiedAt, linked.map(\.modifiedAt).max() ?? .distantPast)
        // Keep IDs solely for importing device-local opaque tokens on devices
        // that have not opened the new version yet. They no longer own policy.
        return result
    }
}
