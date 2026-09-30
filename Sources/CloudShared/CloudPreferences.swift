import CryptoKit
import Foundation

struct CloudPreferencesDocument: Codable, Equatable {
    var schemaVersion = 2
    var rules: [CloudRulePreference] = []
    var tombstones: [CloudRuleTombstone] = []
    var activityGroups: [CloudActivityGroup] = []
    var activityGroupTombstones: [CloudActivityGroupTombstone] = []
    var baseline = CloudBaseline()
    var retreats: [CloudRetreat] = []
    var timeWindowTemplates: [CloudTimeWindowTemplate] = []

    init(
        schemaVersion: Int = 2,
        rules: [CloudRulePreference] = [],
        tombstones: [CloudRuleTombstone] = [],
        activityGroups: [CloudActivityGroup] = [],
        activityGroupTombstones: [CloudActivityGroupTombstone] = [],
        baseline: CloudBaseline = CloudBaseline(),
        retreats: [CloudRetreat] = [],
        timeWindowTemplates: [CloudTimeWindowTemplate] = []
    ) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.tombstones = tombstones
        self.activityGroups = activityGroups
        self.activityGroupTombstones = activityGroupTombstones
        self.baseline = baseline
        self.retreats = retreats
        self.timeWindowTemplates = timeWindowTemplates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, tombstones, activityGroups, activityGroupTombstones
        case baseline, retreats, timeWindowTemplates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        rules = try values.decodeIfPresent([CloudRulePreference].self, forKey: .rules) ?? []
        tombstones = try values.decodeIfPresent([CloudRuleTombstone].self, forKey: .tombstones) ?? []
        activityGroups = try values.decodeIfPresent([CloudActivityGroup].self, forKey: .activityGroups) ?? []
        activityGroupTombstones = try values.decodeIfPresent(
            [CloudActivityGroupTombstone].self,
            forKey: .activityGroupTombstones
        ) ?? []
        baseline = try values.decodeIfPresent(CloudBaseline.self, forKey: .baseline) ?? CloudBaseline()
        retreats = try values.decodeIfPresent([CloudRetreat].self, forKey: .retreats) ?? []
        timeWindowTemplates = try values.decodeIfPresent(
            [CloudTimeWindowTemplate].self,
            forKey: .timeWindowTemplates
        ) ?? []
    }

    mutating func merge(rule: CloudRulePreference) {
        if let tombstone = tombstones.first(where: { $0.id == rule.id }),
           tombstone.modifiedAt >= rule.modifiedAt { return }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            guard rules[index].modifiedAt <= rule.modifiedAt else { return }
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        tombstones.removeAll { $0.id == rule.id && $0.modifiedAt <= rule.modifiedAt }
        absorbLegacyRule(rule)
    }

    mutating func merge(tombstone: CloudRuleTombstone) {
        if let rule = rules.first(where: { $0.id == tombstone.id }),
           rule.modifiedAt > tombstone.modifiedAt { return }
        if let index = tombstones.firstIndex(where: { $0.id == tombstone.id }) {
            guard tombstones[index].modifiedAt <= tombstone.modifiedAt else { return }
            tombstones[index] = tombstone
        } else {
            tombstones.append(tombstone)
        }
        rules.removeAll { $0.id == tombstone.id && $0.modifiedAt <= tombstone.modifiedAt }
        if baseline.blockingGroups.contains(where: { $0.id == tombstone.id }) {
            deleteActivityGroup(id: tombstone.id, at: tombstone.modifiedAt)
        }
    }

    mutating func migrateLegacyRulesIfNeeded() {
        guard activityGroups.isEmpty, baseline.blockingGroups.isEmpty, !rules.isEmpty else {
            schemaVersion = max(2, schemaVersion)
            return
        }
        for rule in rules where !tombstones.contains(where: { $0.id == rule.id && $0.modifiedAt >= rule.modifiedAt }) {
            absorbLegacyRule(rule)
        }
        schemaVersion = max(2, schemaVersion)
        rebuildLegacyRuleProjection()
    }

    mutating func rebuildLegacyRuleProjection(at date: Date = Date()) {
        reconcileRetreatLifecycles(at: date)
        rules = compiledRules(at: date)
        schemaVersion = max(2, schemaVersion)
    }

    mutating func reconcileRetreatLifecycles(at date: Date = Date()) {
        for index in retreats.indices {
            retreats[index].reconcile(at: date)
        }
    }

    func compiledRules(at date: Date = Date()) -> [CloudRulePreference] {
        let groupsByID = Dictionary(
            activityGroups.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                current.modifiedAt >= candidate.modifiedAt ? current : candidate
            }
        )
        var contexts = baseline.blockingGroups.map { ($0, baseline.modificationPolicy) }
        for retreat in retreats {
            guard retreat.isActive(at: date), let version = retreat.currentVersion else { continue }
            contexts.append(contentsOf: version.blockingGroups.map {
                ($0, CloudRuleLockdownPreference.restrictiveMaximum([
                    retreat.modificationPolicy,
                    version.modificationPolicy
                ]))
            })
        }

        return contexts.compactMap { blockingGroup, containerPolicy in
            compiledRule(
                from: blockingGroup,
                containerPolicy: containerPolicy,
                groupsByID: groupsByID
            )
        }
    }

    /// The dashboard presents every enabled Blocking Group that participates
    /// in the baseline or a currently active Retreat. Its schedule controls
    /// when enforcement applies; it does not control whether the group is
    /// visible on the dashboard.
    func dashboardBlockingRules(at date: Date = Date()) -> [CloudRulePreference] {
        compiledRules(at: date)
            .filter(\.isEnabled)
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Baseline groups are shown without a boundary. Scheduled and active
    /// Retreat groups are clipped to their planned run, which makes the
    /// dashboard calendar match the period when they can actually enforce.
    func dashboardCalendarRules(at date: Date = Date()) -> [BlockStatusCalendarRule] {
        let groupsByID = Dictionary(activityGroups.map { ($0.id, $0) }, uniquingKeysWith: {
            current, candidate in current.modifiedAt >= candidate.modifiedAt ? current : candidate
        })
        var entries: [BlockStatusCalendarRule] = []

        for group in baseline.blockingGroups {
            guard let rule = compiledRule(
                from: group,
                containerPolicy: baseline.modificationPolicy,
                groupsByID: groupsByID
            ), rule.isEnabled else { continue }
            entries.append(BlockStatusCalendarRule(rule: rule))
        }

        for retreat in retreats where (retreat.state == .scheduled || retreat.state == .active)
            && retreat.plannedEnd > date && retreat.plannedEnd > retreat.plannedStart {
            guard let version = retreat.currentVersion else { continue }
            let policy = CloudRuleLockdownPreference.restrictiveMaximum([
                retreat.modificationPolicy,
                version.modificationPolicy
            ])
            let interval = DateInterval(start: retreat.plannedStart, end: retreat.plannedEnd)
            for group in version.blockingGroups {
                guard let rule = compiledRule(
                    from: group,
                    containerPolicy: policy,
                    groupsByID: groupsByID
                ), rule.isEnabled else { continue }
                entries.append(BlockStatusCalendarRule(rule: rule, enforcementInterval: interval))
            }
        }

        return entries.sorted {
            $0.rule.name.localizedCaseInsensitiveCompare($1.rule.name) == .orderedAscending
        }
    }

    mutating func deleteActivityGroup(id: UUID, at date: Date = Date()) {
        guard let group = activityGroups.first(where: { $0.id == id }) else { return }
        activityGroups.removeAll { $0.id == id }
        activityGroupTombstones.removeAll { $0.id == id }
        activityGroupTombstones.append(.init(id: id, name: group.name, modifiedAt: date))
        baseline.blockingGroups = baseline.blockingGroups.compactMap { $0.removingActivityGroup(id) }

        for index in retreats.indices where retreats[index].state.isLiveConfiguration {
            guard let current = retreats[index].currentVersion else { continue }
            let revisedGroups = current.blockingGroups.compactMap { $0.removingActivityGroup(id) }
            guard revisedGroups != current.blockingGroups else { continue }
            retreats[index].appendVersion(
                blockingGroups: revisedGroups,
                modificationPolicy: current.modificationPolicy,
                at: date
            )
        }
        rebuildLegacyRuleProjection(at: date)
    }

    private mutating func absorbLegacyRule(_ rule: CloudRulePreference) {
        let activityGroup = CloudActivityGroup(legacyRule: rule)
        if let index = activityGroups.firstIndex(where: { $0.id == activityGroup.id }) {
            guard activityGroups[index].modifiedAt <= activityGroup.modifiedAt else { return }
            activityGroups[index] = activityGroup
        } else {
            activityGroups.append(activityGroup)
        }

        let blockingGroup = CloudBlockingGroup(legacyRule: rule)
        if let index = baseline.blockingGroups.firstIndex(where: { $0.id == blockingGroup.id }) {
            guard baseline.blockingGroups[index].modifiedAt <= blockingGroup.modifiedAt else { return }
            baseline.blockingGroups[index] = blockingGroup
        } else {
            baseline.blockingGroups.append(blockingGroup)
        }
        baseline.modifiedAt = max(baseline.modifiedAt, rule.modifiedAt)
    }
}

