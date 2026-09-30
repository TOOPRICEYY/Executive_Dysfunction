import XCTest

final class ClockTamperGuardTests: XCTestCase {
    private let boot = "boot-A"
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() {
        ClockTamperGuard.shared.setOffsetForTesting(0)
        super.tearDown()
    }

    func testSameBootTracksContinuousClock() {
        let first = TrustedClock.evaluate(wall: start, clock: reading(100), anchor: nil)
        let later = TrustedClock.evaluate(
            wall: start.addingTimeInterval(3_600),
            clock: reading(3_700),
            anchor: first.anchor
        )
        XCTAssertFalse(later.tampered)
        XCTAssertEqual(later.trustedNow, start.addingTimeInterval(3_600))
    }

    func testForwardJumpWithinBootIsDetected() {
        let first = TrustedClock.evaluate(wall: start, clock: reading(100), anchor: nil)
        let jumped = TrustedClock.evaluate(
            wall: start.addingTimeInterval(10 * 3_600),
            clock: reading(160),
            anchor: first.anchor
        )
        XCTAssertTrue(jumped.tampered)
        XCTAssertEqual(jumped.trustedNow, start.addingTimeInterval(60))
    }

    func testSmallStepsCannotWalkTheClock() {
        var anchor = TrustedClock.evaluate(wall: start, clock: reading(0), anchor: nil).anchor
        var wall = start
        var tampered = false
        for step in 1...10 {
            wall = wall.addingTimeInterval(100)   // each step inside tolerance
            let evaluation = TrustedClock.evaluate(wall: wall, clock: reading(TimeInterval(step)), anchor: anchor)
            anchor = evaluation.anchor
            tampered = tampered || evaluation.tampered
        }
        XCTAssertTrue(tampered, "The anchor never moves within a boot, so steps accumulate")
    }

    func testBackwardMoveAcrossRebootIsDetected() {
        let first = TrustedClock.evaluate(wall: start, clock: reading(100), anchor: nil)
        let afterReboot = TrustedClock.evaluate(
            wall: start.addingTimeInterval(-86_400),
            clock: SystemClockReading(bootIdentifier: "boot-B", continuousUptime: 30),
            anchor: first.anchor
        )
        XCTAssertTrue(afterReboot.tampered)
        XCTAssertEqual(afterReboot.trustedNow, start)
    }

    func testTamperedEvaluationEnforcesUnionOfBothInstants() {
        let calendar = Calendar(identifier: .gregorian)
        let noon = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 12))!
        let weekday = calendar.component(.weekday, from: noon)
        let policy = DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: noon,
            rules: [DesktopEnforcementRule(
                id: UUID(), name: "Work", isEnabled: true, enforcementMode: .blockList,
                windows: [.init(weekdays: [weekday], startMinutes: 9 * 60, endMinutes: 17 * 60)],
                domains: ["example.com"], macApplicationIdentifiers: [], windowsExecutablePaths: [],
                windowsPublisherRules: [],
                lockdown: DesktopLockdownPolicy(severity: "delayed", unlockDelayDays: 3, passageWordCount: 40,
                    confirmationWindowHours: 24, editWindowHours: 24, allowsTimeExtensions: false,
                    maximumTimeExtensionHours: 1)
            )],
            weakeningAuthorizationExpiresAt: nil
        )
        // Wall clock moved to 20:00; trusted time is still noon.
        let evening = noon.addingTimeInterval(8 * 3_600)
        XCTAssertTrue(policy.activeRules(at: evening, calendar: calendar).isEmpty)
        ClockTamperGuard.shared.setOffsetForTesting(-8 * 3_600)
        XCTAssertEqual(policy.activeRules(at: evening, calendar: calendar).count, 1)
    }

    private func reading(_ uptime: TimeInterval) -> SystemClockReading {
        SystemClockReading(bootIdentifier: boot, continuousUptime: uptime)
    }
}
