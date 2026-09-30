import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class TemporaryAllowanceBackoffTests: XCTestCase {
    func testSessionFloorSurvivesPeriodicReset() {
        let now = Date()
        XCTAssertEqual(TemporaryAllowanceBackoff.wordCount(base: 40,
            history: .init(startedAt: now.addingTimeInterval(-86_400), grants: 3), resetDays: 1,
            at: now, sessionWordCount: 320), 320)
    }

    func testChangePolicyWarningForEqualWeakerDelayedAndDisabledAccess() {
        var change = CloudRuleLockdownPreference(severity: "passageOnly", passageWordCount: 40)
        var access = CloudRuleLockdownPreference(allowsTimeExtensions: true, temporaryAccessPassageWordCount: 40)
        XCTAssertNotNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        change.passageWordCount = 20
        XCTAssertNotNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        change.passageWordCount = 80
        XCTAssertNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        access.temporaryAllowanceResetDays = 7
        XCTAssertNotNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        change.severity = "delayed"
        change.unlockDelayDays = 1
        XCTAssertNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        change.severity = "none"
        XCTAssertNotNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
        access.allowsTimeExtensions = false
        XCTAssertNil(TemporaryAccessPolicyComparison.warning(changePolicy: change, temporaryPolicy: access))
    }

    func testIndependentPassageMigrationAndPortableTargets() throws {
        let old = try JSONDecoder().decode(CloudRuleLockdownPreference.self, from: Data("{\"passageWordCount\":80}".utf8))
        XCTAssertNil(old.temporaryAccessPassageWordCount)
        XCTAssertEqual(old.effectiveTemporaryAccessPassageWordCount, 80)
        var explicit = old
        explicit.allowsTimeExtensions = true
        explicit.temporaryAccessPassageWordCount = 30
        let effective = CloudRuleLockdownPreference.restrictiveMaximum([explicit])
        XCTAssertEqual(effective.effectiveTemporaryAccessPassageWordCount, 30)
        var rule = CloudRulePreference()
        rule.macApplicationIdentifiers = ["com.example.app"]
        var renamed = rule
        renamed.name = "New label"
        XCTAssertTrue(CloudPortableTargetRestriction.canReplace(rule, with: renamed))
        renamed.macApplicationIdentifiers = []
        XCTAssertFalse(CloudPortableTargetRestriction.canReplace(rule, with: renamed))
    }
    func testLinearSequencePersistsAcrossReloadAndResetsAtFixedBoundary() throws {
        let suite = "backoff-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), other = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<4 {
            let now = start.addingTimeInterval(Double(index) * 3_600)
            let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(TemporaryAllowanceBackoff.wordCount(base: 30,
                history: TemporaryAllowanceBackoff.history(for: id, defaults: reloaded), resetDays: 2, at: now), 30 * (index + 1))
            TemporaryAllowanceBackoff.recordGrant(for: id, resetDays: 2, at: now, defaults: defaults)
        }
        let history = try XCTUnwrap(TemporaryAllowanceBackoff.history(for: id, defaults: defaults))
        XCTAssertEqual(history.startedAt, start)
        XCTAssertNil(TemporaryAllowanceBackoff.history(for: other, defaults: defaults))
        XCTAssertEqual(history.count(at: start.addingTimeInterval(172_799), resetDays: 2), 4)
        XCTAssertEqual(history.count(at: start.addingTimeInterval(172_800), resetDays: 2), 0)
        XCTAssertEqual(history.count(at: start.addingTimeInterval(-3_600), resetDays: 2), 4)
        let next = start.addingTimeInterval(172_800)
        TemporaryAllowanceBackoff.recordGrant(for: id, resetDays: 2, at: next, defaults: defaults)
        XCTAssertEqual(TemporaryAllowanceBackoff.history(for: id, defaults: defaults), .init(startedAt: next, grants: 1))
    }

    func testDecodingOldPoliciesKeepsFeatureOffAndBoundsDays() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(CloudRuleLockdownPreference.self, from: Data("{}".utf8)).temporaryAllowanceResetDays)
        XCTAssertNil(try decoder.decode(RuleLockdownPolicy.self, from: Data("{}".utf8)).temporaryAllowanceResetDays)
        XCTAssertEqual(try decoder.decode(CloudRuleLockdownPreference.self,
            from: Data("{\"temporaryAllowanceResetDays\":9999}".utf8)).temporaryAllowanceResetDays, 365)
        let policy = CloudRuleLockdownPreference(severity: "passageOnly", allowsTimeExtensions: true, temporaryAllowanceResetDays: 7)
        XCTAssertEqual(try decoder.decode(CloudRuleLockdownPreference.self, from: JSONEncoder().encode(policy)), policy)
        XCTAssertEqual(CloudRuleLockdownPreference.restrictiveMaximum([policy,
            .init(severity: "passageOnly", allowsTimeExtensions: true, temporaryAllowanceResetDays: 14)]).temporaryAllowanceResetDays, 14)
    }

    func testLargeCountersCannotOverflowOrCreateUnboundedPassages() {
        XCTAssertEqual(TemporaryAllowanceBackoff.wordCount(base: Int.max,
            history: .init(startedAt: .distantFuture, grants: Int.max), resetDays: 7, at: Date()), TemporaryAllowanceBackoff.maximumWords)
    }

    func testUnlockedGroupKeepsExplicitAllowanceBackoffWithoutWeakeningInheritedDenial() {
        let group = CloudRuleLockdownPreference(severity: "none", allowsTimeExtensions: true,
            maximumTimeExtensionHours: 1, temporaryAllowanceResetDays: 7)
        let result = CloudRuleLockdownPreference.restrictiveMaximum([.init(severity: "none"), group])
        XCTAssertEqual(result.severity, "none")
        XCTAssertTrue(result.allowsTimeExtensions)
        XCTAssertEqual(result.temporaryAllowanceResetDays, 7)
        XCTAssertEqual(result.maximumTimeExtensionHours, 1)
        var inherited = group
        inherited.severity = "appDefault"
        let inheritedResult = CloudRuleLockdownPreference.restrictiveMaximum([inherited])
        XCTAssertTrue(inheritedResult.allowsTimeExtensions)
        XCTAssertEqual(inheritedResult.temporaryAllowanceResetDays, 7)
        let denied = CloudRuleLockdownPreference.restrictiveMaximum([group,
            .init(severity: "passageOnly", allowsTimeExtensions: false)])
        XCTAssertFalse(denied.allowsTimeExtensions)
    }
}