private func compiledRule(
    from blockingGroup: CloudBlockingGroup,
    containerPolicy: CloudRuleLockdownPreference,
    groupsByID: [UUID: CloudActivityGroup]
) -> CloudRulePreference? {
    if let targets = blockingGroup.targets {
        return CloudRulePreference(
            id: blockingGroup.id, modifiedAt: blockingGroup.modifiedAt, name: blockingGroup.name,
            isEnabled: blockingGroup.isEnabled, enforcementMode: blockingGroup.enforcementMode,
            windows: blockingGroup.timeWindow.effectiveBlockingSlots(),
            usageLimitEnabled: blockingGroup.usageBudget.dailyLimitMinutes != nil,
            dailyUsageLimitMinutes: blockingGroup.usageBudget.dailyLimitMinutes ?? 30,
            domains: targets.domains, websiteCategories: targets.websiteCategories,
            macApplicationIdentifiers: targets.macApplicationIdentifiers,
            windowsExecutablePaths: targets.windowsExecutablePaths,
            windowsPublisherRules: targets.windowsPublisherRules,
            lockdown: .restrictiveMaximum([containerPolicy, blockingGroup.modificationPolicy]),
            deviceLocalSelectionCount: targets.deviceLocalSelectionCount)
    }
    let linkedGroups = blockingGroup.activityGroupIDs.compactMap { groupsByID[$0] }
    guard !linkedGroups.isEmpty else { return nil }
    let effectivePolicy = CloudRuleLockdownPreference.restrictiveMaximum(
        [containerPolicy, blockingGroup.modificationPolicy]
            + linkedGroups.map(\.modificationPolicy)
    )
    return CloudRulePreference(
        id: blockingGroup.id,
        modifiedAt: max(blockingGroup.modifiedAt, linkedGroups.map(\.modifiedAt).max() ?? .distantPast),
        name: blockingGroup.name.isEmpty
            ? linkedGroups.map(\.name).joined(separator: " + ")
            : blockingGroup.name,
        isEnabled: blockingGroup.isEnabled,
        enforcementMode: blockingGroup.enforcementMode,
        windows: blockingGroup.timeWindow.effectiveBlockingSlots(),
        usageLimitEnabled: blockingGroup.usageBudget.dailyLimitMinutes != nil,
        dailyUsageLimitMinutes: blockingGroup.usageBudget.dailyLimitMinutes ?? 30,
        domains: linkedGroups.flatMap(\.domains).uniqued(by: \.domain),
        websiteCategories: linkedGroups.reduce(into: Set<String>()) { $0.formUnion($1.websiteCategories) },
        macApplicationIdentifiers: linkedGroups.reduce(into: Set<String>()) { $0.formUnion($1.macApplicationIdentifiers) },
        windowsExecutablePaths: linkedGroups.reduce(into: Set<String>()) { $0.formUnion($1.windowsExecutablePaths) },
        windowsPublisherRules: linkedGroups.reduce(into: Set<String>()) { $0.formUnion($1.windowsPublisherRules) },
        lockdown: effectivePolicy,
        deviceLocalSelectionCount: linkedGroups.reduce(0) { $0 + $1.deviceLocalSelectionCount }
    )
}

