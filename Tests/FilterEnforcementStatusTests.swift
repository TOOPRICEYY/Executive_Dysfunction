import XCTest
@testable import ExecutiveDysfunctionMac

/// The readout exists to make silent failures loud, so its job is to be
/// pessimistic: anything short of "the filter says it is on the current
/// revision" must not read as healthy.
final class FilterEnforcementStatusTests: XCTestCase {
    func testBehindRevisionIsReportedAsUnhealthy() {
        // Exactly the live failure: the app published a policy the filter
        // rejected, so newly added domains never blocked.
        let health = FilterEnforcementSummary.health(
            published: 183,
            status: status(revision: 104, at: now),
            now: now
        )
        XCTAssertEqual(health, .behind(published: 183, enforcing: 104))
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("183"))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("104"))
    }

    func testMissingReportIsUnhealthy() {
        let health = FilterEnforcementSummary.health(published: 5, status: nil)
        XCTAssertEqual(health, .notReporting)
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    func testStaleHeartbeatIsUnhealthy() {
        let old = now.addingTimeInterval(-(FilterEnforcementSummary.staleAfter + 30))
        let health = FilterEnforcementSummary.health(
            published: 10,
            status: status(revision: 10, at: old),
            now: now
        )
        guard case .stale = health else { return XCTFail("Expected stale, got \(health)") }
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    /// A stopped filter must not look healthy just because its last report
    /// happened to carry the current revision.
    func testStalenessOutranksAMatchingRevision() {
        let old = now.addingTimeInterval(-(FilterEnforcementSummary.staleAfter + 1))
        let health = FilterEnforcementSummary.health(
            published: 42,
            status: status(revision: 42, at: old),
            now: now
        )
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    func testCurrentRevisionWithActiveRuleIsHealthy() {
        let health = FilterEnforcementSummary.health(
            published: 183,
            status: status(revision: 183, at: now, domains: ["a.example", "b.example"]),
            now: now
        )
        XCTAssertEqual(health, .enforcing(revision: 183, domains: 2, rules: 1))
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
    }

    /// A filter ahead of this app's counter is fine; the iPhone can publish too.
    func testFilterAheadOfPublishedRevisionIsHealthy() {
        let health = FilterEnforcementSummary.health(
            published: 100,
            status: status(revision: 120, at: now, domains: ["a.example"]),
            now: now
        )
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
    }

    func testIdleIsHealthyButSaysNoRuleIsInForce() {
        let health = FilterEnforcementSummary.health(
            published: 7,
            status: status(revision: 7, at: now, domains: [], windowActive: false),
            now: now
        )
        XCTAssertEqual(health, .idle(revision: 7))
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("No website rule"))
    }

    func testStatusCountsOnlyActiveRulesAndDomains() {
        let policy = DesktopEnforcementPolicy(
            revision: 3,
            issuedAt: now,
            rules: [
                rule(domains: ["live.example"], windowActive: true),
                rule(domains: ["dormant.example"], windowActive: false)
            ]
        )
        let snapshot = FilterEnforcementStatus(policy: policy, at: now)
        XCTAssertEqual(snapshot.ruleCount, 2)
        XCTAssertEqual(snapshot.activeRuleCount, 1)
        XCTAssertEqual(snapshot.activeDomainCount, 1)
        XCTAssertTrue(snapshot.hasActiveWebRestrictions)
    }

    func testStatusSurvivesEncodingRoundTrip() throws {
        let original = status(revision: 9, at: now, domains: ["a.example"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(
            FilterEnforcementStatus.self,
            from: try encoder.encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Helpers

    private var now: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 12).date!
    }

    private func status(
        revision: UInt64,
        at date: Date,
        domains: Set<String> = ["a.example"],
        windowActive: Bool = true
    ) -> FilterEnforcementStatus {
        FilterEnforcementStatus(
            policy: DesktopEnforcementPolicy(
                revision: revision,
                issuedAt: date,
                rules: [rule(domains: domains, windowActive: windowActive)]
            ),
            at: date
        )
    }

    private func rule(domains: Set<String>, windowActive: Bool) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(),
            name: "Test",
            isEnabled: true,
            enforcementMode: .blockList,
            windows: [
                windowActive
                    ? DesktopTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_439)
                    : DesktopTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1)
            ],
            domains: domains,
            macApplicationIdentifiers: [],
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(
                severity: "appDefault",
                unlockDelayDays: 3,
                passageWordCount: 40,
                confirmationWindowHours: 24,
                editWindowHours: 24,
                allowsTimeExtensions: false,
                maximumTimeExtensionHours: 3
            )
        )
    }
}
