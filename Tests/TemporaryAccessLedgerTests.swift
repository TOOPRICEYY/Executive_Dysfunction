import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class TemporaryAccessLedgerTests: XCTestCase {
    func testPauseTransfersWithoutRestartingItsClockAndCancellationWins() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 10, pauseEndsIn: 600))
        let imported = ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], at: now.addingTimeInterval(120))
        XCTAssertEqual(imported[rule]?.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(ledger.additionalCommittedMinutes(forRule: rule, localMinutes: 10, at: now), 0)
        var cancellation = contribution(device: phone, minutes: 0, pauseEndsIn: -1)
        cancellation.updatedAt = now.addingTimeInterval(130)
        ledger.record(cancellation)
        XCTAssertNil(ledger.applyingSharedPauses(to: imported, device: mac,
            maximumMinutes: [rule: 60], at: now.addingTimeInterval(140))[rule])
    }

    func testRemotePauseDoesNotUnlockIneligibleGroupOrReviveExpiredPause() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 10, pauseEndsIn: 600))
        XCTAssertTrue(ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [:], at: now).isEmpty)
        XCTAssertTrue(ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 5], at: now).isEmpty)
        XCTAssertTrue(ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], at: now.addingTimeInterval(601)).isEmpty)
    }

    func testOfflineOldGrantCannotUndoNewerCancellationAfterMerge() {
        var offline = TemporaryAccessLedger()
        offline.record(contribution(device: mac, minutes: 10, pauseEndsIn: 600))
        var current = TemporaryAccessLedger()
        var cancelled = contribution(device: phone, minutes: 0, pauseEndsIn: -1)
        cancelled.updatedAt = now.addingTimeInterval(10)
        current.record(cancelled)
        current.merge(offline, at: now.addingTimeInterval(20))
        XCTAssertTrue(current.applyingSharedPauses(to: [:], device: mac,
            maximumMinutes: [rule: 60], at: now.addingTimeInterval(20)).isEmpty)
        XCTAssertEqual(current.additionalCommittedMinutes(forRule: rule, localMinutes: 0, at: now), 0)
    }

    private let rule = UUID()
    private let mac = UUID()
    private let phone = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func contribution(
        device: UUID,
        rule: UUID? = nil,
        minutes: Int,
        pauseEndsIn seconds: TimeInterval,
        grants: Int = 1,
        backoffStartedAgo: TimeInterval = 0,
        updatedAgo: TimeInterval = 0
    ) -> TemporaryAccessContribution {
        TemporaryAccessContribution(
            deviceID: device,
            ruleID: rule ?? self.rule,
            minutesGranted: minutes,
            pauseEndsAt: now.addingTimeInterval(seconds),
            backoffGrants: grants,
            backoffStartedAt: now.addingTimeInterval(-backoffStartedAgo),
            updatedAt: now.addingTimeInterval(-updatedAgo)
        )
    }

    // MARK: - Spend

    /// The loophole this closes: a budget spent on one device has to count
    /// against the same budget on another.
    func testAnotherDevicesLivePauseCountsAgainstTheBudget() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 300))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 5)
    }

    /// A device never counts its own published entry: it already tracks that
    /// spend locally, and counting both would double it.
    func testADeviceDoesNotCountItsOwnContribution() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 300))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: mac, at: now), 0)
    }

    /// Spend stops counting when the pause ends, mirroring the local rule that
    /// a session resets once the allowance expires.
    func testExpiredPausesStopCountingAgainstTheBudget() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 60, pauseEndsIn: -1))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 0)
    }

    func testSpendFromSeveralDevicesAddsUp() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 300))
        ledger.record(contribution(device: UUID(), minutes: 10, pauseEndsIn: 600))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 15)
    }

    func testSpendIsScopedToItsOwnRule() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, rule: UUID(), minutes: 30, pauseEndsIn: 600))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 0)
    }

    /// Cancelling a pause early must stop its minutes counting against the
    /// other devices, while the passage it cost is still counted.
    func testReleasingAPauseFreesTheMinutesButKeepsTheGrant() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 30, pauseEndsIn: 1_800, grants: 2))
        ledger.record(TemporaryAccessContribution(
            deviceID: mac, ruleID: rule, minutesGranted: 0, pauseEndsAt: .distantPast,
            backoffGrants: 2, backoffStartedAt: now, updatedAt: now
        ))

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 0)
        XCTAssertEqual(ledger.backoffGrants(forRule: rule, excluding: phone, resetDays: 2, at: now), 2)
    }

    // MARK: - Escalation

    func testBackoffGrantsFromOtherDevicesAddUpInsideTheWindow() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 0, pauseEndsIn: -1, grants: 3))

        XCTAssertEqual(ledger.backoffGrants(forRule: rule, excluding: phone, resetDays: 2, at: now), 3)
    }

    /// The window is the rule's own reset interval, so an old grant stops
    /// making today's passage longer.
    func testBackoffGrantsFallOutOfTheWindow() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(
            device: mac, minutes: 0, pauseEndsIn: -1, grants: 3, backoffStartedAgo: 3 * 86_400
        ))

        XCTAssertEqual(ledger.backoffGrants(forRule: rule, excluding: phone, resetDays: 2, at: now), 0)
        XCTAssertEqual(ledger.backoffGrants(forRule: rule, excluding: phone, resetDays: 30, at: now), 3)
    }

    // MARK: - Merge

    /// A device offline for a week must not erase what the others recorded
    /// while it was away.
    func testMergeNeverDropsAnEntryMissingFromTheIncomingCopy() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 600))

        ledger.merge(TemporaryAccessLedger(), at: now)

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 5)
    }

    func testMergeKeepsTheLaterWritePerDevice() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 600, updatedAgo: 60))

        var incoming = TemporaryAccessLedger()
        incoming.record(contribution(device: mac, minutes: 20, pauseEndsIn: 600))
        ledger.merge(incoming, at: now)
        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 20)

        var stale = TemporaryAccessLedger()
        stale.record(contribution(device: mac, minutes: 1, pauseEndsIn: 600, updatedAgo: 600))
        ledger.merge(stale, at: now)
        XCTAssertEqual(
            ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 20,
            "An older write must not overwrite a newer one"
        )
    }

    /// Two devices pausing at once must not lose each other's spend, which is
    /// the reason each writes only its own entry.
    func testConcurrentDevicesBothSurviveAMerge() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 600))
        var incoming = TemporaryAccessLedger()
        incoming.record(contribution(device: phone, minutes: 10, pauseEndsIn: 600))

        ledger.merge(incoming, at: now)

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: UUID(), at: now), 15)
    }

    /// A hand-edited record whose key does not match its contents is ignored,
    /// so one cannot be planted under another device's name.
    func testMergeRejectsAMiskeyedEntry() {
        var ledger = TemporaryAccessLedger()
        var incoming = TemporaryAccessLedger()
        incoming.contributions["not-the-right-key"] = contribution(device: mac, minutes: 500, pauseEndsIn: 600)

        ledger.merge(incoming, at: now)

        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 0)
    }

    func testPruningKeepsAnythingStillCapableOfCounting() {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 600, backoffStartedAgo: 400 * 86_400))
        ledger.record(contribution(device: phone, minutes: 5, pauseEndsIn: -1, backoffStartedAgo: 400 * 86_400))

        ledger.prune(at: now)

        XCTAssertEqual(ledger.contributions.count, 1, "A live pause is kept; a fully lapsed entry is dropped")
        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now), 5)
    }

    func testLedgerSurvivesARoundTrip() throws {
        var ledger = TemporaryAccessLedger()
        ledger.record(contribution(device: mac, minutes: 5, pauseEndsIn: 600, grants: 2))

        let decoded = try JSONDecoder().decode(
            TemporaryAccessLedger.self, from: try JSONEncoder().encode(ledger)
        )

        XCTAssertEqual(decoded, ledger)
    }
}