private extension Array {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}

struct CloudRulePreference: Codable, Equatable, Identifiable {
    var id = UUID()
    var modifiedAt = Date()
    var name = "Focus rule"
    var isEnabled = true
    var enforcementMode = "blockList"
    var windows: [CloudTimeWindow] = [CloudTimeWindow()]
    var usageLimitEnabled = false
    var dailyUsageLimitMinutes = 30
    var domains: [CloudDomainPreference] = []
    var websiteCategories: Set<String> = []
    /// Stable macOS code-signing identifiers (normally bundle identifiers).
    /// Unlike Screen Time tokens, these are portable and can be enforced by an
    /// administrator-approved Endpoint Security system extension.
    var macApplicationIdentifiers: Set<String> = []
    /// Normalized Windows executable paths. Production Windows deployments
    /// should prefer publisher rules where available so application updates do
    /// not silently move outside the rule.
    var windowsExecutablePaths: Set<String> = []
    var windowsPublisherRules: Set<String> = []
    var lockdown = CloudRuleLockdownPreference()
    /// Informational only. Opaque Screen Time tokens never leave the iPhone.
    var deviceLocalSelectionCount = 0
}

extension CloudRulePreference {
    private enum CodingKeys: String, CodingKey {
        case id, modifiedAt, name, isEnabled, enforcementMode, windows
        case usageLimitEnabled, dailyUsageLimitMinutes, domains, websiteCategories
        case macApplicationIdentifiers, windowsExecutablePaths, windowsPublisherRules
        case lockdown, deviceLocalSelectionCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Focus rule"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        enforcementMode = try values.decodeIfPresent(String.self, forKey: .enforcementMode) ?? "blockList"
        windows = try values.decodeIfPresent([CloudTimeWindow].self, forKey: .windows) ?? [CloudTimeWindow()]
        usageLimitEnabled = try values.decodeIfPresent(Bool.self, forKey: .usageLimitEnabled) ?? false
        dailyUsageLimitMinutes = try values.decodeIfPresent(Int.self, forKey: .dailyUsageLimitMinutes) ?? 30
        domains = try values.decodeIfPresent([CloudDomainPreference].self, forKey: .domains) ?? []
        websiteCategories = try values.decodeIfPresent(Set<String>.self, forKey: .websiteCategories) ?? []
        macApplicationIdentifiers = try values.decodeIfPresent(Set<String>.self, forKey: .macApplicationIdentifiers) ?? []
        windowsExecutablePaths = try values.decodeIfPresent(Set<String>.self, forKey: .windowsExecutablePaths) ?? []
        windowsPublisherRules = try values.decodeIfPresent(Set<String>.self, forKey: .windowsPublisherRules) ?? []
        lockdown = try values.decodeIfPresent(CloudRuleLockdownPreference.self, forKey: .lockdown)
            ?? CloudRuleLockdownPreference()
        deviceLocalSelectionCount = try values.decodeIfPresent(Int.self, forKey: .deviceLocalSelectionCount) ?? 0
    }
}

struct CloudTimeWindow: Codable, Equatable, Identifiable {
    var id = UUID()
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinutes = 9 * 60
    var endMinutes = 17 * 60

    var startsAt: Date {
        get { Self.referenceDate(minutes: startMinutes) }
        set { startMinutes = Self.minutes(from: newValue) }
    }

    var endsAt: Date {
        get { Self.referenceDate(minutes: endMinutes) }
        set { endMinutes = Self.minutes(from: newValue) }
    }

