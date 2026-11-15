import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class MacTemporaryPauseStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "mac-temporary-pause-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBackoffSurvivesExpiryPruningAndCancellation() {
        let now = Date()
        var subject = rule(maximumHours: 1, passageWordCount: 30)
        subject.lockdown.temporaryAllowanceResetDays = 2
        for index in 0..<4 {
            let date = now.addingTimeInterval(Double(index) * 3_600)
            MacTemporaryPauseStore.pruneExpired(at: date, defaults: defaults)
            XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: date, defaults: defaults), 30 * (index + 1))
            guard case .success = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: date, defaults: defaults) else { return XCTFail("Expected grant") }
            if index == 1 { MacTemporaryPauseStore.cancel(ruleID: subject.id, defaults: defaults) }
        }
        XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: now.addingTimeInterval(172_800), defaults: defaults), 30)
        let current = now.addingTimeInterval(10_800)
        guard case .failure = MacTemporaryPauseStore.grant(.sixtyMinutes, for: subject, at: current, defaults: defaults) else { return XCTFail("Over-limit grant must fail") }
        XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: current, defaults: defaults), 150)
    }

    private func rule(
        allowsTimeExtensions: Bool = true,
        maximumHours: Int = 2,
        passageWordCount: Int = 40
    ) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(),
            name: "Feeds",
            isEnabled: true,
            enforcementMode: .blockList,
            windows: [],
            domains: ["news.example"],
            macApplicationIdentifiers: [],
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(
                severity: "passageOnly",
                unlockDelayDays: 3,
                passageWordCount: passageWordCount,
                confirmationWindowHours: 24,
                editWindowHours: 24,
                allowsTimeExtensions: allowsTimeExtensions,
                maximumTimeExtensionHours: maximumHours
            )
        )
    }

    func testEnablingBackoffMidSessionNeverShortensExistingPassage() {
        let now = Date()
        var subject = rule(passageWordCount: 40)
        for _ in 0..<3 { _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults) }
        let oldWords = MacTemporaryPauseStore.passageWordCount(for: subject, at: now, defaults: defaults)
        XCTAssertEqual(oldWords, 320)
        subject.lockdown.temporaryAllowanceResetDays = 1
        XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: now, defaults: defaults), oldWords)
    }

    func testTemporaryAccessUsesIndependentPassageWithoutChangingEditPassage() {
        var subject = rule(passageWordCount: 80)
        subject.lockdown.temporaryAccessPassageWordCount = 30
        XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: Date(), defaults: defaults), 30)
        XCTAssertEqual(DesktopRuleEditUnlock.configuration(subject.lockdown).passageWordCount, 80)
    }

    func testGrantingAPauseRecordsAnExpiryAndPublishesIt() {
        let now = Date()
        let subject = rule()

        let result = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)

        guard case let .success(pause) = result else {
            return XCTFail("Expected the pause to be granted")
        }
        XCTAssertEqual(pause.expiresAt.timeIntervalSince(now), 600, accuracy: 1)
        XCTAssertEqual(
            MacTemporaryPauseStore.activeExpirations(at: now, defaults: defaults)[subject.id],
            pause.expiresAt
        )
    }

    /// A rule that never opted into temporary access must not be pausable, or
    /// the button would weaken a policy that deliberately forbids it.
    func testARuleThatDisallowsTemporaryAccessCannotBePaused() {
        let result = MacTemporaryPauseStore.grant(
            .tenMinutes,
            for: rule(allowsTimeExtensions: false),
            at: Date(),
            defaults: defaults
        )

        XCTAssertEqual(result, .failure(.notPermitted))
    }

    /// Extending adds to the end of the current pause rather than restarting
    /// it, so repeated grants cannot quietly stretch past the maximum.
    func testExtendingAccumulatesOntoTheExistingExpiry() {
        let now = Date()
        let subject = rule()

        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)
        let second = MacTemporaryPauseStore.grant(
            .thirtyMinutes,
            for: subject,
            at: now.addingTimeInterval(60),
            defaults: defaults
        )

        guard case let .success(pause) = second else {
            return XCTFail("Expected the extension to be granted")
        }
        XCTAssertEqual(pause.expiresAt.timeIntervalSince(now), 600 + 1_800, accuracy: 1)
        XCTAssertEqual(pause.totalMinutesGranted, 40)
        XCTAssertEqual(pause.grantCount, 2)
    }

    func testSessionMaximumIsEnforced() {
        let now = Date()
        let subject = rule(maximumHours: 1)

        for _ in 0..<2 {
            _ = MacTemporaryPauseStore.grant(.thirtyMinutes, for: subject, at: now, defaults: defaults)
        }
        let overflow = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)

        XCTAssertEqual(overflow, .failure(.exceedsSessionMaximum(maximumMinutes: 60)))
        XCTAssertTrue(MacTemporaryPauseStore.availableDurations(for: subject, at: now, defaults: defaults).isEmpty)
    }

    /// The escalation is shared with iOS, so the second pause in a session
    /// costs the same doubled passage on both platforms.
    func testPassageLengthDoublesWithEachGrantInASession() {
        let now = Date()
        let subject = rule(passageWordCount: 40)

        XCTAssertEqual(
            MacTemporaryPauseStore.passageWordCount(for: subject, at: now, defaults: defaults),
            40
        )
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)
        XCTAssertEqual(
            MacTemporaryPauseStore.passageWordCount(for: subject, at: now, defaults: defaults),
            80
        )
    }

    /// An expired record must never be published, and the session maximum has
    /// to reset once the pause ends rather than counting forever.
    func testExpiredPausesAreNotPublishedAndResetTheSession() {
        let now = Date()
        let subject = rule(maximumHours: 1)
        _ = MacTemporaryPauseStore.grant(.sixtyMinutes, for: subject, at: now, defaults: defaults)

        let later = now.addingTimeInterval(3_601)

        XCTAssertTrue(MacTemporaryPauseStore.activeExpirations(at: later, defaults: defaults).isEmpty)
        XCTAssertNil(MacTemporaryPauseStore.active(for: subject.id, at: later, defaults: defaults))
        XCTAssertEqual(MacTemporaryPauseStore.pruneExpired(at: later, defaults: defaults), 1)
        XCTAssertFalse(
            MacTemporaryPauseStore.availableDurations(for: subject, at: later, defaults: defaults).isEmpty,
            "The session maximum should reset once the pause has expired"
        )
    }

    func testCancellingRemovesThePause() {
        let now = Date()
        let subject = rule()
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)

        XCTAssertTrue(MacTemporaryPauseStore.cancel(ruleID: subject.id, defaults: defaults))
        XCTAssertNil(MacTemporaryPauseStore.active(for: subject.id, at: now, defaults: defaults))
    }
}

