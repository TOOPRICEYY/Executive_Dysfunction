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
    func testTemporaryAccessOffersOnlyTenThirtyAndSixtyMinutes() {
        XCTAssertEqual(TemporaryAccessDuration.allCases.map(\.rawValue), [10, 30, 60])
        XCTAssertEqual(TemporaryAccessDuration.thirtyMinutes.seconds, 30 * 60)
    }

    func testTemporaryAccessCapUsesCumulativeMinutes() {
        XCTAssertTrue(TimeAllowancePolicy.canGrant(
            .thirtyMinutes,
            afterMinutes: 120,
            maximumHours: 3
        ))
        XCTAssertTrue(TimeAllowancePolicy.canGrant(
            .sixtyMinutes,
            afterMinutes: 120,
            maximumHours: 3
        ))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(
            .tenMinutes,
            afterMinutes: 180,
            maximumHours: 3
        ))
        XCTAssertFalse(TimeAllowancePolicy.canGrant(
            .sixtyMinutes,
            afterMinutes: 150,
            maximumHours: 3
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

    func testPassageDiffUsesSameCaseAndWhitespaceRulesAsConfirmation() {
        let typed = "  ALPHA\n beta  "
        let passage = "alpha beta"
        XCTAssertTrue(CommitmentPassage.matches(typed, passage: passage))
        XCTAssertTrue(PassageDiff.compare(typed: typed, passage: passage).allSatisfy {
            $0.kind == .matched
        })
    }
}