    private static func referenceDate(minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: max(0, min(23, minutes / 60)),
            minute: max(0, min(59, minutes % 60)),
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

extension CloudTimeWindow {
    /// Blocking windows are derived from an allowance plan on every load and
    /// save, so a fresh UUID each time would hand the iPhone's Device Activity
    /// monitors a new identity on every sync. A monitor restarted in the middle
    /// of its own window can no longer be relied on to deliver the interval end
    /// that lifts its shield, which shows up as a block that never releases.
    /// The identity is therefore a function of the schedule it represents.
    static func derivedID(
        planID: UUID,
        weekdays: Set<Int>,
        startMinutes: Int,
        endMinutes: Int
    ) -> UUID {
        let seed = [
            planID.uuidString,
            weekdays.sorted().map(String.init).joined(separator: ","),
            String(startMinutes),
            String(endMinutes)
        ].joined(separator: "|")

        var digest = Array(Insecure.MD5.hash(data: Data(seed.utf8)))
        // Tag the value so it is a well-formed name-based UUID rather than an
        // arbitrary 16 bytes.
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

enum CloudTimeWindowPaintMode: String, Codable, CaseIterable {
    case block
    case allow
}

struct CloudTimeWindowPlan: Codable, Equatable, Identifiable {
    var id = UUID()
    var paintMode: CloudTimeWindowPaintMode = .block
    var slots: [CloudTimeWindow] = [CloudTimeWindow()]

    func effectiveBlockingSlots() -> [CloudTimeWindow] {
        guard paintMode == .allow else { return slots }
        let minutesPerDay = 1_440
        struct Range: Hashable { var start: Int; var end: Int }
        var allowed: [Int: [Range]] = [:]

        func append(_ range: Range, weekday: Int) {
            guard (1...7).contains(weekday), range.start < range.end else { return }
            allowed[weekday, default: []].append(range)
        }

        for slot in slots {
            guard (0...minutesPerDay).contains(slot.startMinutes),
                  (0...minutesPerDay).contains(slot.endMinutes),
                  slot.startMinutes < minutesPerDay else {
                continue
            }
            for startWeekday in slot.weekdays where (1...7).contains(startWeekday) {
                if slot.startMinutes < slot.endMinutes {
                    append(Range(start: slot.startMinutes, end: slot.endMinutes), weekday: startWeekday)
                } else {
                    append(Range(start: slot.startMinutes, end: minutesPerDay), weekday: startWeekday)
                    let next = startWeekday == 7 ? 1 : startWeekday + 1
                    append(Range(start: 0, end: slot.endMinutes), weekday: next)
                }
            }
        }

        var ranges: [Range: Set<Int>] = [:]
        for weekday in 1...7 {
            let sorted = (allowed[weekday] ?? []).sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
            var merged: [Range] = []
            for value in sorted {
                if let last = merged.last, value.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, value.end)
                } else {
                    merged.append(value)
                }
            }

            var cursor = 0
            for value in merged {
                if cursor < value.start {
                    ranges[Range(start: cursor, end: value.start), default: []].insert(weekday)
                }
                cursor = max(cursor, value.end)
            }
            if cursor < minutesPerDay {
                ranges[Range(start: cursor, end: minutesPerDay), default: []].insert(weekday)
            }
        }
        return ranges.map { range, weekdays in
            CloudTimeWindow(
                id: CloudTimeWindow.derivedID(
                    planID: id,
                    weekdays: weekdays,
                    startMinutes: range.start,
                    endMinutes: range.end
                ),
                weekdays: weekdays,
                startMinutes: range.start,
                endMinutes: range.end
            )
        }
        .sorted {
            $0.startMinutes == $1.startMinutes
                ? $0.endMinutes < $1.endMinutes
                : $0.startMinutes < $1.startMinutes
        }
    }

    func effectiveAllowedSlots() -> [CloudTimeWindow] {
        if paintMode == .allow { return slots }
        return CloudTimeWindowPlan(id: id, paintMode: .allow, slots: slots).effectiveBlockingSlots()
    }
}

struct CloudUsageBudget: Codable, Equatable {
    var dailyLimitMinutes: Int?
    var weeklyLimitMinutes: Int?

    init(dailyLimitMinutes: Int? = nil, weeklyLimitMinutes: Int? = nil) {
        self.dailyLimitMinutes = dailyLimitMinutes
        self.weeklyLimitMinutes = weeklyLimitMinutes
    }
}

struct CloudActivityGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var modifiedAt = Date()
    var name = "Activity group"
    var domains: [CloudDomainPreference] = []
    var websiteCategories: Set<String> = []
    var macApplicationIdentifiers: Set<String> = []
    var windowsExecutablePaths: Set<String> = []
    var windowsPublisherRules: Set<String> = []
    var modificationPolicy = CloudRuleLockdownPreference()
    /// Opaque FamilyControls tokens remain on their originating device. This
    /// count makes an incomplete portable group visible without pretending the
    /// selections can be reconstructed elsewhere.
    var deviceLocalSelectionCount = 0

    init(
        id: UUID = UUID(),
        modifiedAt: Date = Date(),
        name: String = "Activity group",
        domains: [CloudDomainPreference] = [],
        websiteCategories: Set<String> = [],
        macApplicationIdentifiers: Set<String> = [],
        windowsExecutablePaths: Set<String> = [],
        windowsPublisherRules: Set<String> = [],
        modificationPolicy: CloudRuleLockdownPreference = CloudRuleLockdownPreference(),
        deviceLocalSelectionCount: Int = 0
    ) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.name = name
        self.domains = domains
        self.websiteCategories = websiteCategories
        self.macApplicationIdentifiers = macApplicationIdentifiers
        self.windowsExecutablePaths = windowsExecutablePaths
        self.windowsPublisherRules = windowsPublisherRules
        self.modificationPolicy = modificationPolicy
        self.deviceLocalSelectionCount = deviceLocalSelectionCount
    }

    init(legacyRule rule: CloudRulePreference) {
        id = rule.id
        modifiedAt = rule.modifiedAt
        name = rule.name
        domains = rule.domains
        websiteCategories = rule.websiteCategories
        macApplicationIdentifiers = rule.macApplicationIdentifiers
        windowsExecutablePaths = rule.windowsExecutablePaths
        windowsPublisherRules = rule.windowsPublisherRules
        modificationPolicy = rule.lockdown
        deviceLocalSelectionCount = rule.deviceLocalSelectionCount
    }
}

