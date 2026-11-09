import Foundation

/// The part of a diagnostic report that both platforms build identically.
///
/// iOS and macOS enforce through unrelated machinery, but they share one object
/// graph, and most cross-device confusion is really disagreement about that
/// graph. Building these sections from one implementation is what makes an
/// iPhone report and a Mac report directly comparable: if the two disagree
/// here, the sync is the fault, not the enforcement.
enum HoldfastDiagnosticDocumentSections {
    /// iOS caps concurrent Device Activity schedules. The limit is a property of
    /// Screen Time, but the count that will breach it is a property of the
    /// document, so it is worth reporting from either device.
    static let deviceActivityMonitorBudget = 20

    static func sections(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor,
        now: Date = Date()
    ) -> [HoldfastDiagnosticSection] {
        [
            documentSection(document: document, now: now),
            activityGroupsSection(document: document, redactor: redactor),
            blockingGroupsSection(document: document, redactor: redactor, now: now),
            derivedWindowsSection(document: document, redactor: redactor),
            retreatsSection(document: document, redactor: redactor, now: now)
        ]
    }

    static func warnings(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor,
        now: Date = Date()
    ) -> [HoldfastDiagnosticWarning] {
        var warnings: [HoldfastDiagnosticWarning] = []

        let unlinked = document.baseline.blockingGroups.filter { $0.activityGroupIDs.isEmpty }
        if !unlinked.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "blocking-group.no-activity-groups",
                severity: .warning,
                message: "\(unlinked.count) Blocking Group(s) link no Activity Group and therefore compile to no rule at all: "
                    + unlinked.map { redactor.userContent($0.name) }.joined(separator: ", "),
                hint: "Open each one and link at least one Activity Group, or delete it."
            ))
        }

        let knownGroupIDs = Set(document.activityGroups.map(\.id))
        let dangling = document.baseline.blockingGroups.filter { group in
            !group.activityGroupIDs.isEmpty
                && !group.activityGroupIDs.allSatisfy(knownGroupIDs.contains)
        }
        if !dangling.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "blocking-group.dangling-activity-reference",
                severity: .critical,
                message: "\(dangling.count) Blocking Group(s) reference an Activity Group that no longer exists. "
                    + "The missing targets are silently dropped when the rule is compiled.",
                hint: "This usually means a deletion did not propagate. Compare the Activity Group list against the other device."
            ))
        }

        let empty = document.activityGroups.filter {
            $0.deviceLocalSelectionCount == 0
                && $0.domains.isEmpty
                && $0.websiteCategories.isEmpty
                && $0.macApplicationIdentifiers.isEmpty
        }
        if !empty.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "activity-group.empty",
                severity: .warning,
                message: "\(empty.count) Activity Group(s) select nothing on any platform, so any rule built from them enforces nothing: "
                    + empty.map { redactor.userContent($0.name) }.joined(separator: ", "),
                hint: "Screen Time picker selections are stored per device. An Activity Group chosen on iPhone shows zero here on a Mac, which is expected."
            ))
        }

        let windowCount = derivedWindows(document: document).count
        if windowCount > deviceActivityMonitorBudget {
            warnings.append(HoldfastDiagnosticWarning(
                code: "schedule.exceeds-monitor-budget",
                severity: .critical,
                message: "The enabled schedule compiles to \(windowCount) time blocks, above the Screen Time budget of "
                    + "\(deviceActivityMonitorBudget) concurrent monitors. On iPhone the excess blocks cannot be monitored.",
                hint: "An allowance-painted schedule is stored as its complement, so a few allowed windows can expand into many blocking windows. Merge time blocks or reduce the number of enabled Blocking Groups."
            ))
        }

        let overdue = document.retreats.filter { $0.state == .active && $0.plannedEnd < now }
        if !overdue.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "retreat.past-planned-end",
                severity: .warning,
                message: "\(overdue.count) Retreat(s) are still active past their planned end.",
                hint: "Reconciliation runs on launch and on refresh. If this persists after a refresh, the lifecycle is not advancing."
            ))
        }

        // A monitor and its shield store are keyed by the group and the window
        // together, so two groups may legitimately share a window identity. Only
        // a repeat of the whole pair is a collision.
        struct MonitorKey: Hashable {
            var groupID: UUID
            var windowID: UUID
        }
        var seen: Set<MonitorKey> = []
        var duplicated: Set<MonitorKey> = []
        for entry in derivedWindows(document: document) {
            let key = MonitorKey(groupID: entry.group.id, windowID: entry.window.id)
            if !seen.insert(key).inserted { duplicated.insert(key) }
        }
        if !duplicated.isEmpty {
            warnings.append(HoldfastDiagnosticWarning(
                code: "schedule.duplicate-window-identity",
                severity: .critical,
                message: "\(duplicated.count) time block(s) resolve to an identity another block in the same group already uses. "
                    + "Device Activity monitors and shield stores are keyed by that pair, so these collide: one block's monitor lifts the other's shield.",
                hint: "Two time blocks within one Blocking Group must not produce the same identity."
            ))
        }

        return warnings
    }

    /// Every blocking window the document currently compiles to, paired with the
    /// group it came from. This is the exact set the iPhone turns into monitors.
    static func derivedWindows(
        document: CloudPreferencesDocument
    ) -> [(group: CloudBlockingGroup, window: CloudTimeWindow)] {
        document.baseline.blockingGroups
            .filter(\.isEnabled)
            .flatMap { group in
                group.timeWindow.effectiveBlockingSlots().map { (group: group, window: $0) }
            }
    }

    private static func documentSection(
        document: CloudPreferencesDocument,
        now: Date
    ) -> HoldfastDiagnosticSection {
        HoldfastDiagnosticSection(
            title: "Document",
            explanation: "The portable object graph, as this device currently holds it.",
            rows: [
                HoldfastDiagnosticRow("schema version", document.schemaVersion),
                HoldfastDiagnosticRow("activity groups", document.activityGroups.count),
                HoldfastDiagnosticRow("blocking groups", document.baseline.blockingGroups.count),
                HoldfastDiagnosticRow("blocking groups enabled", document.baseline.blockingGroups.filter(\.isEnabled).count),
                HoldfastDiagnosticRow("retreats", document.retreats.count),
                HoldfastDiagnosticRow("retreats active", document.retreats.filter { $0.isActive(at: now) }.count),
                HoldfastDiagnosticRow("compiled rules", document.rules.count),
                HoldfastDiagnosticRow("tombstones", document.tombstones.count),
                HoldfastDiagnosticRow("baseline modified", document.baseline.modifiedAt),
                HoldfastDiagnosticRow("derived time blocks", derivedWindows(document: document).count),
                HoldfastDiagnosticRow("monitor budget", deviceActivityMonitorBudget)
            ]
        )
    }

    private static func activityGroupsSection(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Activity Groups",
            columns: ["id", "name", "picker", "domains", "categories", "mac apps", "modified"],
            rows: document.activityGroups.map { group in
                [
                    redactor.identifier(group.id),
                    redactor.userContent(group.name),
                    String(group.deviceLocalSelectionCount),
                    String(group.domains.count),
                    String(group.websiteCategories.count),
                    String(group.macApplicationIdentifiers.count),
                    HoldfastDiagnosticReport.format(group.modifiedAt)
                ]
            },
            emptyMessage: "No Activity Groups."
        )
        return HoldfastDiagnosticSection(
            title: "Activity Groups",
            explanation: "\"picker\" counts opaque Screen Time selections, which are stored per device and never sync.",
            tables: [table]
        )
    }

    private static func blockingGroupsSection(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor,
        now: Date
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Blocking Groups",
            columns: ["id", "name", "on", "mode", "paint", "slots", "derived", "daily", "weekly", "lock"],
            rows: document.baseline.blockingGroups.map { group in
                [
                    redactor.identifier(group.id),
                    redactor.userContent(group.name),
                    group.isEnabled ? "yes" : "no",
                    group.enforcementMode,
                    group.timeWindow.paintMode.rawValue,
                    String(group.timeWindow.slots.count),
                    String(group.timeWindow.effectiveBlockingSlots().count),
                    group.usageBudget.dailyLimitMinutes.map { "\($0)m" } ?? "—",
                    group.usageBudget.weeklyLimitMinutes.map { "\($0)m" } ?? "—",
                    group.modificationPolicy.severity
                ]
            },
            emptyMessage: "No Blocking Groups."
        )
        return HoldfastDiagnosticSection(
            title: "Blocking Groups",
            explanation: "\"slots\" is what the schedule stores; \"derived\" is what it compiles to. "
                + "An allowance-painted plan stores allowed time and derives its complement, so derived is normally the larger number.",
            tables: [table]
        )
    }

    private static func derivedWindowsSection(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        let windows = derivedWindows(document: document)
        let table = HoldfastDiagnosticTable(
            title: "Derived time blocks",
            columns: ["window", "group", "weekdays", "start", "end", "overnight"],
            rows: windows.map { entry in
                [
                    redactor.identifier(entry.window.id),
                    redactor.identifier(entry.group.id),
                    HoldfastDiagnosticReport.formatWeekdays(entry.window.weekdays),
                    HoldfastDiagnosticReport.formatMinutes(entry.window.startMinutes),
                    HoldfastDiagnosticReport.formatMinutes(entry.window.endMinutes),
                    entry.window.endMinutes <= entry.window.startMinutes ? "yes" : "no"
                ]
            },
            emptyMessage: "No enabled Blocking Group produces a time block."
        )
        return HoldfastDiagnosticSection(
            title: "Derived time blocks",
            explanation: "Each row becomes one Device Activity monitor on iPhone. "
                + "The window identity is derived from the schedule it represents, so it must match on both devices for the same rule.",
            tables: [table]
        )
    }

    private static func retreatsSection(
        document: CloudPreferencesDocument,
        redactor: HoldfastDiagnosticRedactor,
        now: Date
    ) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Retreats",
            columns: ["id", "name", "state", "active", "start", "end", "versions", "groups"],
            rows: document.retreats.map { retreat in
                [
                    redactor.identifier(retreat.id),
                    redactor.userContent(retreat.name),
                    retreat.state.rawValue,
                    retreat.isActive(at: now) ? "yes" : "no",
                    HoldfastDiagnosticReport.format(retreat.plannedStart),
                    HoldfastDiagnosticReport.format(retreat.plannedEnd),
                    String(retreat.versions.count),
                    String(retreat.currentVersion?.blockingGroups.count ?? 0)
                ]
            },
            emptyMessage: "No Retreats."
        )
        return HoldfastDiagnosticSection(title: "Retreats", tables: [table])
    }
}
