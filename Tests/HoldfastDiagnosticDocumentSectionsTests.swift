import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class HoldfastDiagnosticDocumentSectionsTests: XCTestCase {
    private let redactor = HoldfastDiagnosticRedactor(.standard)

    private func document(
        activityGroups: [CloudActivityGroup] = [],
        blockingGroups: [CloudBlockingGroup] = [],
        retreats: [CloudRetreat] = []
    ) -> CloudPreferencesDocument {
        var baseline = CloudBaseline()
        baseline.blockingGroups = blockingGroups
        var document = CloudPreferencesDocument()
        document.activityGroups = activityGroups
        document.baseline = baseline
        document.retreats = retreats
        return document
    }

    private func enabledGroup(
        name: String = "Group",
        activityGroupIDs: [UUID] = [UUID()],
        plan: CloudTimeWindowPlan = CloudTimeWindowPlan()
    ) -> CloudBlockingGroup {
        var group = CloudBlockingGroup()
        group.name = name
        group.isEnabled = true
        group.activityGroupIDs = activityGroupIDs
        group.timeWindow = plan
        return group
    }

    // MARK: - Findings

    /// A Blocking Group with no Activity Group compiles to nothing at all, which
    /// looks identical to a rule that is simply not firing.
    func testUnlinkedBlockingGroupIsReported() {
        let subject = document(blockingGroups: [enabledGroup(activityGroupIDs: [])])

        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)

        XCTAssertTrue(warnings.contains { $0.code == "blocking-group.no-activity-groups" })
    }

    /// A reference to a deleted Activity Group is silently dropped at compile
    /// time, so the rule quietly enforces less than it appears to.
    func testDanglingActivityGroupReferenceIsCritical() {
        let subject = document(
            activityGroups: [],
            blockingGroups: [enabledGroup(activityGroupIDs: [UUID()])]
        )

        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)
        let finding = warnings.first { $0.code == "blocking-group.dangling-activity-reference" }

        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.severity, .critical)
    }

    func testWellFormedDocumentReportsNoStructuralFindings() {
        var group = CloudActivityGroup()
        group.deviceLocalSelectionCount = 3
        let subject = document(
            activityGroups: [group],
            blockingGroups: [enabledGroup(activityGroupIDs: [group.id])]
        )

        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)

        XCTAssertFalse(warnings.contains { $0.code == "blocking-group.no-activity-groups" })
        XCTAssertFalse(warnings.contains { $0.code == "blocking-group.dangling-activity-reference" })
        XCTAssertFalse(warnings.contains { $0.code == "activity-group.empty" })
    }

    /// The monitor budget is the ceiling that turns a working schedule into an
    /// unenforceable one, and an allowance-painted plan reaches it quickly.
    func testScheduleBeyondTheMonitorBudgetIsCritical() {
        var activityGroup = CloudActivityGroup()
        activityGroup.deviceLocalSelectionCount = 1

        // Uniform hours collapse: identical ranges are merged into one window
        // carrying every weekday. It takes hours that differ per day for the
        // complement to stay split, which is exactly what painting by hand
        // produces -- two blocking windows for each of the seven days.
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: (1...7).map { weekday in
                CloudTimeWindow(
                    weekdays: [weekday],
                    startMinutes: (8 + weekday) * 60,
                    endMinutes: (10 + weekday) * 60
                )
            }
        )
        let groups = (0..<2).map { index in
            enabledGroup(name: "Group \(index)", activityGroupIDs: [activityGroup.id], plan: plan)
        }
        let subject = document(activityGroups: [activityGroup], blockingGroups: groups)

        let derived = HoldfastDiagnosticDocumentSections.derivedWindows(document: subject)
        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)

        XCTAssertGreaterThan(derived.count, HoldfastDiagnosticDocumentSections.deviceActivityMonitorBudget)
        XCTAssertTrue(warnings.contains { $0.code == "schedule.exceeds-monitor-budget" })
    }

    func testDisabledBlockingGroupsDoNotConsumeTheMonitorBudget() {
        var group = enabledGroup()
        group.isEnabled = false
        let subject = document(blockingGroups: [group])

        XCTAssertTrue(HoldfastDiagnosticDocumentSections.derivedWindows(document: subject).isEmpty)
    }

    func testRetreatPastItsPlannedEndIsReported() {
        var retreat = CloudRetreat()
        retreat.state = .active
        retreat.plannedStart = Date(timeIntervalSinceNow: -86_400)
        retreat.plannedEnd = Date(timeIntervalSinceNow: -3_600)
        let subject = document(retreats: [retreat])

        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)

        XCTAssertTrue(warnings.contains { $0.code == "retreat.past-planned-end" })
    }

    /// A monitor is keyed by its group and its window together, so two Blocking
    /// Groups built from the same schedule are not in conflict.
    func testDistinctGroupsWithIdenticalHoursDoNotCollide() {
        var activityGroup = CloudActivityGroup()
        activityGroup.deviceLocalSelectionCount = 1
        let plan = CloudTimeWindowPlan(
            paintMode: .block,
            slots: [CloudTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)]
        )
        let subject = document(
            activityGroups: [activityGroup],
            blockingGroups: [
                enabledGroup(name: "A", activityGroupIDs: [activityGroup.id], plan: plan),
                enabledGroup(name: "B", activityGroupIDs: [activityGroup.id], plan: plan)
            ]
        )

        let warnings = HoldfastDiagnosticDocumentSections.warnings(document: subject, redactor: redactor)

        XCTAssertFalse(warnings.contains { $0.code == "schedule.duplicate-window-identity" })
    }

    // MARK: - Sections

    func testSectionsDescribeTheGraphWithoutLeakingNames() {
        var activityGroup = CloudActivityGroup()
        activityGroup.name = "Social Feeds"
        activityGroup.deviceLocalSelectionCount = 4
        let subject = document(
            activityGroups: [activityGroup],
            blockingGroups: [enabledGroup(name: "Evening", activityGroupIDs: [activityGroup.id])]
        )

        let sections = HoldfastDiagnosticDocumentSections.sections(document: subject, redactor: redactor)
        let rendered = HoldfastDiagnosticReport(
            platform: "ios",
            redaction: .standard,
            sections: sections
        ).renderedText()

        XCTAssertTrue(sections.contains { $0.title == "Derived time blocks" })
        XCTAssertFalse(rendered.contains("Social Feeds"))
        XCTAssertFalse(rendered.contains("Evening"))
        XCTAssertTrue(rendered.contains("blocking groups enabled"))
    }

    func testFullRedactionKeepsNamesInTheRenderedSections() {
        var activityGroup = CloudActivityGroup()
        activityGroup.name = "Social Feeds"
        let subject = document(activityGroups: [activityGroup])

        let sections = HoldfastDiagnosticDocumentSections.sections(
            document: subject,
            redactor: HoldfastDiagnosticRedactor(.full)
        )
        let rendered = HoldfastDiagnosticReport(
            platform: "ios",
            redaction: .full,
            sections: sections
        ).renderedText()

        XCTAssertTrue(rendered.contains("Social Feeds"))
    }

    /// An overnight window is the case the schedule code has repeatedly got
    /// wrong, so the report has to name it rather than leave it to be inferred
    /// from a start that is later than its end.
    func testDerivedWindowsSectionMarksOvernightBlocks() {
        var activityGroup = CloudActivityGroup()
        activityGroup.deviceLocalSelectionCount = 1
        let plan = CloudTimeWindowPlan(
            paintMode: .block,
            slots: [CloudTimeWindow(weekdays: [6], startMinutes: 22 * 60, endMinutes: 6 * 60)]
        )
        let subject = document(
            activityGroups: [activityGroup],
            blockingGroups: [enabledGroup(activityGroupIDs: [activityGroup.id], plan: plan)]
        )

        let sections = HoldfastDiagnosticDocumentSections.sections(document: subject, redactor: redactor)
        let table = sections
            .first { $0.title == "Derived time blocks" }?
            .tables.first

        XCTAssertEqual(table?.rows.count, 1)
        XCTAssertEqual(table?.rows.first?.last, "yes")
    }
}