struct CloudActivityGroupTombstone: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var modifiedAt: Date
}

struct CloudBlockingGroup: Codable, Equatable, Identifiable {
    var targets: CloudBlockingTargets?
    var id = UUID()
    /// The reusable Baseline Blocking Group this Retreat-local copy came from.
    /// Older documents predate this field; matching falls back to the linked
    /// Activity Groups and name until the next edited Retreat version.
    var sourceBlockingGroupID: UUID?
    var modifiedAt = Date()
    var name = "Blocking group"
    var activityGroupIDs: [UUID] = []
    var timeWindow = CloudTimeWindowPlan()
    var usageBudget = CloudUsageBudget()
    var isEnabled = false
    var enforcementMode = "blockList"
    var modificationPolicy = CloudRuleLockdownPreference()

    init(
        id: UUID = UUID(),
        sourceBlockingGroupID: UUID? = nil,
        modifiedAt: Date = Date(),
        name: String = "Blocking group",
        activityGroupIDs: [UUID] = [],
        timeWindow: CloudTimeWindowPlan = CloudTimeWindowPlan(),
        usageBudget: CloudUsageBudget = CloudUsageBudget(),
        isEnabled: Bool = false,
        enforcementMode: String = "blockList",
        modificationPolicy: CloudRuleLockdownPreference = CloudRuleLockdownPreference()
    ) {
        self.id = id
        self.sourceBlockingGroupID = sourceBlockingGroupID
        self.modifiedAt = modifiedAt
        self.name = name
        self.activityGroupIDs = activityGroupIDs
        self.timeWindow = timeWindow
        self.usageBudget = usageBudget
        self.isEnabled = isEnabled
        self.enforcementMode = enforcementMode
        self.modificationPolicy = modificationPolicy
    }

    init(legacyRule rule: CloudRulePreference) {
        id = rule.id
        sourceBlockingGroupID = nil
        modifiedAt = rule.modifiedAt
        name = rule.name
        activityGroupIDs = [rule.id]
        timeWindow = CloudTimeWindowPlan(id: rule.id, paintMode: .block, slots: rule.windows)
        usageBudget = CloudUsageBudget(
            dailyLimitMinutes: rule.usageLimitEnabled ? rule.dailyUsageLimitMinutes : nil
        )
        isEnabled = rule.isEnabled
        enforcementMode = rule.enforcementMode
        modificationPolicy = rule.lockdown
    }

    func removingActivityGroup(_ id: UUID) -> CloudBlockingGroup? {
        var copy = self
        copy.activityGroupIDs.removeAll { $0 == id }
        return copy.activityGroupIDs.isEmpty ? nil : copy
    }

    func makeIndependentCopy(at date: Date = Date()) -> CloudBlockingGroup {
        var copy = self
        copy.sourceBlockingGroupID = sourceBlockingGroupID ?? id
        copy.id = UUID()
        copy.modifiedAt = date
        copy.timeWindow.id = UUID()
        copy.timeWindow.slots = copy.timeWindow.slots.map { slot in
            CloudTimeWindow(
                weekdays: slot.weekdays,
                startMinutes: slot.startMinutes,
                endMinutes: slot.endMinutes
            )
        }
        return copy
    }
}

enum CloudRetreatGroupVersioning {
    /// Builds a new Retreat version without replacing the identity of groups
    /// that were already in that Retreat. Selected Baseline groups that did
    /// not previously exist in the Retreat become independent, enabled copies.
    static func versionedGroups(
        from selectedGroups: [CloudBlockingGroup],
        replacing currentGroups: [CloudBlockingGroup],
        at date: Date = Date()
    ) -> [CloudBlockingGroup] {
        var consumedCurrentIDs: Set<UUID> = []
        return selectedGroups.map { selected in
            let current = currentGroups.first {
                !consumedCurrentIDs.contains($0.id) && matches(selected: selected, current: $0)
            }

            var result: CloudBlockingGroup
            if let current {
                consumedCurrentIDs.insert(current.id)
                result = selected
                result.id = current.id
                result.sourceBlockingGroupID = resolvedSourceID(selected: selected, current: current)
                result.timeWindow.id = current.timeWindow.id
                result.timeWindow.slots = result.timeWindow.slots.map { slot in
                    current.timeWindow.slots.first {
                        $0.weekdays == slot.weekdays
                            && $0.startMinutes == slot.startMinutes
                            && $0.endMinutes == slot.endMinutes
                    } ?? CloudTimeWindow(
                        weekdays: slot.weekdays,
                        startMinutes: slot.startMinutes,
                        endMinutes: slot.endMinutes
                    )
                }
            } else {
                result = selected.makeIndependentCopy(at: date)
            }
            // Baseline enablement controls ordinary enforcement. Selecting a
            // group for a Retreat means that its Retreat-local copy is active.
            result.isEnabled = true
            if let current,
               enforcementConfiguration(of: result) == enforcementConfiguration(of: current) {
                // Provenance can be repaired without making an unchanged rule
                // appear modified to a locked projection.
                result.modifiedAt = current.modifiedAt
            } else {
                result.modifiedAt = date
            }
            return result
        }
    }

    /// True when a historical Retreat copy represents this reusable Baseline
    /// group. Provenance is authoritative; the fallback supports old files.
    static func represents(
        _ retreatGroup: CloudBlockingGroup,
        baselineGroup: CloudBlockingGroup
    ) -> Bool {
        if retreatGroup.sourceBlockingGroupID == baselineGroup.id { return true }
        guard retreatGroup.sourceBlockingGroupID == nil else { return false }
        return retreatGroup.name == baselineGroup.name
            && Set(retreatGroup.activityGroupIDs) == Set(baselineGroup.activityGroupIDs)
            && retreatGroup.enforcementMode == baselineGroup.enforcementMode
    }

