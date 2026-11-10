import XCTest
@testable import Holdfast

final class LockdownTests: XCTestCase {
    func testAllowanceEndAcceptsWholeSecondBoundaryButRejectsOldCallbackAfterExtension() {
        let boundary = Date(timeIntervalSince1970: 1_700_000_600)
        var allowance = RuleTimeAllowance(
            ruleID: UUID(), expiresAt: boundary.addingTimeInterval(0.875),
            totalMinutesGranted: 10, grantCount: 1, restoreUsageShield: false
        )
        XCTAssertFalse(allowance.isDueForMonitorEnd(at: boundary.addingTimeInterval(-1)))
        XCTAssertTrue(allowance.isDueForMonitorEnd(at: boundary))
        allowance.expiresAt = allowance.expiresAt.addingTimeInterval(600)
        XCTAssertFalse(allowance.isDueForMonitorEnd(at: boundary))
    }
    func testTemporaryAccessOffersOneMinuteThroughAnHour() {
        XCTAssertEqual(TemporaryAccessDuration.allCases.map(\.rawValue), [1, 5, 10, 30, 60])
        XCTAssertEqual(TemporaryAccessDuration.thirtyMinutes.seconds, 30 * 60)
        XCTAssertEqual(TemporaryAccessDuration.oneMinute.seconds, 60)
    }

