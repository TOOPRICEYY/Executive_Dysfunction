import XCTest
@testable import ExecutiveDysfunction

final class RuleRestrictionTests: XCTestCase {
    private var appDefault: LockdownConfiguration!

    override func setUp() {
        appDefault = LockdownConfiguration()
        appDefault.isEnabled = false
    }

    func testExtendingBlockedTimeIsStrictlyMoreRestrictive() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.windows[0].weekdays.insert(7)

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testRemovingBlockedTimeRequiresUnlock() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.windows[0].weekdays.remove(2)

        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
    }

    func testLoweringEnabledUsageLimitIsStrictlyMoreRestrictive() {
        var existing = BlockingRule()
        existing.usageLimitEnabled = true
        existing.dailyUsageLimitMinutes = 60
        var proposed = existing
        proposed.dailyUsageLimitMinutes = 30

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testMixedStrongerAndWeakerDraftRequiresUnlock() {
        var existing = BlockingRule()
        existing.usageLimitEnabled = true
        existing.dailyUsageLimitMinutes = 60
        var proposed = existing
        proposed.dailyUsageLimitMinutes = 30
        proposed.windows[0].weekdays.remove(2)

        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
    }

    func testAddingExplicitBlockedDomainIsStrictlyMoreRestrictive() {
        var existing = BlockingRule()
        existing.classifiedDomains = [
            ClassifiedDomain(domain: "first.example", category: .social, source: .user)
        ]
        existing.websiteCategories = [.social]
        var proposed = existing
        proposed.classifiedDomains.append(
            ClassifiedDomain(domain: "second.example", category: .social, source: .user)
        )

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testRemovingFortressExceptionIsStrictlyMoreRestrictive() {
        var existing = BlockingRule()
        existing.enforcementMode = .fortressAllowList
        existing.classifiedDomains = [
            ClassifiedDomain(domain: "allowed.example", category: .productivity, source: .user)
        ]
        existing.websiteCategories = [.productivity]
        var proposed = existing
        proposed.websiteCategories = []

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testStrengtheningRuleLockdownIsStrictlyMoreRestrictive() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.lockdownPolicy.severity = .passageOnly

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testEnablingTimeExtensionsRequiresUnlock() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.lockdownPolicy.allowsTimeExtensions = true

        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
    }

    func testDisablingTimeExtensionsIsStrictlyMoreRestrictive() {
        var existing = BlockingRule()
        existing.lockdownPolicy.allowsTimeExtensions = true
        var proposed = existing
        proposed.lockdownPolicy.allowsTimeExtensions = false

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testReducingMaximumExtraHoursIsStrictlyMoreRestrictive() {
        var existing = BlockingRule()
        existing.lockdownPolicy.allowsTimeExtensions = true
        existing.lockdownPolicy.maximumTimeExtensionHours = 4
        var proposed = existing
        proposed.lockdownPolicy.maximumTimeExtensionHours = 2

        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
    }

    func testRenameOnlyIsEquivalentAndStillRequiresNormalUnlockFlow() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.name = "Renamed"

        XCTAssertEqual(compare(existing, proposed), .equivalent)
    }

    func testChangingEnforcementModeIsIncomparable() {
        let existing = BlockingRule()
        var proposed = existing
        proposed.enforcementMode = .fortressAllowList

        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
    }

    private func compare(
        _ existing: BlockingRule,
        _ proposed: BlockingRule
    ) -> RuleRestrictionChange {
        RuleRestrictionEvaluator.compare(
            existing: existing,
            proposed: proposed,
            appDefaultLockdown: appDefault
        )
    }
}
