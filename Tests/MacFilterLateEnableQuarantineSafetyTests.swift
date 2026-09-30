import XCTest

final class MacFilterLateEnableQuarantineSafetyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let generation: UInt64 = 41
    private let bootID = "boot-a"

    func testStartsWithImmediateBoundedAttemptAndSchedulesPeriodicRetry() throws {
        let initial = try XCTUnwrap(makeState())
        XCTAssertEqual(initial.deadline, now.addingTimeInterval(30))

        let claimed = advance(initial, now: now)
        XCTAssertEqual(claimed.command, .verifyAndRemove(attemptSequence: 1))
        let inFlight = try XCTUnwrap(claimed.state)

        let completed = complete(inFlight, attempt: 1, now: now.addingTimeInterval(2))
        XCTAssertEqual(completed.command, .wait(until: now.addingTimeInterval(7)))
        let waiting = try XCTUnwrap(completed.state)
        XCTAssertEqual(
            advance(waiting, now: now.addingTimeInterval(6)).command,
            .wait(until: now.addingTimeInterval(7))
        )
        XCTAssertEqual(
            advance(waiting, now: now.addingTimeInterval(7)).command,
            .verifyAndRemove(attemptSequence: 2)
        )
    }

    func testSuccessfulRemovalDoesNotEndGraceWindow() throws {
        let first = advance(try XCTUnwrap(makeState()), now: now)
        let afterSuccess = complete(
            try XCTUnwrap(first.state),
            attempt: 1,
            now: now.addingTimeInterval(1)
        )
        XCTAssertNotNil(afterSuccess.state)
        XCTAssertEqual(afterSuccess.command, .wait(until: now.addingTimeInterval(6)))
    }

    func testOnlyOneAttemptCanBeInFlightAndLateAttemptIsFenced() throws {
        let claimed = advance(try XCTUnwrap(makeState()), now: now)
        let inFlight = try XCTUnwrap(claimed.state)
        XCTAssertEqual(
            advance(inFlight, now: now.addingTimeInterval(1)).command,
            .wait(until: inFlight.deadline)
        )
        XCTAssertEqual(
            complete(inFlight, attempt: 2, now: now.addingTimeInterval(1)).command,
            .ignoreStaleAttempt
        )
        XCTAssertEqual(inFlight.activeAttemptSequence, 1)
    }

    func testGenerationIntentAndBootChangesFenceScheduler() throws {
        let state = try XCTUnwrap(makeState())
        XCTAssertEqual(
            advance(state, generation: generation + 1, now: now).command,
            .cancel
        )
        XCTAssertEqual(
            advance(state, wantsDisabled: false, now: now).command,
            .cancel
        )
        XCTAssertEqual(
            advance(state, bootID: "boot-b", now: now).command,
            .finished
        )
    }

    func testGraceDeadlineStopsNewAndLateAttempts() throws {
        let state = try XCTUnwrap(makeState())
        XCTAssertEqual(
            advance(state, now: state.deadline).command,
            .finished
        )

        let claimed = advance(state, now: now)
        let late = complete(
            try XCTUnwrap(claimed.state),
            attempt: 1,
            now: state.deadline
        )
        XCTAssertNil(late.state)
        XCTAssertEqual(late.command, .finished)
    }

    func testEnabledPreferenceIsDeniedOnlyDuringMatchingActiveQuarantine() throws {
        let state = try XCTUnwrap(makeState())
        XCTAssertFalse(allowsEnable(state, now: now))
        XCTAssertTrue(allowsEnable(state, generation: generation + 1, now: now))
        XCTAssertTrue(allowsEnable(state, bootID: "boot-b", now: now))
        XCTAssertTrue(allowsEnable(state, now: state.deadline))
        XCTAssertTrue(allowsEnable(nil, now: now))
    }

    func testMissingBootEvidenceFailsClosedForBoundedWindow() throws {
        let state = try XCTUnwrap(makeState(bootID: nil))
        XCTAssertFalse(allowsEnable(state, bootID: "boot-b", now: now))
        XCTAssertEqual(
            advance(state, bootID: nil, now: now).command,
            .verifyAndRemove(attemptSequence: 1)
        )
    }

    func testRejectsUnboundedOrNonpositiveConfiguration() {
        XCTAssertNil(makeState(grace: .infinity))
        XCTAssertNil(makeState(grace: 0))
        XCTAssertNil(makeState(interval: .nan))
        XCTAssertNil(makeState(interval: -1))
    }

    private func makeState(
        bootID: String? = "boot-a",
        grace: TimeInterval = 30,
        interval: TimeInterval = 5
    ) -> MacFilterLateEnableQuarantineState? {
        MacFilterLateEnableQuarantineSafety.start(
            generation: generation,
            bootSessionIdentifier: bootID,
            now: now,
            gracePeriod: grace,
            retryInterval: interval
        )
    }

    private func advance(
        _ state: MacFilterLateEnableQuarantineState,
        generation: UInt64? = nil,
        bootID: String? = "boot-a",
        wantsDisabled: Bool = true,
        now: Date
    ) -> MacFilterLateEnableQuarantineTransition {
        MacFilterLateEnableQuarantineSafety.advance(
            state,
            currentGeneration: generation ?? self.generation,
            currentBootSessionIdentifier: bootID,
            stillWantsDisabled: wantsDisabled,
            now: now
        )
    }

    private func complete(
        _ state: MacFilterLateEnableQuarantineState,
        attempt: UInt64,
        generation: UInt64? = nil,
        bootID: String? = "boot-a",
        wantsDisabled: Bool = true,
        now: Date
    ) -> MacFilterLateEnableQuarantineTransition {
        MacFilterLateEnableQuarantineSafety.completeAttempt(
            state,
            attemptSequence: attempt,
            currentGeneration: generation ?? self.generation,
            currentBootSessionIdentifier: bootID,
            stillWantsDisabled: wantsDisabled,
            now: now
        )
    }

    private func allowsEnable(
        _ state: MacFilterLateEnableQuarantineState?,
        generation: UInt64? = nil,
        bootID: String? = "boot-a",
        now: Date
    ) -> Bool {
        MacFilterLateEnableQuarantineSafety.allowsEnabledPreference(
            during: state,
            currentGeneration: generation ?? self.generation,
            currentBootSessionIdentifier: bootID,
            now: now
        )
    }
}