    private static func matches(
        selected: CloudBlockingGroup,
        current: CloudBlockingGroup
    ) -> Bool {
        if selected.id == current.id { return true }
        if let selectedSource = selected.sourceBlockingGroupID,
           selectedSource == current.sourceBlockingGroupID {
            return true
        }
        if current.sourceBlockingGroupID == selected.id { return true }
        return represents(current, baselineGroup: selected)
    }

    private static func resolvedSourceID(
        selected: CloudBlockingGroup,
        current: CloudBlockingGroup
    ) -> UUID? {
        if selected.id == current.id {
            return current.sourceBlockingGroupID
        }
        return selected.sourceBlockingGroupID
            ?? current.sourceBlockingGroupID
            ?? selected.id
    }

    private struct EnforcementConfiguration: Equatable {
        var name: String
        var activityGroupIDs: Set<UUID>
        var blockedMinutes: Set<Int>
        var usageBudget: CloudUsageBudget
        var isEnabled: Bool
        var enforcementMode: String
        var modificationPolicy: CloudRuleLockdownPreference
    }

    private static func enforcementConfiguration(
        of group: CloudBlockingGroup
    ) -> EnforcementConfiguration {
        var blockedMinutes: Set<Int> = []
        for slot in group.timeWindow.effectiveBlockingSlots() {
            for weekday in slot.weekdays {
                let duration = slot.startMinutes < slot.endMinutes
                    ? slot.endMinutes - slot.startMinutes
                    : 1_440 - slot.startMinutes + slot.endMinutes
                let start = (weekday - 1) * 1_440 + slot.startMinutes
                for offset in 0..<duration {
                    blockedMinutes.insert((start + offset) % (7 * 1_440))
                }
            }
        }
        return EnforcementConfiguration(
            name: group.name,
            activityGroupIDs: Set(group.activityGroupIDs),
            blockedMinutes: blockedMinutes,
            usageBudget: group.usageBudget,
            isEnabled: group.isEnabled,
            enforcementMode: group.enforcementMode,
            modificationPolicy: group.modificationPolicy
        )
    }
}

struct CloudBaseline: Codable, Equatable, Identifiable {
    var id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var modifiedAt = Date.distantPast
    var blockingGroups: [CloudBlockingGroup] = []
    var modificationPolicy = CloudRuleLockdownPreference(severity: "none")
}

enum CloudRetreatState: String, Codable, CaseIterable {
    case draft
    case scheduled
    case active
    case completed
    case endedEarly

    var isLiveConfiguration: Bool {
        self == .draft || self == .scheduled || self == .active
    }
}

struct CloudRetreatVersion: Codable, Equatable, Identifiable {
    var id = UUID()
    var number: Int
    var createdAt: Date
    var blockingGroups: [CloudBlockingGroup]
    var modificationPolicy: CloudRuleLockdownPreference
}

struct CloudRetreatRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var versionNumber: Int
    var actualStart: Date
    var actualEnd: Date?
    var terminalState: CloudRetreatState?
}

struct CloudRetreat: Codable, Equatable, Identifiable {
    var id = UUID()
    var modifiedAt = Date()
    var name = "Retreat"
    var goal = ""
    var plannedStart = Date()
    var plannedEnd = Date().addingTimeInterval(24 * 60 * 60)
    var state: CloudRetreatState = .draft
    var modificationPolicy = CloudRuleLockdownPreference()
    var versions: [CloudRetreatVersion] = []
    var currentVersionNumber = 0
    var runs: [CloudRetreatRun] = []

    var currentVersion: CloudRetreatVersion? {
        versions.first { $0.number == currentVersionNumber } ?? versions.max { $0.number < $1.number }
    }

    func isActive(at date: Date) -> Bool {
        (state == .scheduled || state == .active) && date >= plannedStart && date < plannedEnd
    }

    mutating func appendVersion(
        blockingGroups: [CloudBlockingGroup],
        modificationPolicy: CloudRuleLockdownPreference,
        at date: Date = Date()
    ) {
        currentVersionNumber = max(currentVersionNumber, versions.map(\.number).max() ?? 0) + 1
        versions.append(CloudRetreatVersion(
            number: currentVersionNumber,
            createdAt: date,
            blockingGroups: blockingGroups,
            modificationPolicy: modificationPolicy
        ))
        self.modificationPolicy = modificationPolicy
        modifiedAt = date
    }

    mutating func start(at date: Date = Date()) {
        guard state == .draft || state == .scheduled else { return }
        guard date < plannedEnd else { return }
        if date < plannedStart {
            state = .scheduled
            modifiedAt = date
            return
        }
        state = .active
        modifiedAt = date
        runs.append(CloudRetreatRun(versionNumber: currentVersionNumber, actualStart: date))
    }

    mutating func reconcile(at date: Date = Date()) {
        guard state == .scheduled || state == .active else { return }

        if state == .scheduled, date >= plannedStart {
            state = .active
            if runs.last?.actualEnd != nil || runs.isEmpty {
                runs.append(CloudRetreatRun(
                    versionNumber: currentVersionNumber,
                    actualStart: plannedStart
                ))
            }
            modifiedAt = max(modifiedAt, plannedStart)
        }

        if state == .active, date >= plannedEnd {
            finish(early: false, at: plannedEnd)
        }
    }

    mutating func finish(early: Bool, at date: Date = Date()) {
        guard state == .active else { return }
        state = early ? .endedEarly : .completed
        modifiedAt = date
        if let index = runs.indices.last {
            runs[index].actualEnd = date
            runs[index].terminalState = state
        }
    }
}