extension MacTemporaryPauseStoreTests {
    func testAuthorizationIdentitySurvivesExtensionButChangesAfterExpiry() {
        let now = Date(timeIntervalSince1970: 1_790_000_000.123)
        let subject = rule()
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)
        let first = MacTemporaryPauseStore.activeAuthorizationIDs(at: now, defaults: defaults)[subject.id]
        XCTAssertNotNil(first)
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now.addingTimeInterval(60), defaults: defaults)
        XCTAssertEqual(MacTemporaryPauseStore.activeAuthorizationIDs(at: now, defaults: defaults)[subject.id], first)
        let later = now.addingTimeInterval(1_800)
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: later, defaults: defaults)
        XCTAssertNotEqual(MacTemporaryPauseStore.activeAuthorizationIDs(at: later, defaults: defaults)[subject.id], first)
    }

    /// The Mac honours a sub-hour session maximum, which is the whole point of
    /// configuring one in minutes.
    func testSubHourMaximumOffersOnlyTheDurationsThatFit() {
        let now = Date()
        var subject = rule(maximumHours: 1)
        subject.lockdown.maximumTemporaryAccessMinutes = 5

        let available = MacTemporaryPauseStore.availableDurations(for: subject, at: now, defaults: defaults)

        XCTAssertEqual(available.map(\.minutes), [1, 5])
        guard case .success = MacTemporaryPauseStore.grant(.oneMinute, for: subject, at: now, defaults: defaults) else {
            return XCTFail("A one-minute pause must fit a five-minute maximum")
        }
        guard case .failure = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults) else {
            return XCTFail("Ten minutes must not fit a five-minute maximum")
        }
    }

    // MARK: - Access delay

    private func waitedRule(_ wait: Int) -> DesktopEnforcementRule {
        var subject = rule(maximumHours: 3)
        subject.lockdown.temporaryAccessWaitMinutes = wait
        return subject
    }

    func testGrantWithWaitIsPendingUntilItOpensAndNeverEarly() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000.25)
        let subject = waitedRule(10)
        guard case let .success(pause) = MacTemporaryPauseStore.grant(.thirtyMinutes, for: subject, at: now, defaults: defaults)
        else { return XCTFail("Expected grant") }
        let opens = try XCTUnwrap(pause.opensAt)
        XCTAssertEqual(opens, Date(timeIntervalSince1970: 1_790_000_601), "Wait rounds up to a whole second")
        XCTAssertEqual(pause.expiresAt, opens.addingTimeInterval(1_800), "The wait does not shorten the access")
        XCTAssertEqual(pause.totalMinutesGranted, 30, "Charged when granted")
        XCTAssertTrue(MacTemporaryPauseStore.activeExpirations(at: now, defaults: defaults).isEmpty)
        XCTAssertNil(MacTemporaryPauseStore.open(for: subject.id, at: opens.addingTimeInterval(-0.5), defaults: defaults))
        XCTAssertEqual(MacTemporaryPauseStore.pendingIntervals(at: now, defaults: defaults)[subject.id],
                       DateInterval(start: opens, end: pause.expiresAt))
        XCTAssertEqual(MacTemporaryPauseStore.activeExpirations(at: opens, defaults: defaults)[subject.id], pause.expiresAt)
        XCTAssertTrue(MacTemporaryPauseStore.pendingIntervals(at: opens, defaults: defaults).isEmpty)
        XCTAssertTrue(MacTemporaryPauseStore.activeExpirations(at: pause.expiresAt, defaults: defaults).isEmpty)
    }

    func testPendingGrantCanBeCancelledAndIsNotRefunded() {
        let now = Date()
        var subject = waitedRule(10)
        subject.lockdown.temporaryAllowanceResetDays = 2
        _ = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)
        XCTAssertTrue(MacTemporaryPauseStore.cancel(ruleID: subject.id, defaults: defaults))
        XCTAssertTrue(MacTemporaryPauseStore.pendingIntervals(at: now, defaults: defaults).isEmpty)
        XCTAssertTrue(MacTemporaryPauseStore.activeExpirations(at: now.addingTimeInterval(700), defaults: defaults).isEmpty)
        XCTAssertEqual(MacTemporaryPauseStore.passageWordCount(for: subject, at: now, defaults: defaults), 80,
                       "The backoff charge of a cancelled pending grant stays")
    }

    func testSecondRequestNeverOpensEarlierAndCannotLeaveAGap() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let subject = waitedRule(10)
        guard case let .success(first) = MacTemporaryPauseStore.grant(.thirtyMinutes, for: subject, at: now, defaults: defaults)
        else { return XCTFail("Expected grant") }
        let later = now.addingTimeInterval(120)
        guard case let .success(second) = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: later, defaults: defaults)
        else { return XCTFail("A contiguous extension is granted") }
        XCTAssertEqual(second.opensAt, first.opensAt, "Stacking never moves the opening earlier")
        XCTAssertEqual(second.expiresAt, first.expiresAt.addingTimeInterval(600))
        XCTAssertEqual(second.grantCount, 2)

        // A short grant whose end comes before this request's own wait is over.
        MacTemporaryPauseStore.cancel(ruleID: subject.id, defaults: defaults)
        let long = waitedRule(60)
        guard case let .success(short) = MacTemporaryPauseStore.grant(.oneMinute, for: long, at: now, defaults: defaults)
        else { return XCTFail("Expected grant") }
        XCTAssertEqual(
            MacTemporaryPauseStore.grant(.tenMinutes, for: long, at: now.addingTimeInterval(300), defaults: defaults),
            .failure(.alreadyScheduled(endsAt: short.expiresAt)))
        XCTAssertEqual(MacTemporaryPauseStore.active(for: long.id, at: now, defaults: defaults), short,
                       "A refused request changes nothing")
    }

    func testNoWaitGrantIsOpenImmediatelyAsBefore() {
        let now = Date()
        let subject = rule()
        guard case let .success(pause) = MacTemporaryPauseStore.grant(.tenMinutes, for: subject, at: now, defaults: defaults)
        else { return XCTFail("Expected grant") }
        XCTAssertNil(pause.opensAt)
        XCTAssertEqual(pause.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(MacTemporaryPauseStore.activeExpirations(at: now, defaults: defaults)[subject.id], pause.expiresAt)
    }
}
