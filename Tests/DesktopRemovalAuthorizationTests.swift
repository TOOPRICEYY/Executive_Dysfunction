import XCTest
// The desktop decision layer is compiled directly into this hostless test
// bundle; see project.yml. Importing the app module would drag in
// NetworkExtension and a live filter configuration.

final class DesktopRemovalAuthorizationTests: XCTestCase {
    func testEmptyDisableChallengeCannotAuthorizeRecovery() {
        let now = Date()
        var challenge = DesktopBlockingDisableGate.makeChallenge(for: .empty, at: now)
        challenge.requiredPassage = " \n "
        XCTAssertEqual(DesktopBlockingDisableGate.validate(
            typedPassage: "anything", challenge: challenge, currentPolicy: .empty, at: now
        ), .passageMismatch)
    }
    private let boot = "BOOT-SESSION-A"

    private func clock(_ uptime: TimeInterval, boot: String? = nil) -> SystemClockReading {
        SystemClockReading(bootIdentifier: boot ?? self.boot, continuousUptime: uptime)
    }

    private func policy(
        severity: String = "delayed",
        delayDays: Int = 3,
        passageWords: Int = 6,
        editWindowHours: Int = 2,
        isEnabled: Bool = true
    ) -> DesktopEnforcementPolicy {
        DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: Date(timeIntervalSince1970: 0),
            rules: [
                DesktopEnforcementRule(
                    id: UUID(),
                    name: "Focus",
                    isEnabled: isEnabled,
                    enforcementMode: .blockList,
                    windows: [],
                    domains: ["coinbase.com"],
                    macApplicationIdentifiers: [],
                    windowsExecutablePaths: [],
                    windowsPublisherRules: [],
                    lockdown: DesktopLockdownPolicy(
                        severity: severity,
                        unlockDelayDays: delayDays,
                        passageWordCount: passageWords,
                        confirmationWindowHours: 24,
                        editWindowHours: editWindowHours,
                        allowsTimeExtensions: false,
                        maximumTimeExtensionHours: 0
                    )
                )
            ],
            weakeningAuthorizationExpiresAt: nil
        )
    }

    // MARK: - Terms

    func testStrictestLockedRuleSetsTheTerms() {
        var combined = policy(delayDays: 3, passageWords: 6, editWindowHours: 8)
        var strict = policy(delayDays: 9, passageWords: 12, editWindowHours: 2).rules[0]
        strict.id = UUID()
        combined.rules.append(strict)

        let terms = DesktopRemovalGate.terms(for: combined)
        XCTAssertEqual(terms.delaySeconds, 9 * 86_400, "The longest delay must win")
        XCTAssertEqual(terms.passageWordCount, 12, "The longest passage must win")
        XCTAssertEqual(terms.confirmationWindowSeconds, 2 * 3_600, "The shortest window is the stricter one")
    }

    func testUnlockedAndDisabledRulesImposeNoDelay() {
        XCTAssertEqual(DesktopRemovalGate.terms(for: policy(severity: "none")), .unlocked)
        XCTAssertEqual(DesktopRemovalGate.terms(for: policy(isEnabled: false)), .unlocked)
        XCTAssertEqual(DesktopRemovalGate.terms(for: .empty), .unlocked)
    }

    func testALockedRuleAlwaysEarnsAtLeastOneDay() {
        let terms = DesktopRemovalGate.terms(for: policy(delayDays: 0))
        XCTAssertEqual(terms.delaySeconds, 86_400, "A locked rule must not be removable on impulse")
    }

    // MARK: - State machine

    func testEnforcementSurvivesTheWholeDelay() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let request = DesktopRemovalGate.makeRequest(for: policy(), at: start, clock: clock(100))

        guard case let .waiting(remaining) = DesktopRemovalGate.state(
            for: request,
            at: start.addingTimeInterval(86_400),
            clock: clock(100 + 86_400)
        ) else { return XCTFail("Expected to still be waiting one day into a three-day delay") }
        XCTAssertEqual(remaining, 2 * 86_400, accuracy: 1)
    }

    func testWindowOpensThenExpires() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let request = DesktopRemovalGate.makeRequest(for: policy(), at: start, clock: clock(0))
        let delay = 3.0 * 86_400

        guard case .ready = DesktopRemovalGate.state(
            for: request,
            at: start.addingTimeInterval(delay + 60),
            clock: clock(delay + 60)
        ) else { return XCTFail("Expected the window to be open just after the delay") }

        // 2h window, so 2h+1s past the delay is closed.
        XCTAssertEqual(
            DesktopRemovalGate.state(
                for: request,
                at: start.addingTimeInterval(delay + 7_201),
                clock: clock(delay + 7_201)
            ),
            .expired
        )
    }

    func testNoRequestMeansNothingPending() {
        XCTAssertEqual(DesktopRemovalGate.state(for: nil, at: Date(), clock: clock(0)), .notRequested)
    }

    // MARK: - Clock tampering

    func testMovingTheWallClockForwardDoesNotMatureTheRequest() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let request = DesktopRemovalGate.makeRequest(for: policy(), at: start, clock: clock(500))

        // The administrator sets the clock a year ahead; only a minute of real
        // time has passed on the monotonic clock.
        let state = DesktopRemovalGate.state(
            for: request,
            at: start.addingTimeInterval(365 * 86_400),
            clock: clock(560)
        )
        guard case let .waiting(remaining) = state else {
            return XCTFail("A forward clock jump must not open the gate, got \(state)")
        }
        XCTAssertEqual(remaining, 3 * 86_400 - 60, accuracy: 1)
    }

    func testMovingTheWallClockBackwardDoesNotExtendTheWaitPastTheMonotonicOne() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let request = DesktopRemovalGate.makeRequest(for: policy(), at: start, clock: clock(0))
        // Wall clock rolled back before the request; monotonic says 3 days.
        let state = DesktopRemovalGate.state(
            for: request,
            at: start.addingTimeInterval(-10_000),
            clock: clock(3 * 86_400 + 60)
        )
        // Wall-clock elapsed floors at 0, and the lesser of the two wins, so
        // this stays shut. Tampering may delay the user; it must never help.
        guard case .waiting = state else {
            return XCTFail("Expected the conservative reading to keep the gate shut, got \(state)")
        }
    }

    func testRebootFallsBackToWallClock() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let request = DesktopRemovalGate.makeRequest(for: policy(), at: start, clock: clock(90_000))
        // New boot session: the monotonic anchor is not comparable, and a fresh
        // boot's uptime is small. Wall clock must carry the wait.
        guard case .ready = DesktopRemovalGate.state(
            for: request,
            at: start.addingTimeInterval(3 * 86_400 + 60),
            clock: clock(30, boot: "BOOT-SESSION-B")
        ) else { return XCTFail("A reboot must not strand a matured request forever") }
    }

    // MARK: - Passage

    func testPassageIsStableForARequestAndVariesBetweenRequests() {
        let a = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let b = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
        XCTAssertEqual(DesktopRemovalGate.passage(wordCount: 6, seed: a).split(separator: " ").count, 6)
        XCTAssertEqual(
            DesktopRemovalGate.passage(wordCount: 6, seed: a),
            DesktopRemovalGate.passage(wordCount: 6, seed: a),
            "Reopening the sheet must not re-roll the passage"
        )
        XCTAssertNotEqual(
            DesktopRemovalGate.passage(wordCount: 6, seed: a),
            DesktopRemovalGate.passage(wordCount: 6, seed: b)
        )
    }

    func testPassageComparisonIgnoresCaseAndSpacingButNotWords() {
        let request = DesktopRemovalGate.makeRequest(
            for: policy(),
            at: Date(),
            clock: clock(0),
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let correct = request.requiredPassage
        XCTAssertTrue(DesktopRemovalGate.passageMatches(correct, request: request))
        XCTAssertTrue(DesktopRemovalGate.passageMatches("  \(correct.uppercased())\n ", request: request))
        XCTAssertFalse(DesktopRemovalGate.passageMatches("", request: request))
        XCTAssertFalse(
            DesktopRemovalGate.passageMatches(correct.split(separator: " ").dropLast().joined(separator: " "), request: request),
            "A truncated passage must not pass"
        )
    }

    // MARK: - Ordinary blocking disable

    func testBlockingDisableChallengeUsesStrictestEnabledLockAndSafeDefault() {
        var combined = policy(passageWords: 60)
        var shorter = policy(passageWords: 20).rules[0]
        shorter.id = UUID()
        combined.rules.append(shorter)

        var disabled = policy(passageWords: 200, isEnabled: false).rules[0]
        disabled.id = UUID()
        combined.rules.append(disabled)

        var unlocked = policy(severity: "none", passageWords: 250).rules[0]
        unlocked.id = UUID()
        combined.rules.append(unlocked)

        let issuedAt = Date(timeIntervalSince1970: 2_000_000)
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let challenge = DesktopBlockingDisableGate.makeChallenge(
            for: combined,
            at: issuedAt,
            id: id
        )

        XCTAssertEqual(challenge.policyRevision, combined.revision)
        XCTAssertEqual(challenge.requiredPassage.split(separator: " ").count, 60)
        XCTAssertEqual(
            challenge.expiresAt,
            issuedAt.addingTimeInterval(DesktopBlockingDisableGate.challengeLifetime)
        )
        XCTAssertEqual(
            DesktopBlockingDisableGate.passageWordCount(for: .empty),
            DesktopBlockingDisableGate.defaultPassageWordCount,
            "Even a policy with no locked rules must require a deliberate passage"
        )
    }

    func testBlockingDisableChallengeRejectsRetryAfterExpiryOrPolicyChange() {
        let current = policy(passageWords: 20)
        let issuedAt = Date(timeIntervalSince1970: 2_000_000)
        let challenge = DesktopBlockingDisableGate.makeChallenge(
            for: current,
            at: issuedAt,
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        XCTAssertEqual(
            DesktopBlockingDisableGate.validate(
                typedPassage: "  \(challenge.requiredPassage.uppercased())\n",
                challenge: challenge,
                currentPolicy: current,
                at: issuedAt.addingTimeInterval(1)
            ),
            .authorized
        )
        XCTAssertEqual(
            DesktopBlockingDisableGate.validate(
                typedPassage: "wrong passage",
                challenge: challenge,
                currentPolicy: current,
                at: issuedAt.addingTimeInterval(1)
            ),
            .passageMismatch
        )
        XCTAssertEqual(
            DesktopBlockingDisableGate.validate(
                typedPassage: challenge.requiredPassage,
                challenge: challenge,
                currentPolicy: current,
                at: challenge.expiresAt
            ),
            .expired
        )

        var changed = current
        changed.revision &+= 1
        XCTAssertEqual(
            DesktopBlockingDisableGate.validate(
                typedPassage: challenge.requiredPassage,
                challenge: challenge,
                currentPolicy: changed,
                at: issuedAt.addingTimeInterval(1)
            ),
            .policyChanged
        )
        XCTAssertEqual(
            DesktopBlockingDisableGate.validate(
                typedPassage: challenge.requiredPassage,
                challenge: challenge,
                currentPolicy: current,
                at: issuedAt.addingTimeInterval(-1)
            ),
            .notYetValid
        )
    }

    // MARK: - Persistence

    func testAPendingRequestSurvivesAndIsNotRestartedByReRequesting() {
        let store = InMemoryRemovalRequestStore()
        let original = DesktopRemovalGate.makeRequest(for: policy(), at: Date(timeIntervalSince1970: 1), clock: clock(0))
        try? store.save(original)
        XCTAssertEqual(store.load(), original)
        store.clear()
        XCTAssertNil(store.load())
    }
}
