import XCTest
import FamilyControls
@testable import Holdfast

final class RuleRestrictionTests: XCTestCase {
    func testUnchangedSelectionPreservesOriginalSerialization() throws {
        let selection = FamilyActivitySelection()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var rule = BlockingRule()
        rule.selectionData = try encoder.encode(selection)
        let original = rule.selectionData
        rule.selection = selection
        XCTAssertEqual(rule.selectionData, original)
        var legacy = BlockingRule()
        legacy.selection = selection
        XCTAssertTrue(legacy.selectionData.isEmpty)
        legacy.selectionData = Data("corrupt".utf8)
        legacy.selection = selection
        XCTAssertNoThrow(try JSONDecoder().decode(FamilyActivitySelection.self, from: legacy.selectionData))
    }

    func testRejectionListExcludesEquivalentRecompilationButKeepsTemporaryAccessUnlock() throws {
        let original = BlockingRule()
        var recompiled = original
        recompiled.selectionData = try JSONEncoder().encode(FamilyActivitySelection())
        XCTAssertFalse(RuleRestrictionEvaluator.requiresArchitectureUnlock(
            existing: original, proposed: recompiled, portableDefinitionUnchanged: true, appDefaultLockdown: appDefault))
        XCTAssertFalse(RuleRestrictionEvaluator.requiresArchitectureUnlock(
            existing: original, proposed: recompiled, portableDefinitionUnchanged: false, appDefaultLockdown: appDefault))
        XCTAssertTrue(RuleRestrictionEvaluator.requiresArchitectureUnlock(
            existing: original, proposed: recompiled, portableDefinitionUnchanged: false,
            portableTargetsSameOrStricter: false, appDefaultLockdown: appDefault))
        var weaker = recompiled
        weaker.lockdownPolicy.allowsTimeExtensions = true
        XCTAssertTrue(RuleRestrictionEvaluator.requiresArchitectureUnlock(
            existing: original, proposed: weaker, portableDefinitionUnchanged: true, appDefaultLockdown: appDefault))
    }

    func testBackoffCannotBeRemovedOrResetEarlierWithoutUnlock() {
        var existing = BlockingRule()
        existing.lockdownPolicy.allowsTimeExtensions = true
        existing.lockdownPolicy.temporaryAllowanceResetDays = 7
        var proposed = existing
        proposed.lockdownPolicy.temporaryAllowanceResetDays = nil
        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
        proposed.lockdownPolicy.temporaryAllowanceResetDays = 3
        XCTAssertEqual(compare(existing, proposed), .requiresUnlock)
        proposed.lockdownPolicy.temporaryAllowanceResetDays = 14
        XCTAssertEqual(compare(existing, proposed), .strictlyMoreRestrictive)
        let cloud = CloudRuleBridge.cloudPreference(from: existing)
        XCTAssertEqual(cloud.lockdown.temporaryAllowanceResetDays, 7)
        XCTAssertEqual(CloudRuleBridge.applying(cloud, to: nil).lockdownPolicy.temporaryAllowanceResetDays, 7)
    }

    func testAddingBackoffIsStricterAndAccessPassageIsIndependent() {
        var old = BlockingRule()
        old.lockdownPolicy = .init(severity: .passageOnly, passageWordCount: 40,
            allowsTimeExtensions: true, temporaryAccessPassageWordCount: 20)
        var new = old
        new.lockdownPolicy.temporaryAllowanceResetDays = 1
        XCTAssertEqual(compare(old, new), .strictlyMoreRestrictive)
        new.lockdownPolicy.temporaryAccessPassageWordCount = 60
        XCTAssertEqual(compare(old, new), .strictlyMoreRestrictive)
        XCTAssertEqual(new.lockdownPolicy.configuration(appDefault: appDefault).passageWordCount, 40)
        let cloud = CloudRuleBridge.cloudPreference(from: new)
        XCTAssertEqual(CloudRuleBridge.applying(cloud, to: nil).lockdownPolicy.temporaryAccessPassageWordCount, 60)
        new.lockdownPolicy.passageWordCount = 20
        XCTAssertEqual(compare(old, new), .requiresUnlock, "Stricter temporary access cannot hide weaker edit protection")
    }

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

    func testUnlockReasonsExplainDisabledGroupAndReducedSchedule() {
        var existing = BlockingRule()
        existing.isEnabled = true
        var proposed = existing
        proposed.isEnabled = false
        proposed.windows[0].weekdays.remove(2)

        let reasons = unlockReasons(existing, proposed)

        XCTAssertTrue(reasons.contains("Blocking would be disabled."))
        XCTAssertTrue(reasons.contains { $0.contains("blocked schedule would lose") })
        XCTAssertTrue(reasons.contains { $0.contains("MON 09:00–17:00") })
    }

    func testUnlockReasonsNameRemovedBlockedDomains() {
        var existing = BlockingRule()
        existing.classifiedDomains = [
            ClassifiedDomain(domain: "blocked.example", category: .social, source: .user)
        ]
        existing.websiteCategories = [.social]
        var proposed = existing
        proposed.websiteCategories = []

        let reasons = unlockReasons(existing, proposed)

        XCTAssertTrue(reasons.contains { $0.contains("Blocked domains would be removed: blocked.example") })
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

    private func unlockReasons(
        _ existing: BlockingRule,
        _ proposed: BlockingRule
    ) -> [String] {
        RuleRestrictionEvaluator.unlockRequirementReasons(
            existing: existing,
            proposed: proposed,
            appDefaultLockdown: appDefault
        )
    }
}