/// End-to-end through the store, with a fake transport standing in for iCloud.
final class ICloudTemporaryAccessStoreTests: XCTestCase {
    private final class FakeCloud: LockdownCloudTransport {
        var storage: [String: Any] = [:]
        var synchronizeCount = 0
        var values: [String: Any] { storage }
        func set(_ data: Data, forKey key: String) { storage[key] = data }
        func remove(_ key: String) { storage[key] = nil }
        func synchronize() { synchronizeCount += 1 }
    }

    private let rule = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeviceIdentityIsMintedOnceAndReused() {
        let ledger = InMemoryKeyValueLedger()
        let first = ICloudTemporaryAccessStore(ledger: ledger, cloud: FakeCloud()).deviceID
        let second = ICloudTemporaryAccessStore(ledger: ledger, cloud: FakeCloud()).deviceID

        XCTAssertEqual(first, second)
    }

    /// The point of the whole feature: spend recorded on one device is visible
    /// to the other, so a budget cannot be spent twice.
    func testSpendRecordedOnOneDeviceReachesTheOther() {
        let cloud = FakeCloud()
        let mac = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        let phone = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)

        mac.record(
            rule: rule, minutesGranted: 5, pauseEndsAt: now.addingTimeInterval(300),
            backoffGrants: 1, backoffStartedAt: now, at: now
        )
        let seen = phone.reconcile(at: now)

