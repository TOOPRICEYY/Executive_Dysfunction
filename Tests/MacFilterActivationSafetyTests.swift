import XCTest

final class MacFilterActivationSafetyTests: XCTestCase {
    private let bootTime = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoRecordAllowsActivation() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: nil,
                currentBootSessionIdentifier: "boot-a",
                currentEstimatedBootTime: bootTime,
                currentSystemUptime: 1
            ),
            .clear
        )
    }

    func testSameBootIdentifierKeepsActivationLocked() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: "boot-a"),
                currentBootSessionIdentifier: "boot-a",
                currentEstimatedBootTime: bootTime.addingTimeInterval(60),
                currentSystemUptime: 1
            ),
            .lockedUntilRestart
        )
    }

    func testDifferentBootIdentifierReleasesInterlock() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: "boot-a"),
                currentBootSessionIdentifier: "boot-b",
                currentEstimatedBootTime: bootTime,
                currentSystemUptime: 1_000
            ),
            .restartObserved
        )
    }

    func testBootTimeFallbackKeepsSameBootLocked() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(2),
                currentSystemUptime: 180
            ),
            .lockedUntilRestart
        )
    }

    func testUptimeFallbackRecognizesEarlyRestart() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(30),
                currentSystemUptime: 30
            ),
            .restartObserved
        )
    }

    func testMissingCurrentUUIDDoesNotOverrideSameBootFallback() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: "boot-a"),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime,
                currentSystemUptime: 180
            ),
            .lockedUntilRestart
        )
    }

    func testPositiveWallClockCorrectionDoesNotReleaseSameBootInterlock() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(3_600),
                currentSystemUptime: 180
            ),
            .lockedUntilRestart
        )
    }

    func testNegativeWallClockCorrectionDoesNotReleaseSameBootInterlock() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(-3_600),
                currentSystemUptime: 180
            ),
            .lockedUntilRestart
        )
    }

    func testEarlyPostRestartUptimeRollbackReleasesInterlockDespiteClockChange() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(86_400),
                currentSystemUptime: 30
            ),
            .restartObserved
        )
    }

    func testLatePostRestartWithoutUUIDRemainsLockedWhenBootIdentityIsAmbiguous() {
        XCTAssertEqual(
            MacFilterActivationSafetyGate.state(
                record: record(bootIdentifier: nil),
                currentBootSessionIdentifier: nil,
                currentEstimatedBootTime: bootTime.addingTimeInterval(86_400),
                currentSystemUptime: 180
            ),
            .lockedUntilRestart
        )
    }

    private func record(bootIdentifier: String?) -> MacFilterActivationSafetyRecord {
        MacFilterActivationSafetyRecord(
            bootSessionIdentifier: bootIdentifier,
            estimatedBootTime: bootTime,
            triggeredAt: bootTime.addingTimeInterval(120),
            reason: "provider-startup-watchdog"
        )
    }
}