    func testTemporaryAccessCapUsesCumulativeMinutes() {
        XCTAssertTrue(TimeAllowancePolicy.canGrant(
            .thirtyMinutes,
            afterMinutes: 120,
            maximumMinutes: 180
        ))
        XCTAssertTrue(TimeAllowancePolicy.canGrant(
            .sixtyMinutes,
            afterMinutes: 120,
            maximumMinutes: 180
        ))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(
            .tenMinutes,
            afterMinutes: 180,
            maximumMinutes: 180
        ))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(
            .sixtyMinutes,
            afterMinutes: 150,
            maximumMinutes: 180
        ))
    }

    func testLegacyHourlyAllowanceDecodesWithMinuteAndGrantAccounting() throws {
        struct LegacyAllowance: Encodable {
            var ruleID: UUID
            var expiresAt: Date
            var incrementsGranted: Int
            var restoreUsageShield: Bool
        }

        let id = UUID()
        let expiry = Date(timeIntervalSinceReferenceDate: 12_345)
        let data = try JSONEncoder().encode(LegacyAllowance(
            ruleID: id,
            expiresAt: expiry,
            incrementsGranted: 2,
            restoreUsageShield: true
        ))
        let decoded = try JSONDecoder().decode(RuleTimeAllowance.self, from: data)

        XCTAssertEqual(decoded.ruleID, id)
        XCTAssertEqual(decoded.expiresAt, expiry)
        XCTAssertEqual(decoded.incrementsGranted, 2)
        XCTAssertEqual(decoded.grantCount, 2)
        XCTAssertEqual(decoded.totalMinutesGranted, 120)
        XCTAssertTrue(decoded.restoreUsageShield)
    }

    func testMinuteAllowanceRoundTripsNewAccounting() throws {
        let original = RuleTimeAllowance(
            ruleID: UUID(),
            expiresAt: Date(timeIntervalSinceReferenceDate: 54_321),
            totalMinutesGranted: 40,
            grantCount: 2,
            restoreUsageShield: false
        )

        let decoded = try JSONDecoder().decode(
            RuleTimeAllowance.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.incrementsGranted, decoded.grantCount)
    }

    func testShieldEligibilityUsesRuleModeEnabledStateAndOptIn() {
        let activeWindow = TimeWindow(
            weekdays: [2],
            startMinutes: 0,
            endMinutes: 1_439
        )
        var selectedBlockList = BlockingRule()
        selectedBlockList.lockdownPolicy.allowsTimeExtensions = true
        selectedBlockList.windows = [activeWindow]

        var selectedFortress = BlockingRule()
        selectedFortress.enforcementMode = .fortressAllowList
        selectedFortress.lockdownPolicy.allowsTimeExtensions = true
        selectedFortress.windows = [activeWindow]

        var unselectedFortress = BlockingRule()
        unselectedFortress.enforcementMode = .fortressAllowList
        unselectedFortress.lockdownPolicy.allowsTimeExtensions = true
        unselectedFortress.windows = [activeWindow]

        var disabled = BlockingRule()
        disabled.isEnabled = false
        disabled.lockdownPolicy.allowsTimeExtensions = true
        disabled.windows = [activeWindow]

        var notOptedIn = BlockingRule()
        notOptedIn.windows = [activeWindow]
        let selected = Set([selectedBlockList.id, selectedFortress.id, disabled.id, notOptedIn.id])
        let result = ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            rules: [selectedBlockList, selectedFortress, unselectedFortress, disabled, notOptedIn],
            at: start,
            targetIsSelected: { selected.contains($0.id) }
        )

        XCTAssertEqual(Set(result), Set([selectedBlockList.id, unselectedFortress.id]))
    }

    func testShieldEligibilityExcludesInactiveOverlappingAndAlreadyPausedRules() {
        let activeWindow = TimeWindow(weekdays: [2], startMinutes: 0, endMinutes: 1_439)
        var active = BlockingRule()
        active.lockdownPolicy.allowsTimeExtensions = true
        active.windows = [activeWindow]

        var inactive = BlockingRule()
        inactive.lockdownPolicy.allowsTimeExtensions = true
        inactive.windows = []

        let selected = Set([active.id, inactive.id])
        XCTAssertEqual(
            ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
                rules: [inactive, active],
                at: start,
                targetIsSelected: { selected.contains($0.id) }
            ),
            [active.id]
        )
        XCTAssertTrue(ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            rules: [inactive, active],
            at: start,
            activeAllowanceRuleIDs: [active.id],
            targetIsSelected: { selected.contains($0.id) }
        ).isEmpty)
    }

    func testShieldEligibilityUsesActuallyEnforcingStoreProvenance() {
        var scheduled = BlockingRule()
        scheduled.lockdownPolicy.allowsTimeExtensions = true
        scheduled.windows = [TimeWindow(weekdays: [2], startMinutes: 0, endMinutes: 1_439)]

        var configuredUsageLimit = BlockingRule()
        configuredUsageLimit.lockdownPolicy.allowsTimeExtensions = true
        configuredUsageLimit.windows = []
        configuredUsageLimit.usageLimitEnabled = true

        let selected = Set([scheduled.id, configuredUsageLimit.id])
        let eligible = ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            rules: [scheduled, configuredUsageLimit],
            at: start,
            currentlyEnforcedRuleIDs: [scheduled.id],
            targetIsSelected: { selected.contains($0.id) }
        )

        XCTAssertEqual(eligible, [scheduled.id])
    }

    func testPendingShieldRequestExpiresAndDeduplicatesRules() throws {
        let suiteName = "LockdownTests.pending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let first = UUID()
        let second = UUID()

        let request = try XCTUnwrap(ShieldTemporaryAccessCoordinator.savePendingRequest(
            eligibleRuleIDs: [second, first, second],
            duration: .thirtyMinutes,
            now: now,
            defaults: defaults
        ))

        XCTAssertEqual(Set(request.eligibleRuleIDs), Set([first, second]))
        XCTAssertEqual(request.eligibleRuleIDs.count, 2)
        XCTAssertEqual(request.expiresAt, now.addingTimeInterval(10 * 60))
        XCTAssertEqual(
            ShieldTemporaryAccessCoordinator.loadPendingRequest(
                now: now.addingTimeInterval(599),
                defaults: defaults
            ),
            request
        )
        XCTAssertNil(ShieldTemporaryAccessCoordinator.loadPendingRequest(
            now: now.addingTimeInterval(600),
            defaults: defaults
        ))
    }

    func testClearingOldPendingRequestDoesNotDeleteNewerRequest() throws {
        let suiteName = "LockdownTests.pending-replacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        let ruleID = UUID()
        let first = try XCTUnwrap(ShieldTemporaryAccessCoordinator.savePendingRequest(
            eligibleRuleIDs: [ruleID],
            duration: .tenMinutes,
            now: now,
            defaults: defaults
        ))
        let second = try XCTUnwrap(ShieldTemporaryAccessCoordinator.savePendingRequest(
            eligibleRuleIDs: [ruleID],
            duration: .sixtyMinutes,
            now: now.addingTimeInterval(1),
            defaults: defaults
        ))

        ShieldTemporaryAccessCoordinator.clearPendingRequest(id: first.id, defaults: defaults)

        XCTAssertEqual(
            ShieldTemporaryAccessCoordinator.loadPendingRequest(
                now: now.addingTimeInterval(2),
                defaults: defaults
            ),
            second
        )
    }

    func testShieldCoordinatorLoadsRulesFromInjectedAppGroupDefaults() throws {
        let suiteName = "LockdownTests.rules.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var rule = BlockingRule()
        rule.name = "Loaded in shield"
        defaults.set(try JSONEncoder().encode([rule]), forKey: "blocking.rules.v1")

        XCTAssertEqual(ShieldTemporaryAccessCoordinator.loadRules(defaults: defaults), [rule])
    }

    func testAdditionalTimePassageDoublesForEachConsecutiveHour() {
        XCTAssertEqual(TimeAllowancePolicy.passageWordCount(base: 40, incrementsAlreadyGranted: 0), 40)
        XCTAssertEqual(TimeAllowancePolicy.passageWordCount(base: 40, incrementsAlreadyGranted: 1), 80)
        XCTAssertEqual(TimeAllowancePolicy.passageWordCount(base: 40, incrementsAlreadyGranted: 2), 160)
        XCTAssertEqual(TimeAllowancePolicy.passageWordCount(base: 40, incrementsAlreadyGranted: 3), 320)
        XCTAssertEqual(CommitmentPassage.normalizedWords(in: CommitmentPassage.generate(wordCount: 40)).count, 40)
        XCTAssertEqual(CommitmentPassage.normalizedWords(in: CommitmentPassage.generate(wordCount: 80)).count, 80)
    }

    private var calendar: Calendar!
    private var start: Date!

    override func setUpWithError() throws {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        // Monday 2026-07-13 09:00 UTC.
        start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 13, hour: 9
        )))
    }

    private func configuration(
        enabled: Bool = true,
        delayDays: Int = 3,
        repeats: Bool = false
    ) -> LockdownConfiguration {
        var configuration = LockdownConfiguration()
        configuration.isEnabled = enabled
        configuration.unlockDelayDays = delayDays
        configuration.repeatConfirmations = repeats
        return configuration
    }

    func testDisabledLockdownIsAlwaysIdle() {
        let process = UnlockProcess(startedAt: start)
        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(enabled: false),
            at: start.addingTimeInterval(3_600),
            calendar: calendar
        )
        XCTAssertEqual(phase, .idle)
    }

    func testWaitingDuringDelay() {
        let process = UnlockProcess(startedAt: start)
        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(),
            at: start.addingTimeInterval(86_400),
            calendar: calendar
        )
        XCTAssertEqual(phase, .waiting(
            unlocksAt: start.addingTimeInterval(3 * Lockdown.day),
            nextConfirmationAt: nil
        ))
    }

    func testUnlocksAfterDelayAndWindowExpires() {
        let process = UnlockProcess(startedAt: start)
        let unlocksAt = start.addingTimeInterval(3 * Lockdown.day)

        let justUnlocked = Lockdown.phase(
            of: process, configuration: configuration(), at: unlocksAt, calendar: calendar
        )
        XCTAssertEqual(justUnlocked, .unlocked(editWindowEndsAt: unlocksAt.addingTimeInterval(24 * 3_600)))

        let expired = Lockdown.phase(
            of: process,
            configuration: configuration(),
            at: unlocksAt.addingTimeInterval(24 * 3_600 + 60),
            calendar: calendar
        )
        XCTAssertEqual(expired, .idle)
    }

    func testZeroDayDelayUnlocksImmediatelyAfterInitialPassage() {
        let process = UnlockProcess(startedAt: start)
        let zeroDelay = configuration(delayDays: 0)
        let phase = Lockdown.phase(
            of: process,
            configuration: zeroDelay,
            at: start,
            calendar: calendar
        )
        XCTAssertEqual(phase, .unlocked(
            editWindowEndsAt: start.addingTimeInterval(24 * 3_600)
        ))
    }

    func testRuleSeverityBuildsIndependentConfiguration() {
        var appDefault = configuration(delayDays: 9, repeats: true)
        appDefault.passageWordCount = 100

        var policy = RuleLockdownPolicy()
        policy.severity = .passageOnly
        XCTAssertEqual(policy.configuration(appDefault: appDefault).unlockDelayDays, 0)
        XCTAssertFalse(policy.configuration(appDefault: appDefault).repeatConfirmations)

        policy.severity = .delayed
        policy.unlockDelayDays = 0
        XCTAssertEqual(policy.configuration(appDefault: appDefault).unlockDelayDays, 0)

        policy.severity = .repeatedConfirmations
        policy.unlockDelayDays = 5
        let repeated = policy.configuration(appDefault: appDefault)
        XCTAssertEqual(repeated.unlockDelayDays, 5)
        XCTAssertTrue(repeated.repeatConfirmations)

        policy.severity = .appDefault
        XCTAssertEqual(policy.configuration(appDefault: appDefault), appDefault)
    }

    func testOldRuleWithoutPolicyMigratesToAppDefault() throws {
        var rule = BlockingRule()
        rule.lockdownPolicy.severity = .repeatedConfirmations
        let encoded = try JSONEncoder().encode(rule)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "lockdownPolicy")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BlockingRule.self, from: legacyData)
        XCTAssertEqual(decoded.lockdownPolicy.severity, .appDefault)
    }

    func testRepeatModeRequiresFirstConfirmationAfterTwentyFourHours() {
        let process = UnlockProcess(startedAt: start)
        let sameDay = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: start.addingTimeInterval(6 * 3_600),
            calendar: calendar
        )
        XCTAssertEqual(sameDay, .waiting(
            unlocksAt: start.addingTimeInterval(3 * Lockdown.day),
            nextConfirmationAt: start.addingTimeInterval(Lockdown.day)
        ))

        let nextDay = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: start.addingTimeInterval(Lockdown.day),
            calendar: calendar
        )
        XCTAssertEqual(nextDay, .confirmationDue(
            unlocksAt: start.addingTimeInterval(3 * Lockdown.day),
            deadline: start.addingTimeInterval(2 * Lockdown.day),
            checkpoint: 1,
            total: 3
        ))
    }

    func testRepeatModeCancelsWhenConfirmationMissed() {
        let process = UnlockProcess(startedAt: start)
        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: start.addingTimeInterval(2 * Lockdown.day),
            calendar: calendar
        )
        XCTAssertEqual(phase, .cancelled)
    }

    func testRepeatModeCannotSkipEarlierCheckpointAtUnlockTime() {
        let process = UnlockProcess(startedAt: start)
        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: start.addingTimeInterval(3 * Lockdown.day),
            calendar: calendar
        )
        XCTAssertEqual(phase, .cancelled)
    }

    func testRepeatModeUnlocksWhenConfirmedDaily() {
        var process = UnlockProcess(startedAt: start)
        process.confirmedAt.append(start.addingTimeInterval(Lockdown.day))
        process.confirmedAt.append(start.addingTimeInterval(2 * Lockdown.day))
        process.confirmedAt.append(start.addingTimeInterval(3 * Lockdown.day))
        let unlocksAt = start.addingTimeInterval(3 * Lockdown.day)

        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: unlocksAt.addingTimeInterval(60),
            calendar: calendar
        )
        XCTAssertEqual(phase, .unlocked(editWindowEndsAt: unlocksAt.addingTimeInterval(24 * 3_600)))
    }

    func testFinalCheckpointMayBeCompletedDuringItsWindow() {
        var process = UnlockProcess(startedAt: start)
        process.confirmedAt.append(start.addingTimeInterval(Lockdown.day))
        process.confirmedAt.append(start.addingTimeInterval(2 * Lockdown.day))
        let finalConfirmation = start.addingTimeInterval(3 * Lockdown.day + 6 * 3_600)
        process.confirmedAt.append(finalConfirmation)

        let phase = Lockdown.phase(
            of: process,
            configuration: configuration(repeats: true),
            at: finalConfirmation,
            calendar: calendar
        )
        XCTAssertEqual(phase, .unlocked(
            editWindowEndsAt: finalConfirmation.addingTimeInterval(24 * 3_600)
        ))
    }

    func testLoosensComparison() {
        let base = configuration(delayDays: 3, repeats: true)
        XCTAssertFalse(configuration(delayDays: 5, repeats: true).loosens(comparedTo: base))
        XCTAssertTrue(configuration(delayDays: 2, repeats: true).loosens(comparedTo: base))
        XCTAssertTrue(configuration(enabled: false, delayDays: 3, repeats: true).loosens(comparedTo: base))
        XCTAssertTrue(configuration(delayDays: 3, repeats: false).loosens(comparedTo: base))

        var shorterWindow = base
        shorterWindow.confirmationWindowHours = 12
        XCTAssertFalse(shorterWindow.loosens(comparedTo: base))

        var longerWindow = base
        longerWindow.confirmationWindowHours = 48
        XCTAssertTrue(longerWindow.loosens(comparedTo: base))
    }

    func testOlderConfigurationDecodesWithSecureDefaults() throws {
        let data = try XCTUnwrap(
            #"{"isEnabled":true,"unlockDelayDays":7,"repeatConfirmations":true,"passageWordCount":80}"#
                .data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(LockdownConfiguration.self, from: data)
        XCTAssertEqual(decoded.confirmationWindowHours, 24)
        XCTAssertEqual(decoded.editWindowHours, 24)
    }

    func testPassageGenerationAndMatching() {
        let passage = CommitmentPassage.generate(wordCount: 40)
        XCTAssertGreaterThanOrEqual(passage.split(separator: " ").count, 30)
        XCTAssertTrue(CommitmentPassage.matches("  " + passage.uppercased() + "\n", passage: passage))
        XCTAssertFalse(CommitmentPassage.matches(String(passage.dropLast(10)), passage: passage))
    }

    func testPassageDiffHighlightsMatchesErrorsAndOmissions() {
        let tokens = PassageDiff.compare(
            typed: "Alpha wrong gamma",
            passage: "alpha beta gamma"
        )
        XCTAssertEqual(tokens.filter { $0.kind == .matched }.count, 2)
        XCTAssertEqual(tokens.filter { $0.kind == .incorrect }.map(\.text), ["wrong"])
        XCTAssertEqual(tokens.filter { $0.kind == .missing }.map(\.text), ["beta"])
    }

    func testPassageDiffHandlesMaximumBackoffWithoutQuadraticMemory() {
        let words = (0..<38_400).map { "word\($0)" }
        let typed = words.enumerated().filter { $0.offset != 100 }.map(\.element).joined(separator: " ")
        let tokens = PassageDiff.compare(typed: typed, passage: words.joined(separator: " "))
        XCTAssertEqual(tokens.filter { $0.kind == .matched }.count, 38_399)
        XCTAssertEqual(tokens.filter { $0.kind == .missing }.map(\.text), ["word100"])
    }

    func testPassageDiffUsesSameCaseAndWhitespaceRulesAsConfirmation() {
        let typed = "  ALPHA\n beta  "
        let passage = "alpha beta"
        XCTAssertTrue(CommitmentPassage.matches(typed, passage: passage))
        XCTAssertTrue(PassageDiff.compare(typed: typed, passage: passage).allSatisfy {
            $0.kind == .matched
        })
    }
}

