import XCTest

final class ExternalFilterToggleGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testOwnSavesAndIntendedDisablesAreIgnored() {
        XCTAssertEqual(decide(intends: false, inFlight: false, enabled: false, since: nil), .none)
        XCTAssertEqual(decide(intends: true, inFlight: true, enabled: false, since: nil), .none)
        XCTAssertEqual(decide(intends: true, inFlight: false, enabled: true, since: nil), .none)
    }

    func testExternalDisableIsRecordedThenReenabledAfterGrace() {
        XCTAssertEqual(
            decide(intends: true, inFlight: false, enabled: false, since: nil),
            .recordAndSchedule(reenableAt: now.addingTimeInterval(ExternalFilterToggleGate.reenableGrace))
        )
        XCTAssertEqual(decide(intends: true, inFlight: false, enabled: false, since: now.addingTimeInterval(-60)), .none)
        XCTAssertEqual(
            decide(intends: true, inFlight: false, enabled: false,
                   since: now.addingTimeInterval(-ExternalFilterToggleGate.reenableGrace)),
            .reenable
        )
    }

    func testRecoveryOrPassageDisableClearsTheObservation() {
        XCTAssertEqual(decide(intends: true, inFlight: false, enabled: true, since: now), .clear)
        XCTAssertEqual(decide(intends: false, inFlight: false, enabled: false, since: now), .clear)
    }

    private func decide(intends: Bool, inFlight: Bool, enabled: Bool, since: Date?) -> ExternalFilterToggleGate.Action {
        ExternalFilterToggleGate.decide(
            .init(appIntendsEnforcement: intends, mutationInFlight: inFlight,
                  preferenceEnabled: enabled, firstObservedOffAt: since),
            at: now
        )
    }
}
