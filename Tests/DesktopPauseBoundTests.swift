import XCTest

/// A hand-edited pause ledger must not be able to hold a rule open longer than
/// the rule's own session maximum, however often the app republishes it.
final class DesktopPauseBoundTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testAppClampsForgedExpiryToSessionMaximum() {
        let forged = now.addingTimeInterval(5 * 365 * 86_400)
        XCTAssertEqual(
            DesktopBlockProfile.clampedPause(forged, maximumMinutes: 180, now: now),
            now.addingTimeInterval(3 * 3_600)
        )
        XCTAssertNil(DesktopBlockProfile.clampedPause(now.addingTimeInterval(-1), maximumMinutes: 180, now: now))
        XCTAssertNil(DesktopBlockProfile.clampedPause(forged, maximumMinutes: 0, now: now))
    }

    func testFilterCapsSessionFromFirstSightingAcrossRepublishes() {
        let forged = now.addingTimeInterval(365 * 86_400)
        let first = makePolicy(pausedUntil: forged).boundingPauses(from: .empty, at: now)
        XCTAssertEqual(first.rules[0].pausedUntil, now.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(first.rules[0].pauseSessionStartedAt, now)

        // Two hours later the app republishes the same forged claim.
        let later = now.addingTimeInterval(2 * 3_600)
        let second = makePolicy(pausedUntil: forged).boundingPauses(from: first, at: later)
        XCTAssertEqual(second.rules[0].pausedUntil, now.addingTimeInterval(3 * 3_600),
                       "The ceiling is anchored to the first sighting, not the latest publish")

        // After the ceiling, a continuing claim earns nothing more.
        let exhausted = now.addingTimeInterval(4 * 3_600)
        let third = makePolicy(pausedUntil: forged).boundingPauses(from: second, at: exhausted)
        XCTAssertNil(third.rules[0].pausedUntil)
        XCTAssertEqual(third.rules[0].pauseSessionStartedAt, now, "An exhausted session is remembered")
        let fourth = makePolicy(pausedUntil: forged).boundingPauses(from: third, at: exhausted.addingTimeInterval(60))
        XCTAssertNil(fourth.rules[0].pausedUntil)
    }

    func testSessionResetsOnceTheAppStopsClaimingAPause() {
        let first = makePolicy(pausedUntil: now.addingTimeInterval(1_800)).boundingPauses(from: .empty, at: now)
        let cleared = makePolicy(pausedUntil: nil).boundingPauses(from: first, at: now.addingTimeInterval(1_900))
        XCTAssertNil(cleared.rules[0].pauseSessionStartedAt)

        let regrantAt = now.addingTimeInterval(7_200)
        let regrant = makePolicy(pausedUntil: regrantAt.addingTimeInterval(3_600))
            .boundingPauses(from: cleared, at: regrantAt)
        XCTAssertEqual(regrant.rules[0].pausedUntil, regrantAt.addingTimeInterval(3_600))
    }

    func testRuleWithoutTemporaryAccessCarriesNoPause() {
        var policy = makePolicy(pausedUntil: now.addingTimeInterval(600))
        policy.rules[0].lockdown.allowsTimeExtensions = false
        XCTAssertNil(policy.boundingPauses(from: .empty, at: now).rules[0].pausedUntil)
    }

    func testNativeOnlyRuleKeepsItsPause() {
        var policy = makePolicy(pausedUntil: now.addingTimeInterval(600))
        policy.rules[0].lockdown.allowsTimeExtensions = false
        policy.rules[0].lockdown.requiresNativeTemporaryAccess = true
        XCTAssertEqual(policy.boundingPauses(from: .empty, at: now).rules[0].pausedUntil,
                       now.addingTimeInterval(600))
    }

    func testMinuteBasedNativePauseSurvivesWithZeroLegacyHours() {
        var policy = makePolicy(pausedUntil: now.addingTimeInterval(600))
        policy.rules[0].lockdown.allowsTimeExtensions = false
        policy.rules[0].lockdown.requiresNativeTemporaryAccess = true
        policy.rules[0].lockdown.maximumTimeExtensionHours = 0
        policy.rules[0].lockdown.maximumTemporaryAccessMinutes = 30
        let accepted = policy.boundingPauses(from: .empty, at: now)
        XCTAssertEqual(accepted.rules[0].pausedUntil, now.addingTimeInterval(600))
        XCTAssertTrue(accepted.activeRules(at: now).isEmpty)
    }

    func testMinuteMaximumRemainsAnchoredAcrossRepublishes() {
        var policy = makePolicy(pausedUntil: now.addingTimeInterval(7_200))
        policy.rules[0].lockdown.maximumTimeExtensionHours = 1
        policy.rules[0].lockdown.maximumTemporaryAccessMinutes = 90
        let first = policy.boundingPauses(from: .empty, at: now)
        XCTAssertEqual(first.rules[0].pausedUntil, now.addingTimeInterval(5_400))
        let later = policy.boundingPauses(from: first, at: now.addingTimeInterval(600))
        XCTAssertEqual(later.rules[0].pausedUntil, first.rules[0].pausedUntil)
    }

    func testNewAuthorizedSessionDoesNotInheritYesterdayExhaustedCap() {
        var yesterday = makePolicy(pausedUntil: nil)
        yesterday.rules[0].pauseSessionStartedAt = now.addingTimeInterval(-86_400)
        yesterday.rules[0].pauseAuthorizationID = "yesterday"
        var today = makePolicy(pausedUntil: now.addingTimeInterval(600))
        today.rules[0].pauseAuthorizationID = "today"
        let accepted = today.boundingPauses(from: yesterday, at: now)
        XCTAssertEqual(accepted.rules[0].pausedUntil, now.addingTimeInterval(600))
        XCTAssertEqual(accepted.rules[0].pauseSessionStartedAt, now)

        today.rules[0].pausedUntil = now.addingTimeInterval(86_400)
        let republished = today.boundingPauses(from: accepted, at: now.addingTimeInterval(600))
        XCTAssertEqual(republished.rules[0].pausedUntil, now.addingTimeInterval(10_800))
        XCTAssertEqual(republished.rules[0].pauseSessionStartedAt, now)
    }

    private func makePolicy(pausedUntil: Date?) -> DesktopEnforcementPolicy {
        DesktopEnforcementPolicy(
            revision: 2,
            issuedAt: now,
            rules: [DesktopEnforcementRule(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                name: "Social",
                isEnabled: true,
                enforcementMode: .blockList,
                windows: [],
                domains: ["example.com"],
                macApplicationIdentifiers: [],
                windowsExecutablePaths: [],
                windowsPublisherRules: [],
                lockdown: DesktopLockdownPolicy(
                    severity: "delayed",
                    unlockDelayDays: 3,
                    passageWordCount: 40,
                    confirmationWindowHours: 24,
                    editWindowHours: 24,
                    allowsTimeExtensions: true,
                    maximumTimeExtensionHours: 3
                ),
                pausedUntil: pausedUntil
            )],
            weakeningAuthorizationExpiresAt: nil
        )
    }
}