extension LockdownTests {
    /// The session maximum is the floor the user was asking about: it used to
    /// bottom out at one hour, so a group could never permit a genuinely short
    /// bypass.
    func testSessionMaximumReachesOneMinute() {
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesRange.lowerBound, 1)
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder.first, 1)
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder.last, 480)
    }

    /// A one-minute maximum is useless unless a grant that small exists, so the
    /// shortest duration has to fit inside it.
    func testOneMinuteGrantFitsAOneMinuteMaximum() {
        XCTAssertTrue(TimeAllowancePolicy.canGrant(.oneMinute, afterMinutes: 0, maximumMinutes: 1))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(.fiveMinutes, afterMinutes: 0, maximumMinutes: 1))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(.oneMinute, afterMinutes: 1, maximumMinutes: 1))
    }

    func testShortDurationsAreOfferedAndReadNaturally() {
        XCTAssertEqual(TemporaryAccessDuration.oneMinute.minutes, 1)
        XCTAssertEqual(TemporaryAccessDuration.oneMinute.title, "1 minute")
        XCTAssertEqual(TemporaryAccessDuration.fiveMinutes.title, "5 minutes")
        XCTAssertEqual(TemporaryAccessDuration.allCases.map(\.minutes), [1, 5, 10, 30, 60])
    }

    /// Apple's shield has exactly three secondary submenu slots, so that path
    /// cannot grow with the duration list.
    func testShieldSubmenuStillHasExactlyThreeSlots() {
        XCTAssertEqual(TemporaryAccessDuration.shieldSubmenuOptions.count, 3)
    }

    /// The ladder exists so eight hours stays a few presses away; every rung
    /// must be inside the permitted range and strictly increasing.
    func testLadderIsOrderedAndWithinRange() {
        let ladder = TimeAllowancePolicy.maximumMinutesLadder
        XCTAssertEqual(ladder, ladder.sorted())
        XCTAssertEqual(Set(ladder).count, ladder.count)
        XCTAssertTrue(ladder.allSatisfy { TimeAllowancePolicy.maximumMinutesRange.contains($0) })
    }

    func testLadderIndexSnapsDownToAReachableRung() {
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder[TimeAllowancePolicy.ladderIndex(forMinutes: 1)], 1)
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder[TimeAllowancePolicy.ladderIndex(forMinutes: 7)], 5)
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder[TimeAllowancePolicy.ladderIndex(forMinutes: 480)], 480)
        // Out-of-range values clamp rather than trapping on an index.
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder[TimeAllowancePolicy.ladderIndex(forMinutes: 0)], 1)
        XCTAssertEqual(TimeAllowancePolicy.maximumMinutesLadder[TimeAllowancePolicy.ladderIndex(forMinutes: 10_000)], 480)
    }

    func testMaximumIsDescribedInUnitsAPersonReads() {
        XCTAssertEqual(TimeAllowancePolicy.describeMaximum(minutes: 1), "1 minute")
        XCTAssertEqual(TimeAllowancePolicy.describeMaximum(minutes: 45), "45 minutes")
        XCTAssertEqual(TimeAllowancePolicy.describeMaximum(minutes: 60), "1 hour")
        XCTAssertEqual(TimeAllowancePolicy.describeMaximum(minutes: 90), "1 hour 30 min")
        XCTAssertEqual(TimeAllowancePolicy.describeMaximum(minutes: 480), "8 hours")
    }

    /// A policy written before minutes existed must keep working, and writing a
    /// sub-hour maximum must floor the legacy hour field rather than rounding it
    /// up to an hour nobody authorised.
    func testLegacyHourFieldRemainsTheFallbackAndFloorsOnWrite() {
        var policy = CloudRuleLockdownPreference()
        policy.allowsTimeExtensions = true
        policy.maximumTimeExtensionHours = 3
        XCTAssertNil(policy.maximumTemporaryAccessMinutes)
        XCTAssertEqual(policy.effectiveMaximumTemporaryAccessMinutes, 180)

        policy.setMaximumTemporaryAccess(minutes: 5)
        XCTAssertEqual(policy.effectiveMaximumTemporaryAccessMinutes, 5)
        XCTAssertEqual(policy.maximumTimeExtensionHours, 0, "A sub-hour maximum must not read as a whole hour elsewhere")

        policy.setMaximumTemporaryAccess(minutes: 90)
        XCTAssertEqual(policy.maximumTimeExtensionHours, 1)
    }

    func testMinutesSurviveACloudRoundTripAndClamp() throws {
        var policy = CloudRuleLockdownPreference()
        policy.setMaximumTemporaryAccess(minutes: 2)
        let decoded = try JSONDecoder().decode(
            CloudRuleLockdownPreference.self,
            from: try JSONEncoder().encode(policy)
        )
        XCTAssertEqual(decoded.effectiveMaximumTemporaryAccessMinutes, 2)

        var absurd = policy
        absurd.maximumTemporaryAccessMinutes = 100_000
        let clamped = try JSONDecoder().decode(
            CloudRuleLockdownPreference.self,
            from: try JSONEncoder().encode(absurd)
        )
        XCTAssertEqual(clamped.effectiveMaximumTemporaryAccessMinutes, 480)
    }

    /// Combining policies keeps the most restrictive maximum, which now has to
    /// compare minutes rather than whole hours.
    func testRestrictiveMaximumKeepsTheSmallestMinuteValue() {
        var lenient = CloudRuleLockdownPreference(severity: "passageOnly")
        lenient.allowsTimeExtensions = true
        lenient.setMaximumTemporaryAccess(minutes: 120)
        var strict = CloudRuleLockdownPreference(severity: "passageOnly")
        strict.allowsTimeExtensions = true
        strict.setMaximumTemporaryAccess(minutes: 5)

        let combined = CloudRuleLockdownPreference.restrictiveMaximum([lenient, strict])

        XCTAssertEqual(combined.effectiveMaximumTemporaryAccessMinutes, 5)
    }
}

