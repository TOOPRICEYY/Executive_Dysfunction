import XCTest
@testable import ExecutiveDysfunction

final class LockdownTests: XCTestCase {
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
