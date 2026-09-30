import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class CloudPreferencesTests: XCTestCase {
    func testTargetPresentationDoesNotMisreportAppOnlyGroupsAsEmpty() {
        XCTAssertEqual(HoldfastPresentation.targets(nil), "Waiting for synced targets")
        XCTAssertEqual(HoldfastPresentation.targets(.init()), "No apps or websites selected")
        XCTAssertEqual(HoldfastPresentation.targets(.init(macApplicationIdentifiers: ["com.example.app"])), "1 Mac app")
        XCTAssertEqual(HoldfastPresentation.targets(.init(deviceLocalSelectionCount: 2)), "2 Screen Time selections")
        var rule = CloudRulePreference()
        rule.macApplicationIdentifiers = ["com.example.app"]
        XCTAssertEqual(HoldfastPresentation.targets(rule: rule), "1 Mac app")
    }

    func testPolicyAndRetreatPresentationUsesReadableStates() {
        XCTAssertEqual(HoldfastPresentation.state(.endedEarly), "Ended early")
        XCTAssertEqual(HoldfastPresentation.policy("none"), "No confirmation required")
        XCTAssertEqual(HoldfastPresentation.policy("appDefault"), "Use the app-wide change policy")
        XCTAssertEqual(HoldfastPresentation.count(1, "group"), "1 group")
        XCTAssertEqual(HoldfastPresentation.count(2, "group"), "2 groups")
    }

    func testWebsiteInputNormalizesURLsAndRejectsMalformedTargets() {
        XCTAssertEqual(BlockingTargetInput.domain(from: "https://EXAMPLE.com/watch?v=1"), "example.com")
        XCTAssertEqual(BlockingTargetInput.domain(from: "example.org/path"), "example.org")
        XCTAssertEqual(BlockingTargetInput.domain(from: "https://example.com.:443/"), "example.com")
        for invalid in ["not-a-domain", "-bad.com", "bad..com", "https://user:password@example.com", "ftp://example.com", "*.example.com", "https://", "example_.com"] {
            XCTAssertNil(BlockingTargetInput.domain(from: invalid), invalid)
        }
    }

    func testWebsiteInputPreservesExistingMetadataAndCategoryExclusions() {
        let existing = CloudDomainPreference(domain: "example.com", category: "social", source: "user")
        var targets = CloudBlockingTargets(domains: [existing], websiteCategories: [])
        let result = BlockingTargetInput.add("https://EXAMPLE.com/path, example.org\nexample.org; invalid", to: &targets)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.duplicates, 2)
        XCTAssertEqual(result.invalid, ["invalid"])
        XCTAssertEqual(targets.domains.first, existing)
        XCTAssertEqual(targets.domains.map(\.domain), ["example.com", "example.org"])
        XCTAssertEqual(targets.websiteCategories, ["other"], "New sites enforce, but existing exclusions must not be changed")
    }

    func testWebsiteInputEmptyOrInvalidDoesNotMutateTargets() {
        var targets = CloudBlockingTargets(macApplicationIdentifiers: ["com.example.app"])
        let original = targets
        XCTAssertEqual(BlockingTargetInput.add(" \n,; ", to: &targets).added, 0)
        XCTAssertEqual(BlockingTargetInput.add("invalid", to: &targets).invalid, ["invalid"])
        XCTAssertEqual(targets, original)
    }

    func testOwnedBlockingGroupMigrationPreservesEnforcementAndBecomesIndependent() throws {
        var activity = CloudActivityGroup(name: "Imported")
        activity.domains = [.init(domain: "twitter.com", category: "social", source: "user")]
        activity.websiteCategories = ["social"]
        activity.macApplicationIdentifiers = ["com.example.app"]
        activity.modificationPolicy = .init(severity: "delayed", unlockDelayDays: 5, allowsTimeExtensions: false)
        let first = CloudBlockingGroup(name: "One", activityGroupIDs: [activity.id], isEnabled: true,
                                       modificationPolicy: .init(severity: "passageOnly", allowsTimeExtensions: true))
        let second = CloudBlockingGroup(name: "Two", activityGroupIDs: [activity.id], isEnabled: true)
        var baseline = CloudBaseline()
        baseline.blockingGroups = [first, second]
        var document = CloudPreferencesDocument(activityGroups: [activity], baseline: baseline)
        let before = document.compiledRules()
        document.migrateBlockingGroupOwnership()
        XCTAssertEqual(before, document.compiledRules())
        XCTAssertEqual(document.baseline.blockingGroups[0].modificationPolicy.unlockDelayDays, 5)
        XCTAssertFalse(document.baseline.blockingGroups[0].modificationPolicy.allowsTimeExtensions)
        let migrated = document
        document.migrateBlockingGroupOwnership()
        XCTAssertEqual(document, migrated)
        document.baseline.blockingGroups[0].targets?.domains.removeAll()
        XCTAssertEqual(document.baseline.blockingGroups[1].targets?.domains.count, 1)
        document.activityGroups[0].domains.removeAll()
        XCTAssertEqual(document.compiledRules()[1].domains.count, 1, "Old Activity Group edits must not change owned targets")
        let decoded = try JSONDecoder().decode(CloudPreferencesDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testUnusedTargetsAreRetainedAsDisabledBlockingGroups() {
        let activity = CloudActivityGroup(name: "Unused")
        var document = CloudPreferencesDocument(activityGroups: [activity])
        document.migrateBlockingGroupOwnership()
        XCTAssertEqual(document.baseline.blockingGroups.count, 1)
        XCTAssertEqual(document.baseline.blockingGroups[0].name, "Unused")
        XCTAssertFalse(document.baseline.blockingGroups[0].isEnabled)
        XCTAssertNotNil(document.baseline.blockingGroups[0].targets)
        document.baseline.blockingGroups.removeAll()
        document.migrateBlockingGroupOwnership()
        XCTAssertTrue(document.baseline.blockingGroups.isEmpty, "Deleted imported groups must not resurrect from compatibility records")
    }

    func testIncompleteLegacyTargetSyncIsNotSilentlyFlattened() {
        let group = CloudBlockingGroup(activityGroupIDs: [UUID()])
        XCTAssertNil(group.owningTargets(from: []).targets)
    }

    func testTemporaryAccessExplainsUnsavedPermissionInsteadOfContradictingToggle() {
        var saved = CloudBlockingGroup()
        saved.modificationPolicy.severity = "passageOnly"
        var draft = saved
        draft.modificationPolicy.allowsTimeExtensions = true
        let message = TemporaryAccessExplanation.denied(draft: draft, saved: saved, activities: [], containerPolicy: .init(severity: "none"))
        XCTAssertTrue(message.contains("Unsaved changes"))
        XCTAssertTrue(message.contains("saved policy has Allow Temporary Access turned off"))
    }

    func testTemporaryAccessNamesInheritedVetoAndIgnoresUnlinkedGroups() {
        var linked = CloudActivityGroup()
        linked.name = "Twitter"
        linked.modificationPolicy.severity = "passageOnly"
        var unlinked = linked
        unlinked.id = UUID()
        unlinked.name = "Unrelated"
        var saved = CloudBlockingGroup()
        saved.activityGroupIDs = [linked.id]
        saved.modificationPolicy = .init(severity: "passageOnly", allowsTimeExtensions: true)
        let message = TemporaryAccessExplanation.denied(draft: saved, saved: saved, activities: [linked, unlinked], containerPolicy: .init(severity: "none"))
        XCTAssertTrue(message.contains("Twitter"))
        XCTAssertTrue(message.contains("alone cannot override"))
        XCTAssertFalse(message.contains("Unrelated"))
        XCTAssertFalse(message.contains("Unsaved changes"))
    }

    func testMalformedRetreatDateRangeDoesNotCrashDashboard() {
        var subject = CloudPreferencesDocument()
        var retreat = CloudRetreat()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        retreat.state = .scheduled
        retreat.plannedStart = now.addingTimeInterval(7_200)
        retreat.plannedEnd = now.addingTimeInterval(3_600)
        retreat.appendVersion(blockingGroups: [CloudBlockingGroup()], modificationPolicy: CloudRuleLockdownPreference())
        subject.retreats = [retreat]
        XCTAssertTrue(subject.dashboardCalendarRules(at: now).isEmpty)
    }
    func testNewBlockingGroupDefaultsDisabled() {
        XCTAssertFalse(CloudBlockingGroup().isEnabled)
    }

    func testNewerRuleWinsMerge() {
        let id = UUID()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let old = CloudRulePreference(id: id, modifiedAt: oldDate, name: "Old")
        var new = old
        new.modifiedAt = newDate
        new.name = "New"

        var document = CloudPreferencesDocument(rules: [new])
        document.merge(rule: old)
        XCTAssertEqual(document.rules.first?.name, "New")
    }

    func testNewerTombstoneRemovesRuleAndRejectsOlderRule() {
        let id = UUID()
        let rule = CloudRulePreference(
            id: id,
            modifiedAt: Date(timeIntervalSince1970: 100),
            name: "Deleted"
        )
        let deletion = CloudRuleTombstone(id: id, modifiedAt: Date(timeIntervalSince1970: 200))
        var document = CloudPreferencesDocument(rules: [rule])

        document.merge(tombstone: deletion)
        document.merge(rule: rule)

        XCTAssertTrue(document.rules.isEmpty)
        XCTAssertEqual(document.tombstones, [deletion])
    }

    #if !DESKTOP_HOSTLESS_TESTS
    func testBridgePreservesOpaqueIPhoneSelectionData() {
        var existing = BlockingRule()
        existing.selectionData = Data([1, 2, 3, 4])
        var cloud = CloudRuleBridge.cloudPreference(from: existing)
        cloud.name = "Changed on Mac"
        cloud.modifiedAt = Date().addingTimeInterval(10)

        let applied = CloudRuleBridge.applying(cloud, to: existing)

        XCTAssertEqual(applied.name, "Changed on Mac")
        XCTAssertEqual(applied.selectionData, Data([1, 2, 3, 4]))
    }
    #endif

    func testLegacyRuleMigratesToLiveActivityGroupAndBaselineBlockingGroup() {
        let rule = CloudRulePreference(
            name: "News",
            windows: [CloudTimeWindow(weekdays: [2], startMinutes: 600, endMinutes: 720)],
            domains: [CloudDomainPreference(domain: "example.com", category: "news", source: "user")]
        )
        var document = CloudPreferencesDocument(schemaVersion: 1, rules: [rule])

        document.migrateLegacyRulesIfNeeded()

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.activityGroups.map(\.id), [rule.id])
        XCTAssertEqual(document.baseline.blockingGroups.map(\.id), [rule.id])
        XCTAssertEqual(document.compiledRules().first?.domains, rule.domains)
    }

    func testActivityGroupChangesPropagateToBaselineAndActiveRetreat() {
        let activityID = UUID()
        let group = CloudActivityGroup(
            id: activityID,
            name: "Feeds",
            domains: [CloudDomainPreference(domain: "old.example", category: "social", source: "user")]
        )
        let baselineGroup = CloudBlockingGroup(name: "Baseline", activityGroupIDs: [activityID])
        let retreatGroup = CloudBlockingGroup(name: "Retreat", activityGroupIDs: [activityID])
        var retreat = CloudRetreat(
            name: "Reset",
            plannedStart: Date(timeIntervalSince1970: 0),
            plannedEnd: Date(timeIntervalSince1970: 10_000),
            state: .active
        )
        retreat.appendVersion(blockingGroups: [retreatGroup], modificationPolicy: .init(severity: "none"))
        var document = CloudPreferencesDocument(
            activityGroups: [group],
            baseline: CloudBaseline(blockingGroups: [baselineGroup]),
            retreats: [retreat]
        )

        document.activityGroups[0].domains = [
            CloudDomainPreference(domain: "new.example", category: "social", source: "user")
        ]
        let compiled = document.compiledRules(at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(compiled.count, 2)
        XCTAssertTrue(compiled.allSatisfy { $0.domains.map(\.domain) == ["new.example"] })
    }

    func testDashboardIncludesEnabledBlockingGroupsOutsideTheirWindows() {
        let activity = CloudActivityGroup(name: "Feeds")
        let enabled = CloudBlockingGroup(
            name: "Enabled outside window",
            activityGroupIDs: [activity.id],
            timeWindow: CloudTimeWindowPlan(
                paintMode: .block,
                slots: [CloudTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 10 * 60)]
            ),
            isEnabled: true
        )
        let disabled = CloudBlockingGroup(
            name: "Disabled",
            activityGroupIDs: [activity.id],
            isEnabled: false
        )
        let document = CloudPreferencesDocument(
            activityGroups: [activity],
            baseline: CloudBaseline(blockingGroups: [disabled, enabled])
        )

        let rules = document.dashboardBlockingRules(at: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(rules.map(\.name), ["Enabled outside window"])
        XCTAssertEqual(rules.first?.windows, enabled.timeWindow.effectiveBlockingSlots())
    }

    func testDeletingActivityGroupRemovesLiveLinksButRetainsHistoricalMarker() {
        let activity = CloudActivityGroup(name: "Deleted")
        let blocking = CloudBlockingGroup(activityGroupIDs: [activity.id])
        var active = CloudRetreat(state: .active)
        active.appendVersion(blockingGroups: [blocking], modificationPolicy: .init(severity: "none"))
        var completed = CloudRetreat(state: .completed)
        completed.appendVersion(blockingGroups: [blocking], modificationPolicy: .init(severity: "none"))
        var document = CloudPreferencesDocument(
            activityGroups: [activity],
            baseline: CloudBaseline(blockingGroups: [blocking]),
            retreats: [active, completed]
        )

        document.deleteActivityGroup(id: activity.id, at: Date(timeIntervalSince1970: 500))

        XCTAssertTrue(document.baseline.blockingGroups.isEmpty)
        XCTAssertTrue(document.retreats[0].currentVersion?.blockingGroups.isEmpty == true)
        XCTAssertEqual(document.retreats[1].currentVersion?.blockingGroups.first?.activityGroupIDs, [activity.id])
        XCTAssertEqual(document.activityGroupTombstones.first?.name, "Deleted")
    }

    func testTimeWindowTemplateCreatesIndependentCopy() {
        let template = CloudTimeWindowTemplate(
            value: CloudTimeWindowPlan(slots: [CloudTimeWindow(weekdays: [2], startMinutes: 60, endMinutes: 120)])
        )
        let copy = template.makeIndependentCopy()

        XCTAssertNotEqual(copy.id, template.value.id)
        XCTAssertNotEqual(copy.slots[0].id, template.value.slots[0].id)
        XCTAssertEqual(copy.slots[0].startMinutes, 60)
    }

    func testRetreatBlockingGroupCopyPreservesConfigurationWithIndependentIdentity() {
        let activityID = UUID()
        let source = CloudBlockingGroup(
            name: "Feeds",
            activityGroupIDs: [activityID],
            timeWindow: CloudTimeWindowPlan(
                paintMode: .allow,
                slots: [CloudTimeWindow(weekdays: [2, 3], startMinutes: 540, endMinutes: 660)]
            ),
            usageBudget: CloudUsageBudget(dailyLimitMinutes: 45, weeklyLimitMinutes: 180),
            enforcementMode: "fortressAllowList",
            modificationPolicy: CloudRuleLockdownPreference(severity: "delayed")
        )

        let copy = source.makeIndependentCopy(at: Date(timeIntervalSince1970: 500))

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.sourceBlockingGroupID, source.id)
        XCTAssertNotEqual(copy.timeWindow.id, source.timeWindow.id)
        XCTAssertNotEqual(copy.timeWindow.slots[0].id, source.timeWindow.slots[0].id)
        XCTAssertEqual(copy.activityGroupIDs, [activityID])
        XCTAssertEqual(copy.name, source.name)
        XCTAssertEqual(copy.timeWindow.paintMode, .allow)
        XCTAssertEqual(copy.timeWindow.slots[0].weekdays, [2, 3])
        XCTAssertEqual(copy.usageBudget, source.usageBudget)
        XCTAssertEqual(copy.enforcementMode, source.enforcementMode)
        XCTAssertEqual(copy.modificationPolicy, source.modificationPolicy)
    }

    func testRetreatSelectionEnablesDisabledReusableBlockingGroup() {
        let source = CloudBlockingGroup(name: "Available", isEnabled: false)

        let groups = CloudRetreatGroupVersioning.versionedGroups(
            from: [source],
            replacing: [],
            at: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isEnabled)
        XCTAssertNotEqual(groups[0].id, source.id)
        XCTAssertEqual(groups[0].sourceBlockingGroupID, source.id)
    }

    func testAddingNewBlockingGroupToOldRetreatPreservesExistingIdentity() {
        let firstSource = CloudBlockingGroup(name: "Original", isEnabled: false)
        let secondSource = CloudBlockingGroup(name: "Created later", isEnabled: false)
        let oldVersion = CloudRetreatGroupVersioning.versionedGroups(
            from: [firstSource],
            replacing: [],
            at: Date(timeIntervalSince1970: 100)
        )

        let revised = CloudRetreatGroupVersioning.versionedGroups(
            from: [firstSource, secondSource],
            replacing: oldVersion,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(revised.count, 2)
        XCTAssertEqual(revised[0].id, oldVersion[0].id)
        XCTAssertEqual(revised[0].sourceBlockingGroupID, firstSource.id)
        XCTAssertTrue(revised.allSatisfy(\.isEnabled))
        XCTAssertEqual(revised[1].sourceBlockingGroupID, secondSource.id)
        XCTAssertNotEqual(revised[1].id, secondSource.id)
    }

    func testOldRetreatRecognizesOnlyItsRepresentedBaselineGroups() {
        let original = CloudBlockingGroup(name: "Original", activityGroupIDs: [UUID()])
        let addedLater = CloudBlockingGroup(name: "Later", activityGroupIDs: [UUID()])
        let retreatCopy = original.makeIndependentCopy()

        XCTAssertTrue(CloudRetreatGroupVersioning.represents(retreatCopy, baselineGroup: original))
        XCTAssertFalse(CloudRetreatGroupVersioning.represents(retreatCopy, baselineGroup: addedLater))
    }

    func testAllowancePaintingCompilesToBlockedComplement() {
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 10 * 60)]
        )
        let blocked = plan.effectiveBlockingSlots()
        let monday = blocked.filter { $0.weekdays.contains(2) }

        XCTAssertTrue(monday.contains { $0.startMinutes == 0 && $0.endMinutes == 9 * 60 })
        XCTAssertTrue(monday.contains { $0.startMinutes == 10 * 60 && $0.endMinutes == 1_440 })
        XCTAssertTrue(blocked.contains { $0.weekdays.contains(3) && $0.startMinutes == 0 && $0.endMinutes == 1_440 })
    }

    func testAllowanceCompilationMergesIntervalsWithoutMinuteSizedStorage() {
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [
                CloudTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 11 * 60),
                CloudTimeWindow(weekdays: [2], startMinutes: 10 * 60, endMinutes: 12 * 60)
            ]
        )

        let monday = plan.effectiveBlockingSlots().filter { $0.weekdays.contains(2) }
        XCTAssertEqual(monday.count, 2)
        XCTAssertTrue(monday.contains { $0.startMinutes == 0 && $0.endMinutes == 9 * 60 })
        XCTAssertTrue(monday.contains { $0.startMinutes == 12 * 60 && $0.endMinutes == 1_440 })
    }

    func testMalformedAllowanceMinutesFailClosedWithoutCrashing() {
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [2], startMinutes: 1_500, endMinutes: -20)]
        )

        let blocked = plan.effectiveBlockingSlots()
        XCTAssertEqual(blocked.count, 1)
        XCTAssertEqual(blocked[0].weekdays, Set(1...7))
        XCTAssertEqual(blocked[0].startMinutes, 0)
        XCTAssertEqual(blocked[0].endMinutes, 1_440)
    }

    func testAllDayAllowanceRetainsOvernightOccurrenceSemantics() {
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [7], startMinutes: 9 * 60, endMinutes: 9 * 60)]
        )

        let blocked = plan.effectiveBlockingSlots()
        let saturday = blocked.filter { $0.weekdays.contains(7) }
        let sunday = blocked.filter { $0.weekdays.contains(1) }
        XCTAssertTrue(saturday.contains { $0.startMinutes == 0 && $0.endMinutes == 9 * 60 })
        XCTAssertTrue(sunday.contains { $0.startMinutes == 9 * 60 && $0.endMinutes == 1_440 })
    }

    func testDuplicateActivityGroupIdentifiersChooseNewestRecord() {
        let id = UUID()
        let older = CloudActivityGroup(
            id: id,
            modifiedAt: Date(timeIntervalSince1970: 100),
            domains: [CloudDomainPreference(domain: "old.example", category: "other", source: "user")]
        )
        let newer = CloudActivityGroup(
            id: id,
            modifiedAt: Date(timeIntervalSince1970: 200),
            domains: [CloudDomainPreference(domain: "new.example", category: "other", source: "user")]
        )
        let blocking = CloudBlockingGroup(activityGroupIDs: [id])
        let document = CloudPreferencesDocument(
            activityGroups: [older, newer],
            baseline: CloudBaseline(blockingGroups: [blocking])
        )

        XCTAssertEqual(document.compiledRules().first?.domains.map(\.domain), ["new.example"])
    }

    func testModificationPolicyUsesRestrictiveMaximumInEveryDimension() {
        let first = CloudRuleLockdownPreference(
            severity: "delayed",
            unlockDelayDays: 5,
            passageWordCount: 40,
            confirmationWindowHours: 12,
            editWindowHours: 8,
            allowsTimeExtensions: true,
            maximumTimeExtensionHours: 3
        )
        let second = CloudRuleLockdownPreference(
            severity: "repeatedConfirmations",
            unlockDelayDays: 2,
            passageWordCount: 80,
            confirmationWindowHours: 6,
            editWindowHours: 12,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 1
        )

        let result = CloudRuleLockdownPreference.restrictiveMaximum([first, second])

        XCTAssertEqual(result.severity, "repeatedConfirmations")
        XCTAssertEqual(result.unlockDelayDays, 5)
        XCTAssertEqual(result.passageWordCount, 80)
        XCTAssertEqual(result.confirmationWindowHours, 6)
        XCTAssertEqual(result.editWindowHours, 8)
        XCTAssertFalse(result.allowsTimeExtensions)
        XCTAssertEqual(result.maximumTimeExtensionHours, 1)
    }

    func testPassageOnlyPolicyIgnoresStaleSerializedDelay() {
        let result = CloudRuleLockdownPreference.restrictiveMaximum([
            CloudRuleLockdownPreference(
                severity: "passageOnly",
                unlockDelayDays: 30,
                passageWordCount: 40
            )
        ])

        XCTAssertEqual(result.severity, "passageOnly")
        XCTAssertEqual(result.unlockDelayDays, 0)
    }

    func testRetreatLifecycleRecordsVersionAndRun() {
        let now = Date(timeIntervalSince1970: 1_000)
        var retreat = CloudRetreat(
            plannedStart: now.addingTimeInterval(-100),
            plannedEnd: now.addingTimeInterval(100),
            state: .draft
        )
        retreat.appendVersion(blockingGroups: [CloudBlockingGroup()], modificationPolicy: .init(), at: now)
        retreat.start(at: now.addingTimeInterval(10))
        retreat.finish(early: true, at: now.addingTimeInterval(20))

        XCTAssertEqual(retreat.currentVersionNumber, 1)
        XCTAssertEqual(retreat.state, .endedEarly)
        XCTAssertEqual(retreat.runs.first?.versionNumber, 1)
        XCTAssertEqual(retreat.runs.first?.terminalState, .endedEarly)
    }

    func testActiveRetreatCannotEndEarlyBeforeItsChangePolicyUnlocks() {
        var retreat = CloudRetreat(state: .active)
        retreat.appendVersion(
            blockingGroups: [CloudBlockingGroup()],
            modificationPolicy: CloudRuleLockdownPreference(
                severity: "passageOnly",
                unlockDelayDays: 0
            )
        )

        XCTAssertFalse(CloudRetreatEarlyEndGate.canEndEarly(
            retreat,
            authorizationIsUnlocked: false,
            appDefault: .init(severity: "none")
        ))
        XCTAssertTrue(CloudRetreatEarlyEndGate.canEndEarly(
            retreat,
            authorizationIsUnlocked: true,
            appDefault: .init(severity: "none")
        ))
    }

    func testRetreatEarlyEndUsesMostRestrictiveVersionPolicy() {
        var retreat = CloudRetreat(
            state: .active,
            modificationPolicy: .init(severity: "none")
        )
        retreat.appendVersion(
            blockingGroups: [CloudBlockingGroup()],
            modificationPolicy: CloudRuleLockdownPreference(
                severity: "repeatedConfirmations",
                unlockDelayDays: 7,
                passageWordCount: 80,
                confirmationWindowHours: 12,
                editWindowHours: 2
            )
        )

        let policy = CloudRetreatEarlyEndGate.policy(
            for: retreat,
            appDefault: .init(severity: "none")
        )
        XCTAssertTrue(policy.requiresAuthorization)
        XCTAssertEqual(policy.unlockDelayDays, 7)
        XCTAssertTrue(policy.repeatConfirmations)
        XCTAssertEqual(policy.passageWordCount, 80)
        XCTAssertEqual(policy.confirmationWindowHours, 12)
        XCTAssertEqual(policy.editWindowHours, 2)
    }

    func testUnprotectedRetreatCanEndEarlyWithoutUnlock() {
        var retreat = CloudRetreat(state: .active)
        retreat.appendVersion(
            blockingGroups: [CloudBlockingGroup()],
            modificationPolicy: .init(severity: "none")
        )

        XCTAssertTrue(CloudRetreatEarlyEndGate.canEndEarly(
            retreat,
            authorizationIsUnlocked: false,
            appDefault: .init(severity: "delayed")
        ))
    }

    func testScheduledRetreatTransitionsAndCompletesAtPlannedTimes() {
        let start = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 3_000)
        var retreat = CloudRetreat(plannedStart: start, plannedEnd: end)
        retreat.appendVersion(blockingGroups: [CloudBlockingGroup()], modificationPolicy: .init())

        retreat.start(at: start.addingTimeInterval(-100))
        XCTAssertEqual(retreat.state, .scheduled)
        XCTAssertTrue(retreat.runs.isEmpty)

        retreat.reconcile(at: start.addingTimeInterval(10))
        XCTAssertEqual(retreat.state, .active)
        XCTAssertEqual(retreat.runs.first?.actualStart, start)

        retreat.reconcile(at: end.addingTimeInterval(10))
        XCTAssertEqual(retreat.state, .completed)
        XCTAssertEqual(retreat.runs.first?.actualEnd, end)
        XCTAssertEqual(retreat.runs.first?.terminalState, .completed)
    }
}

