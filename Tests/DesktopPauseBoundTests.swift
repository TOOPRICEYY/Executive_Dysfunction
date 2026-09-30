import XCTest

/// A hand-edited pause ledger must not be able to hold a rule open longer than
/// the rule's own session maximum, however often the app republishes it.
final class DesktopPauseBoundTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testAppClampsForgedExpiryToSessionMaximum() {
        let forged = now.addingTimeInterval(5 * 365 * 86_400)
        XCTAssertEqual(
            DesktopBlockProfile.clampedPause(forged, maximumHours: 3, now: now),
            now.addingTimeInterval(3 * 3_600)
        )
        XCTAssertNil(DesktopBlockProfile.clampedPause(now.addingTimeInterval(-1), maximumHours: 3, now: now))
        XCTAssertNil(DesktopBlockProfile.clampedPause(forged, maximumHours: 0, now: now))
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