        XCTAssertEqual(seen.committedMinutes(forRule: rule, excluding: phone.deviceID, at: now), 5)
        XCTAssertEqual(seen.backoffGrants(forRule: rule, excluding: phone.deviceID, resetDays: 2, at: now), 1)
    }

    /// Two devices writing at once must both survive, which is why each owns
    /// its own key.
    func testConcurrentWritesFromTwoDevicesBothSurvive() {
        let cloud = FakeCloud()
        let mac = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        let phone = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)

        mac.record(rule: rule, minutesGranted: 5, pauseEndsAt: now.addingTimeInterval(300),
                   backoffGrants: 1, backoffStartedAt: now, at: now)
        phone.record(rule: rule, minutesGranted: 10, pauseEndsAt: now.addingTimeInterval(300),
                     backoffGrants: 1, backoffStartedAt: now, at: now)

        let merged = mac.reconcile(at: now)
        XCTAssertEqual(merged.committedMinutes(forRule: rule, excluding: UUID(), at: now), 15)
    }

    /// An unreachable or empty cloud must not forget what this device already
    /// knew; the local replica is the offline outbox.
    func testAnEmptyCloudDoesNotEraseTheLocalReplica() {
        let ledger = InMemoryKeyValueLedger()
        let store = ICloudTemporaryAccessStore(ledger: ledger, cloud: FakeCloud())
        store.record(rule: rule, minutesGranted: 5, pauseEndsAt: now.addingTimeInterval(300),
                     backoffGrants: 1, backoffStartedAt: now, at: now)

        // A different transport stands in for iCloud being unreachable.
        let offline = ICloudTemporaryAccessStore(ledger: ledger, cloud: FakeCloud())
        let replica = offline.reconcile(at: now)

        XCTAssertEqual(replica.committedMinutes(forRule: rule, excluding: UUID(), at: now), 5)
    }

    func testReleasingAPauseIsPublished() {
        let cloud = FakeCloud()
        let mac = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        let phone = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        mac.record(rule: rule, minutesGranted: 30, pauseEndsAt: now.addingTimeInterval(1_800),
                   backoffGrants: 2, backoffStartedAt: now, at: now)

        mac.releasePause(rule: rule, backoffGrants: 2, backoffStartedAt: now, at: now)
        let seen = phone.reconcile(at: now)

        XCTAssertEqual(seen.committedMinutes(forRule: rule, excluding: phone.deviceID, at: now), 0)
        XCTAssertEqual(seen.backoffGrants(forRule: rule, excluding: phone.deviceID, resetDays: 2, at: now), 2)
    }

    /// A record whose key does not match its contents is ignored, so one
    /// cannot be planted under another device's name.
    func testMiskeyedCloudRecordsAreIgnored() throws {
        let cloud = FakeCloud()
        let store = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        let forged = TemporaryAccessContribution(
            deviceID: UUID(), ruleID: rule, minutesGranted: 999,
            pauseEndsAt: now.addingTimeInterval(9_999),
            backoffGrants: 9, backoffStartedAt: now, updatedAt: now
        )
        cloud.storage[ICloudTemporaryAccessStore.contributionPrefix + "wrong-key"] =
            try JSONEncoder().encode(forged)

        let replica = store.reconcile(at: now)

        XCTAssertEqual(replica.committedMinutes(forRule: rule, excluding: store.deviceID, at: now), 0)
    }
}
