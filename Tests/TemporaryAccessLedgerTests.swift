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

    // MARK: - Access delay

    /// How a pending grant travels: an older reader sees an expired pause (so
    /// it opens nothing) while a current reader gets the real window.
    private func pendingContribution(opensIn: TimeInterval, lasts: TimeInterval, minutes: Int) -> TemporaryAccessContribution {
        var entry = contribution(device: mac, minutes: minutes, pauseEndsIn: 0)
        entry.pauseOpensAt = now.addingTimeInterval(opensIn)
        entry.pendingPauseEndsAt = now.addingTimeInterval(opensIn + lasts)
        return entry
    }

    func testPendingRecordLooksLikeNoPauseToAnOlderReader() throws {
        let entry = pendingContribution(opensIn: 600, lasts: 1_800, minutes: 30)
        XCTAssertLessThanOrEqual(entry.pauseEndsAt, now, "An older build opens only while pauseEndsAt > now")
        // Decode with only the keys an older build knows.
        struct OldContribution: Decodable { var minutesGranted: Int; var pauseEndsAt: Date; var updatedAt: Date }
        let old = try JSONDecoder().decode(OldContribution.self, from: JSONEncoder().encode(entry))
        let oldExpiry = min(old.pauseEndsAt, old.updatedAt.addingTimeInterval(60 * 60))
        XCTAssertFalse(oldExpiry > now, "The older reader's own open test fails, so it stays blocked")
    }

    func testPendingRecordOpensOnAnotherCurrentDeviceAtItsOpeningOnly() throws {
        var ledger = TemporaryAccessLedger()
        ledger.record(pendingContribution(opensIn: 600, lasts: 1_800, minutes: 30))
        let imported = try XCTUnwrap(ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 10], at: now.addingTimeInterval(60))[rule])
        XCTAssertEqual(imported.opensAt, now.addingTimeInterval(600))
        XCTAssertEqual(imported.expiresAt, now.addingTimeInterval(2_400), "The wait does not shorten it")
        XCTAssertTrue(imported.isPending(at: now.addingTimeInterval(599)))
        XCTAssertFalse(imported.isOpen(at: now.addingTimeInterval(599)))
        XCTAssertTrue(imported.isOpen(at: now.addingTimeInterval(600)))
        XCTAssertFalse(imported.isOpen(at: now.addingTimeInterval(2_400)))
        // Its spend counts against the other devices while pending.
        XCTAssertEqual(ledger.additionalCommittedMinutes(forRule: rule, localMinutes: 0, at: now.addingTimeInterval(60)), 30)
        XCTAssertEqual(ledger.committedMinutes(forRule: rule, excluding: phone, at: now.addingTimeInterval(60)), 30)
        XCTAssertTrue(ledger.ownEntryIsLatestPending(rule: rule, device: mac))
        XCTAssertFalse(ledger.ownEntryIsLatestPending(rule: rule, device: phone))
    }

    func testReceiverNeverOpensSoonerThanItsOwnWait() throws {
        var ledger = TemporaryAccessLedger()
        // A record claiming an opening after only one minute.
        ledger.record(pendingContribution(opensIn: 60, lasts: 3_600, minutes: 60))
        let imported = try XCTUnwrap(ledger.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 30], at: now)[rule])
        XCTAssertEqual(imported.opensAt, now.addingTimeInterval(30 * 60), "Opens late, never early")
        XCTAssertEqual(imported.expiresAt, now.addingTimeInterval(3_660), "The end is not pushed later")
        // If its window ends before this device's own wait is over, it never opens here.
        var short = TemporaryAccessLedger()
        short.record(pendingContribution(opensIn: 60, lasts: 600, minutes: 10))
        XCTAssertNil(short.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 30], at: now)[rule])
        // An opening more than a day after the grant is not believed.
        var forged = TemporaryAccessLedger()
        forged.record(pendingContribution(opensIn: 2 * 86_400, lasts: 600, minutes: 10))
        XCTAssertNil(forged.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [:], at: now)[rule])
    }

    /// Without `pendingGrantedAt` (an older writer) the write time is the
    /// origin, as before; a claimed origin can never reach further back than
    /// the longest wait before the opening.
    func testPendingOriginFallsBackToTheWriteAndIsBounded() throws {
        var legacy = TemporaryAccessLedger()
        var entry = pendingContribution(opensIn: 3_000, lasts: 3_600, minutes: 60)
        entry.updatedAt = now.addingTimeInterval(600)
        legacy.record(entry)
        let fromWrite = try XCTUnwrap(legacy.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 60], at: now.addingTimeInterval(600))[rule])
        XCTAssertEqual(fromWrite.opensAt, now.addingTimeInterval(4_200), "Measured from the write, conservatively")

        var forged = TemporaryAccessLedger()
        entry.pendingGrantedAt = now.addingTimeInterval(-10 * 86_400)
        forged.record(entry)
        let opening = now.addingTimeInterval(3_000)
        XCTAssertEqual(TemporaryAccessLedger.pendingGrantOrigin(of: entry, opening: opening),
                       opening.addingTimeInterval(-86_401))
        let bounded = try XCTUnwrap(forged.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 1_440], at: now.addingTimeInterval(600))[rule])
        XCTAssertEqual(bounded.opensAt, opening, "Never before the writer's own opening")

        // A fractional origin rounds the receiver's floor up to a whole second.
        var fractional = TemporaryAccessLedger()
        var late = pendingContribution(opensIn: 60, lasts: 3_600, minutes: 60)
        late.pendingGrantedAt = now.addingTimeInterval(0.4)
        fractional.record(late)
        let rounded = try XCTUnwrap(fractional.applyingSharedPauses(to: [:], device: phone,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 30], at: now)[rule])
        XCTAssertEqual(rounded.opensAt, now.addingTimeInterval(1_801))
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

    // MARK: - Pending grant origin

    private func pending(opensIn: TimeInterval, endsIn: TimeInterval, minutes: Int, grants: Int) -> RuleTimeAllowance {
        RuleTimeAllowance(ruleID: rule, expiresAt: now.addingTimeInterval(endsIn), totalMinutesGranted: minutes,
                          grantCount: grants, restoreUsageShield: false, opensAt: now.addingTimeInterval(opensIn))
    }

    /// A 60-minute wait granted at 12:00 opens at 13:00. Extended at 12:10, it
    /// must still open at 13:00 on another device with the same wait, not 13:10.
    func testExtendingAPendingGrantKeepsTheReceiversOpening() throws {
        let cloud = FakeCloud()
        let mac = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        let phone = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        mac.record(rule: rule, allowance: pending(opensIn: 3_600, endsIn: 5_400, minutes: 30, grants: 1),
                   backoffGrants: 1, backoffStartedAt: now, at: now)
        let extendedAt = now.addingTimeInterval(600)
        mac.record(rule: rule, allowance: pending(opensIn: 3_600, endsIn: 6_000, minutes: 40, grants: 2),
                   backoffGrants: 2, backoffStartedAt: now, at: extendedAt)
        let seen = phone.reconcile(at: extendedAt)
        let entry = try XCTUnwrap(seen.contributions[TemporaryAccessLedger.key(rule: rule, device: mac.deviceID)])
        XCTAssertEqual(entry.updatedAt, extendedAt)
        XCTAssertEqual(entry.pendingGrantedAt, now, "The extension keeps the grant's origin")
        XCTAssertLessThanOrEqual(entry.pauseEndsAt, extendedAt, "Older readers still see no pause")
        let imported = try XCTUnwrap(seen.applyingSharedPauses(to: [:], device: phone.deviceID,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 60], at: extendedAt)[rule])
        XCTAssertEqual(imported.opensAt, now.addingTimeInterval(3_600), "Same opening as the granting device")
        XCTAssertEqual(imported.expiresAt, now.addingTimeInterval(6_000))
        // A receiver with a longer wait still waits its own full wait from the grant.
        let stricter = try XCTUnwrap(seen.applyingSharedPauses(to: [:], device: phone.deviceID,
            maximumMinutes: [rule: 60], waitMinutes: [rule: 90], at: extendedAt)[rule])
        XCTAssertEqual(stricter.opensAt, now.addingTimeInterval(5_400))
    }

    /// A new grant after the previous one ended, or after a cancellation,
    /// starts a fresh origin and so a fresh wait on the receiver.
    func testANewGrantGetsAFreshOrigin() throws {
        let cloud = FakeCloud()
        let mac = ICloudTemporaryAccessStore(ledger: InMemoryKeyValueLedger(), cloud: cloud)
        mac.record(rule: rule, allowance: pending(opensIn: 600, endsIn: 1_200, minutes: 10, grants: 1),
                   backoffGrants: 1, backoffStartedAt: now, at: now)
        // The first ended at +1200; a new one is granted at +1500.
        let later = now.addingTimeInterval(1_500)
        mac.record(rule: rule, allowance: pending(opensIn: 2_100, endsIn: 2_700, minutes: 10, grants: 1),
                   backoffGrants: 2, backoffStartedAt: now, at: later)
        let key = TemporaryAccessLedger.key(rule: rule, device: mac.deviceID)
        XCTAssertEqual(mac.load().contributions[key]?.pendingGrantedAt, later)
        // Cancelled, then granted again with an opening that happens to match.
        mac.releasePause(rule: rule, backoffGrants: 2, backoffStartedAt: now, at: later.addingTimeInterval(1))
        let again = later.addingTimeInterval(2)
        mac.record(rule: rule, allowance: pending(opensIn: 2_100, endsIn: 2_700, minutes: 10, grants: 1),
                   backoffGrants: 3, backoffStartedAt: now, at: again)
        XCTAssertEqual(mac.load().contributions[key]?.pendingGrantedAt, again)
        // An opened grant carries no origin at all.
        mac.record(rule: rule, allowance: pending(opensIn: 2_100, endsIn: 2_700, minutes: 10, grants: 1),
                   backoffGrants: 3, backoffStartedAt: now, at: now.addingTimeInterval(2_200))
        XCTAssertNil(mac.load().contributions[key]?.pendingGrantedAt)
    }
}