struct CloudRetreatChangePolicy: Equatable, Sendable {
    var requiresAuthorization: Bool
    var unlockDelayDays: Int
    var repeatConfirmations: Bool
    var passageWordCount: Int
    var confirmationWindowHours: Int
    var editWindowHours: Int
}

/// Centralizes the weakening boundary for an active Retreat. UI buttons are
/// only conveniences; every model mutation must pass this gate so a direct or
/// stale callback cannot end protected enforcement early.
enum CloudRetreatEarlyEndGate {
    static func policy(
        for retreat: CloudRetreat,
        appDefault: CloudRuleLockdownPreference
    ) -> CloudRetreatChangePolicy {
        // Ending early weakens the same active Retreat configuration as an
        // edit. Keep one source of truth: the Retreat change policy.
        let effective = CloudRuleLockdownPreference.restrictiveMaximum(
            [retreat.modificationPolicy, retreat.currentVersion?.modificationPolicy]
                .compactMap { $0 },
            appDefault: appDefault
        )
        return CloudRetreatChangePolicy(
            requiresAuthorization: effective.severity != "none",
            unlockDelayDays: max(0, effective.unlockDelayDays),
            repeatConfirmations: effective.severity == "repeatedConfirmations",
            passageWordCount: max(20, effective.passageWordCount),
            confirmationWindowHours: max(1, effective.confirmationWindowHours),
            editWindowHours: max(1, effective.editWindowHours)
        )
    }

    static func canEndEarly(
        _ retreat: CloudRetreat,
        authorizationIsUnlocked: Bool,
        appDefault: CloudRuleLockdownPreference
    ) -> Bool {
        guard retreat.state == .active else { return false }
        let changePolicy = policy(for: retreat, appDefault: appDefault)
        return !changePolicy.requiresAuthorization || authorizationIsUnlocked
    }
}

struct CloudTimeWindowTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var modifiedAt = Date()
    var name = "Schedule template"
    var value = CloudTimeWindowPlan()

    func makeIndependentCopy() -> CloudTimeWindowPlan {
        var copy = value
        copy.id = UUID()
        copy.slots = copy.slots.map {
            CloudTimeWindow(weekdays: $0.weekdays, startMinutes: $0.startMinutes, endMinutes: $0.endMinutes)
        }
        return copy
    }
}

struct CloudDomainPreference: Codable, Equatable, Identifiable {
    var domain: String
    var category: String
    var source: String
    var id: String { domain }
}

struct CloudRuleLockdownPreference: Codable, Equatable {
    var severity = "appDefault"
    var unlockDelayDays = 3
    var passageWordCount = 40
    var confirmationWindowHours = 24
    var editWindowHours = 24
    var allowsTimeExtensions = false
    var maximumTimeExtensionHours = 3
    var temporaryAllowanceResetDays: Int? = nil
    var temporaryAccessPassageWordCount: Int? = nil

    var effectiveTemporaryAccessPassageWordCount: Int {
        min(300, max(20, temporaryAccessPassageWordCount ?? passageWordCount))
    }
}

extension CloudRuleLockdownPreference {
    private enum CodingKeys: String, CodingKey {
        case severity, unlockDelayDays, passageWordCount
        case confirmationWindowHours, editWindowHours
        case allowsTimeExtensions, maximumTimeExtensionHours
        case temporaryAllowanceResetDays
        case temporaryAccessPassageWordCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        severity = try values.decodeIfPresent(String.self, forKey: .severity) ?? "appDefault"
        unlockDelayDays = try values.decodeIfPresent(Int.self, forKey: .unlockDelayDays) ?? 3
        passageWordCount = try values.decodeIfPresent(Int.self, forKey: .passageWordCount) ?? 40
        confirmationWindowHours = try values.decodeIfPresent(Int.self, forKey: .confirmationWindowHours) ?? 24
        editWindowHours = try values.decodeIfPresent(Int.self, forKey: .editWindowHours) ?? 24
        allowsTimeExtensions = try values.decodeIfPresent(Bool.self, forKey: .allowsTimeExtensions) ?? false
        maximumTimeExtensionHours = try values.decodeIfPresent(Int.self, forKey: .maximumTimeExtensionHours) ?? 3
        temporaryAllowanceResetDays = try values.decodeIfPresent(Int.self, forKey: .temporaryAllowanceResetDays).map { min(365, max(1, $0)) }
        temporaryAccessPassageWordCount = try values.decodeIfPresent(Int.self, forKey: .temporaryAccessPassageWordCount).map { min(300, max(20, $0)) }
    }