extension CloudPreferencesTests {
    /// Blocking windows are recomputed from the allowance plan on every load and
    /// save. A fresh identity each time would restart every Device Activity
    /// monitor on every sync, and a monitor restarted inside its own window can
    /// no longer be relied on to deliver the interval end that lifts its shield.
    func testDerivedBlockingWindowsKeepTheirIdentityAcrossRecomputation() {
        let plan = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [2, 3, 4], startMinutes: 18 * 60, endMinutes: 20 * 60)]
        )

        let first = plan.effectiveBlockingSlots()
        let second = plan.effectiveBlockingSlots()

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "Derived windows must stay distinct")
    }

    func testDerivedWindowIdentityChangesWhenTheScheduleChanges() {
        let evening = CloudTimeWindowPlan(
            paintMode: .allow,
            slots: [CloudTimeWindow(weekdays: [2], startMinutes: 18 * 60, endMinutes: 20 * 60)]
        )
        var later = evening
        later.slots = [CloudTimeWindow(weekdays: [2], startMinutes: 19 * 60, endMinutes: 20 * 60)]

        XCTAssertNotEqual(
            Set(evening.effectiveBlockingSlots().map(\.id)),
            Set(later.effectiveBlockingSlots().map(\.id))
        )
    }

    /// Two plans that describe the same hours still have to stay independent,
    /// or their monitors and shield stores would collide.
    func testDerivedWindowIdentityIsScopedToItsPlan() {
        let slots = [CloudTimeWindow(weekdays: [2], startMinutes: 18 * 60, endMinutes: 20 * 60)]
        let first = CloudTimeWindowPlan(paintMode: .allow, slots: slots)
        let second = CloudTimeWindowPlan(paintMode: .allow, slots: slots)

        XCTAssertNotEqual(
            Set(first.effectiveBlockingSlots().map(\.id)),
            Set(second.effectiveBlockingSlots().map(\.id))
        )
    }
}
