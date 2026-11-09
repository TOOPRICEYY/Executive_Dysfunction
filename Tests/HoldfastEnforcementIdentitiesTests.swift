import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class HoldfastEnforcementIdentitiesTests: XCTestCase {
    func testUsageOnlyRuleSurvivesShieldSweepWithoutWindowIdentities() {
        var legacy = CloudRulePreference(name: "Daily limit", windows: [])
        legacy.usageLimitEnabled = true
        var subject = CloudPreferencesDocument(rules: [legacy])
        subject.migrateLegacyRulesIfNeeded()
        XCTAssertTrue(HoldfastEnforcementIdentities.allWindowIdentities(document: subject).isEmpty)
        XCTAssertEqual(HoldfastEnforcementIdentities.enforcedUsageRuleIDs(document: subject), [legacy.id])
        subject.baseline.blockingGroups[0].usageBudget.dailyLimitMinutes = nil
        XCTAssertTrue(HoldfastEnforcementIdentities.enforcedUsageRuleIDs(document: subject).isEmpty)
    }
    private func group(
        name: String = "Group",
        isEnabled: Bool,
        window: CloudTimeWindow = CloudTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)
    ) -> CloudBlockingGroup {
        var group = CloudBlockingGroup()
        group.name = name
        group.isEnabled = isEnabled
        group.activityGroupIDs = [UUID()]
        group.timeWindow = CloudTimeWindowPlan(paintMode: .block, slots: [window])
        return group
    }

    private func document(
        blockingGroups: [CloudBlockingGroup] = [],
        retreats: [CloudRetreat] = []
    ) -> CloudPreferencesDocument {
        var baseline = CloudBaseline()
        baseline.blockingGroups = blockingGroups
        var document = CloudPreferencesDocument()
        document.baseline = baseline
        document.retreats = retreats
        return document
    }

    private func retreat(
        state: CloudRetreatState,
        groups: [CloudBlockingGroup],
        start: Date = Date(timeIntervalSinceNow: -86_400),
        end: Date = Date(timeIntervalSinceNow: 86_400)
    ) -> CloudRetreat {
        var retreat = CloudRetreat()
        retreat.state = state
        retreat.plannedStart = start
        retreat.plannedEnd = end
        retreat.currentVersionNumber = 1
        retreat.versions = [CloudRetreatVersion(
            number: 1,
            createdAt: start,
            blockingGroups: groups,
            modificationPolicy: CloudRuleLockdownPreference()
        )]
        return retreat
    }

    /// A switched-off group keeps its stores. Nothing in the live schedule names
    /// them, so without this they can never be cleared.
    func testDisabledBaselineGroupIsReachableButNotEnforceable() {
        let disabled = group(isEnabled: false)
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(blockingGroups: [disabled])
        )

        XCTAssertFalse(identities.isEmpty)
        XCTAssertTrue(identities.allSatisfy { $0.groupID == disabled.id })
        XCTAssertTrue(identities.allSatisfy { !$0.isCurrentlyEnforceable })
    }

    func testEnabledBaselineGroupIsEnforceable() {
        let enabled = group(isEnabled: true)
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(blockingGroups: [enabled])
        )

        XCTAssertTrue(identities.contains { $0.isCurrentlyEnforceable })
    }

    /// A Retreat's groups are independent copies with their own identities. When
    /// the Retreat ends they leave the compiled rules entirely, and their
    /// shields would otherwise stay applied with nothing to lift them.
    func testEndedRetreatGroupsRemainReachableForSweeping() {
        let retreatGroup = group(name: "Retreat copy", isEnabled: true)
        let ended = retreat(state: .endedEarly, groups: [retreatGroup])
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(retreats: [ended])
        )

        let matching = identities.filter { $0.groupID == retreatGroup.id }
        XCTAssertFalse(matching.isEmpty, "An ended Retreat's identities must stay reachable")
        XCTAssertTrue(matching.allSatisfy { !$0.isCurrentlyEnforceable })
    }

    func testActiveRetreatCurrentVersionIsEnforceable() {
        let retreatGroup = group(name: "Retreat copy", isEnabled: true)
        let active = retreat(state: .active, groups: [retreatGroup])
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(retreats: [active])
        )

        XCTAssertTrue(identities.contains { $0.groupID == retreatGroup.id && $0.isCurrentlyEnforceable })
    }

    /// Superseded versions name identities no rule mentions any more.
    func testSupersededRetreatVersionsAreReachableButNotEnforceable() {
        let oldGroup = group(name: "v1", isEnabled: true)
        let currentGroup = group(name: "v2", isEnabled: true)
        var active = retreat(state: .active, groups: [currentGroup])
        active.currentVersionNumber = 2
        active.versions = [
            CloudRetreatVersion(
                number: 1,
                createdAt: Date(timeIntervalSinceNow: -172_800),
                blockingGroups: [oldGroup],
                modificationPolicy: CloudRuleLockdownPreference()
            ),
            CloudRetreatVersion(
                number: 2,
                createdAt: Date(timeIntervalSinceNow: -86_400),
                blockingGroups: [currentGroup],
                modificationPolicy: CloudRuleLockdownPreference()
            )
        ]

        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(retreats: [active])
        )

        XCTAssertTrue(identities.contains { $0.groupID == oldGroup.id && !$0.isCurrentlyEnforceable })
        XCTAssertTrue(identities.contains { $0.groupID == currentGroup.id && $0.isCurrentlyEnforceable })
    }

    /// The sweep clears everything not enforceable, so an identity that is live
    /// anywhere must never also appear as sweepable.
    func testAnIdentityLiveAnywhereIsNeverAlsoSweepable() {
        let shared = group(isEnabled: true)
        let active = retreat(state: .active, groups: [shared])
        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(blockingGroups: [shared], retreats: [active])
        )

        let forGroup = identities.filter { $0.groupID == shared.id }
        let sweepable = forGroup.filter { !$0.isCurrentlyEnforceable }
        let enforceableWindows = Set(forGroup.filter(\.isCurrentlyEnforceable).map(\.windowID))

        XCTAssertTrue(
            sweepable.allSatisfy { !enforceableWindows.contains($0.windowID) },
            "A live identity must not also be offered for sweeping"
        )
    }

    /// The paint mode decides whether stored slots or derived windows were used
    /// as the identity, and a document can contain shields written under either.
    func testBothStoredAndDerivedWindowsAreReachable() {
        var allowGroup = group(isEnabled: false)
        allowGroup.timeWindow = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [2], startMinutes: 18 * 60, endMinutes: 20 * 60)]
        )
        let storedID = allowGroup.timeWindow.slots[0].id
        let derivedIDs = Set(allowGroup.timeWindow.effectiveBlockingSlots().map(\.id))

        let identities = HoldfastEnforcementIdentities.allWindowIdentities(
            document: document(blockingGroups: [allowGroup])
        )
        let windowIDs = Set(identities.map(\.windowID))

        XCTAssertTrue(windowIDs.contains(storedID), "The stored slot identity must be reachable")
        XCTAssertTrue(derivedIDs.isSubset(of: windowIDs), "Derived identities must be reachable")
    }

    func testRuleIdentitiesCoverBaselineAndEveryRetreatVersion() {
        let baselineGroup = group(isEnabled: true)
        let retreatGroup = group(name: "Retreat copy", isEnabled: true)
        let ended = retreat(state: .completed, groups: [retreatGroup])

        let identities = HoldfastEnforcementIdentities.allRuleIdentities(
            document: document(blockingGroups: [baselineGroup], retreats: [ended])
        )

        XCTAssertTrue(identities.contains(baselineGroup.id))
        XCTAssertTrue(identities.contains(retreatGroup.id))
    }
}