    static func restrictiveMaximum(
        _ policies: [CloudRuleLockdownPreference],
        appDefault: CloudRuleLockdownPreference = CloudRuleLockdownPreference(severity: "none")
    ) -> CloudRuleLockdownPreference {
        let resolved = policies.map { policy in
            guard policy.severity == "appDefault" else { return policy }
            var value = appDefault
            // App default selects the edit-lock policy; these controls are
            // explicitly configured on the group and must not vanish.
            value.allowsTimeExtensions = policy.allowsTimeExtensions
            value.maximumTimeExtensionHours = policy.maximumTimeExtensionHours
            value.temporaryAllowanceResetDays = policy.temporaryAllowanceResetDays
            value.temporaryAccessPassageWordCount = policy.temporaryAccessPassageWordCount
            return value
        }
        let enabled = resolved.filter { $0.severity != "none" }
        // A group's edit-lock severity and its temporary-access permission are
        // independent. An unlocked group may still require escalating passages
        // for allowances; do not discard that explicit opt-in during compilation.
        let accessPolicies = resolved.filter(\.allowsTimeExtensions)
        guard !enabled.isEmpty else {
            return CloudRuleLockdownPreference(
                severity: "none",
                passageWordCount: accessPolicies.map(\.passageWordCount).max() ?? 40,
                allowsTimeExtensions: !accessPolicies.isEmpty,
                maximumTimeExtensionHours: accessPolicies.map(\.maximumTimeExtensionHours).min() ?? 3,
                temporaryAllowanceResetDays: accessPolicies.compactMap(\.temporaryAllowanceResetDays).max(),
                temporaryAccessPassageWordCount: accessPolicies.contains { $0.temporaryAccessPassageWordCount != nil }
                    ? accessPolicies.map(\.effectiveTemporaryAccessPassageWordCount).max() : nil
            )
        }

        let delay = enabled.map { policy in
            policy.severity == "passageOnly" ? 0 : max(0, policy.unlockDelayDays)
        }.max() ?? 0
        let repeats = enabled.contains { $0.severity == "repeatedConfirmations" }
        let severity = repeats ? "repeatedConfirmations" : (delay > 0 ? "delayed" : "passageOnly")
        return CloudRuleLockdownPreference(
            severity: severity,
            unlockDelayDays: delay,
            passageWordCount: enabled.map(\.passageWordCount).max() ?? 40,
            confirmationWindowHours: enabled.map(\.confirmationWindowHours).min() ?? 24,
            editWindowHours: enabled.map(\.editWindowHours).min() ?? 24,
            allowsTimeExtensions: enabled.allSatisfy(\.allowsTimeExtensions),
            maximumTimeExtensionHours: (enabled + accessPolicies).map(\.maximumTimeExtensionHours).min() ?? 3,
            temporaryAllowanceResetDays: accessPolicies.compactMap(\.temporaryAllowanceResetDays).max(),
            temporaryAccessPassageWordCount: accessPolicies.contains { $0.temporaryAccessPassageWordCount != nil }
                ? accessPolicies.map(\.effectiveTemporaryAccessPassageWordCount).max() : nil
        )
    }
}

/// Advisory only: compare permanent-edit friction with a timed exception.
/// A real wait/checkpoint is not ordered below a passage-only exception.
enum TemporaryAccessPolicyComparison {
    static func warning(changePolicy: CloudRuleLockdownPreference,
                        temporaryPolicy: CloudRuleLockdownPreference,
                        nextPassageWords: Int? = nil) -> String? {
        guard temporaryPolicy.allowsTimeExtensions else { return nil }
        if changePolicy.severity == "appDefault" {
            return "Change protection uses the app default. If it requires no wait and an equal or shorter passage, editing the group can bypass temporary access."
        }
        if changePolicy.severity == "none" {
            return "Change protection is weaker than temporary access: this group can be disabled or edited without confirmation. Temporary access still requires a passage."
        }
        guard changePolicy.severity == "passageOnly" || changePolicy.unlockDelayDays == 0 else { return nil }
        let temporaryWords = max(temporaryPolicy.effectiveTemporaryAccessPassageWordCount, nextPassageWords ?? 0)
        if changePolicy.passageWordCount <= temporaryWords {
            return "Changing or disabling this group takes \(changePolicy.passageWordCount) words with no wait; temporary access takes \(temporaryWords). The change policy is no harder, but can remove restrictions permanently. Increase change protection if that is not intended."
        }
        if temporaryPolicy.temporaryAllowanceResetDays != nil {
            return "Backoff can eventually make temporary access require more words than the \(changePolicy.passageWordCount)-word change passage. With no edit wait, changing the group could then be easier than taking a timed exception."
        }
        return nil
    }
}

struct CloudRuleTombstone: Codable, Equatable, Identifiable {
    var id: UUID
    var modifiedAt: Date
}

enum ICloudPreferencesError: LocalizedError {
    case documentTooLarge(Int)
    case corruptDocument

    var errorDescription: String? {
        switch self {
        case let .documentTooLarge(bytes):
            "The iCloud preference document is too large (\(bytes) bytes). Remove rules or domains."
        case .corruptDocument:
            "The iCloud preference document could not be decoded."
        }
    }
}

final class ICloudPreferencesStore {
    static let documentKey = "executive-dysfunction.preferences.v1"
    static let maximumDocumentBytes = 900_000

    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    func load() throws -> CloudPreferencesDocument {
        guard let data = store.data(forKey: Self.documentKey) else {
            return CloudPreferencesDocument()
        }
        guard var document = try? JSONDecoder().decode(CloudPreferencesDocument.self, from: data) else {
            throw ICloudPreferencesError.corruptDocument
        }
        document.migrateLegacyRulesIfNeeded()
        document.reconcileRetreatLifecycles()
        document.migrateBlockingGroupOwnership()
        return document
    }

    func save(_ document: CloudPreferencesDocument) throws {
        var document = document
        document.migrateLegacyRulesIfNeeded()
        document.migrateBlockingGroupOwnership()
        document.rebuildLegacyRuleProjection()
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw ICloudPreferencesError.documentTooLarge(data.count)
        }
        store.set(data, forKey: Self.documentKey)
        store.synchronize()
    }

    func merge(
        rules: [CloudRulePreference] = [],
        tombstones: [CloudRuleTombstone] = []
    ) throws -> CloudPreferencesDocument {
        var document = try load()
        rules.forEach { document.merge(rule: $0) }
        tombstones.forEach { document.merge(tombstone: $0) }
        try save(document)
        return document
    }
}