extension LockdownTests {
    private func retreatConfiguration(
        delayDays: Int,
        ceiling: Date?,
        repeats: Bool = false
    ) -> LockdownConfiguration {
        var configuration = LockdownConfiguration()
        configuration.isEnabled = true
        configuration.unlockDelayDays = delayDays
        configuration.repeatConfirmations = repeats
        configuration.editWindowHours = 24
        configuration.unlockCeiling = ceiling
        return configuration
    }

    /// The case that prompted this: a three-day wait guarding a thirty-nine
    /// hour Retreat could never come due, so the request was unusable.
    func testUnlockCannotOpenAfterTheRetreatHasAlreadyEnded() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let retreatEnds = started.addingTimeInterval(39 * 3_600)
        let process = UnlockProcess(startedAt: started)

        let phase = Lockdown.phase(
            of: process,
            configuration: retreatConfiguration(delayDays: 3, ceiling: retreatEnds),
            at: started.addingTimeInterval(60)
        )

        guard case let .waiting(unlocksAt, _) = phase else {
            return XCTFail("Expected the request to be waiting, got \(phase)")
        }
        XCTAssertEqual(unlocksAt, retreatEnds, "The wait must stop at the Retreat's own end")
    }

    func testCappedUnlockActuallyOpensAtTheCeiling() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let retreatEnds = started.addingTimeInterval(39 * 3_600)
        let process = UnlockProcess(startedAt: started)

        let phase = Lockdown.phase(
            of: process,
            configuration: retreatConfiguration(delayDays: 3, ceiling: retreatEnds),
            at: retreatEnds.addingTimeInterval(1)
        )

        guard case .unlocked = phase else {
            return XCTFail("The edit window must open once the ceiling passes, got \(phase)")
        }
    }

    /// A ceiling must never *lengthen* a wait: it is a cap, not a schedule.
    func testACeilingLaterThanTheDelayChangesNothing() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let process = UnlockProcess(startedAt: started)
        let generous = started.addingTimeInterval(30 * 86_400)

        let capped = Lockdown.phase(
            of: process, configuration: retreatConfiguration(delayDays: 3, ceiling: generous),
            at: started.addingTimeInterval(60)
        )
        let uncapped = Lockdown.phase(
            of: process, configuration: retreatConfiguration(delayDays: 3, ceiling: nil),
            at: started.addingTimeInterval(60)
        )

        XCTAssertEqual(capped, uncapped)
    }

    /// The app-wide lockdown sets no ceiling, so its behaviour is untouched.
    func testNoCeilingLeavesTheDelayExactlyAsBefore() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let process = UnlockProcess(startedAt: started)

        let phase = Lockdown.phase(
            of: process, configuration: retreatConfiguration(delayDays: 3, ceiling: nil),
            at: started.addingTimeInterval(60)
        )

        guard case let .waiting(unlocksAt, _) = phase else {
            return XCTFail("Expected waiting, got \(phase)")
        }
        XCTAssertEqual(unlocksAt, started.addingTimeInterval(3 * 86_400))
    }

    /// With repeated confirmations, only the checkpoints that fit before the
    /// ceiling can be required, or the process could never finish either.
    func testCheckpointsAreReducedToThoseThatFitBeforeTheCeiling() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let retreatEnds = started.addingTimeInterval(39 * 3_600)
        var process = UnlockProcess(startedAt: started)
        let configuration = retreatConfiguration(delayDays: 3, ceiling: retreatEnds, repeats: true)

        let due = Lockdown.phase(
            of: process, configuration: configuration,
            at: started.addingTimeInterval(86_400 + 60)
        )
        guard case let .confirmationDue(_, _, checkpoint, total) = due else {
            return XCTFail("Expected a checkpoint to be due, got \(due)")
        }
        XCTAssertEqual(checkpoint, 1)
        XCTAssertEqual(total, 1, "Only one 24-hour checkpoint fits before the Retreat ends")

        process.confirmedAt.append(started.addingTimeInterval(86_400 + 120))
        let after = Lockdown.phase(
            of: process, configuration: configuration,
            at: started.addingTimeInterval(86_400 + 180)
        )
        guard case .unlocked = after else {
            return XCTFail("Completing the only required checkpoint must unlock, got \(after)")
        }
    }

    /// Regression: an edit window that closed (or a missed checkpoint) while the
    /// app stayed open was read as idle but kept on disk, and the start guards
    /// required no saved process, so a newly typed passage started nothing.
    func testAClosedOrCancelledProcessDoesNotBlockANewUnlock() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let process = UnlockProcess(startedAt: started)
        let plain = retreatConfiguration(delayDays: 1, ceiling: nil)

        // Waiting and open processes are live and must never be replaced.
        XCTAssertEqual(Lockdown.liveProcess(process, configuration: plain, at: started.addingTimeInterval(3_600)), process)
        XCTAssertEqual(Lockdown.liveProcess(process, configuration: plain, at: started.addingTimeInterval(30 * 3_600)), process)
        // One day of waiting plus a 24-hour window: closed after 48 hours.
        let closed = started.addingTimeInterval(49 * 3_600)
        XCTAssertEqual(Lockdown.phase(of: process, configuration: plain, at: closed), .idle)
        XCTAssertNil(Lockdown.liveProcess(process, configuration: plain, at: closed))

        // Checkpoints: due after a day, with a 24-hour window to type it.
        let checkpoints = retreatConfiguration(delayDays: 2, ceiling: nil, repeats: true)
        let due = started.addingTimeInterval(25 * 3_600)
        guard case .confirmationDue = Lockdown.phase(of: process, configuration: checkpoints, at: due) else {
            return XCTFail("Expected the first checkpoint to be due")
        }
        XCTAssertEqual(Lockdown.liveProcess(process, configuration: checkpoints, at: due), process)
        let missed = started.addingTimeInterval(49 * 3_600)
        XCTAssertEqual(Lockdown.phase(of: process, configuration: checkpoints, at: missed), .cancelled)
        XCTAssertNil(Lockdown.liveProcess(process, configuration: checkpoints, at: missed))

        // No process at all is, as before, nothing to keep.
        XCTAssertNil(Lockdown.liveProcess(nil, configuration: plain, at: started))
        XCTAssertTrue(UnlockPhase.idle.isIdleOrCancelled)
        XCTAssertTrue(UnlockPhase.cancelled.isIdleOrCancelled)
        XCTAssertFalse(UnlockPhase.unlocked(editWindowEndsAt: closed).isIdleOrCancelled)
        XCTAssertFalse(UnlockPhase.waiting(unlocksAt: closed, nextConfirmationAt: nil).isIdleOrCancelled)
    }

    /// A configuration written before the ceiling existed still decodes.
    func testConfigurationWithoutACeilingDecodes() throws {
        let legacy = Data(#"{"isEnabled":true,"unlockDelayDays":3,"repeatConfirmations":false,"passageWordCount":40,"confirmationWindowHours":24,"editWindowHours":24}"#.utf8)

        let decoded = try JSONDecoder().decode(LockdownConfiguration.self, from: legacy)

        XCTAssertNil(decoded.unlockCeiling)
        XCTAssertEqual(decoded.unlockDelayDays, 3)
    }
}
