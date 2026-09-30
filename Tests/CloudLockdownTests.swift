import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class CloudLockdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private final class Transport: LockdownCloudTransport {
        var values: [String: Any] = [:]
        var writes = 0
        func set(_ data: Data, forKey key: String) { values[key] = data; writes += 1 }
        func remove(_ key: String) { values.removeValue(forKey: key) }
        func synchronize() {}
    }
    private func defaults() -> UserDefaults {
        let name = "lockdown-sync-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
    private func session() -> CloudLockdownSession {
        CloudLockdownSession(id: UUID(), rules: [CloudRulePreference(name: "News", domains: [
            CloudDomainPreference(domain: "example.com", category: "other", source: "user")
        ])], startedAt: now, endsAt: now.addingTimeInterval(3_600),
           exitPolicy: CloudLockdownExitPolicy(severity: "repeatedConfirmations", unlockDelayDays: 3, passageWordCount: 80),
           earlyExitPassage: "saved passage")
    }

    func testSecondDeviceReceivesIdenticalTargetsDeadlineAndExitPolicy() throws {
        let cloud = Transport()
        let first = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        let second = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        let session = session()
        try first.reconcile(localSessions: [session], at: now)
        XCTAssertEqual(try second.reconcile(localSessions: [], at: now).active(at: now), [session])
    }

    func testConcurrentOfflineStartsAreAdditiveAfterDelivery() throws {
        let cloudA = Transport(), cloudB = Transport()
        let a = ICloudLockdownStore(defaults: defaults(), cloud: cloudA)
        let b = ICloudLockdownStore(defaults: defaults(), cloud: cloudB)
        let first = session(), second = session()
        try a.reconcile(localSessions: [first], at: now)
        try b.reconcile(localSessions: [second], at: now)
        let delivered = cloudA.values.merging(cloudB.values) { first, _ in first }
        cloudA.values = delivered; cloudB.values = delivered
        XCTAssertEqual(Set(try a.reconcile(localSessions: [], at: now).active(at: now).map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(try b.reconcile(localSessions: [], at: now).active(at: now).map(\.id)), [first.id, second.id])
    }

    func testEmptyCloudAndAppRestartDoNotEndLocalCommitment() throws {
        let cloud = Transport(), disk = defaults(), held = session()
        try ICloudLockdownStore(defaults: disk, cloud: cloud).reconcile(localSessions: [held], at: now)
        cloud.values = [:]
        let restarted = ICloudLockdownStore(defaults: disk, cloud: cloud)
        XCTAssertEqual(try restarted.reconcile(localSessions: [], at: now).active(at: now), [held])
    }

    func testCancellationArrivingBeforeSessionPreventsResurrection() throws {
        let cloud = Transport(), held = session()
        let a = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try a.recordAuthorizedCancellation(id: held.id, endsAt: held.endsAt)
        try a.reconcile(localSessions: [], at: now)
        let b = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        XCTAssertTrue(try b.reconcile(localSessions: [held], at: now).active(at: now).isEmpty)
        XCTAssertTrue(try a.reconcile(localSessions: [held], at: now).active(at: now).isEmpty)
    }

    func testCancellationReleasesOnlySelectedSession() throws {
        let cloud = Transport()
        let first = session(), second = session()
        // A new receiving replica must not require the origin's local state.
        let origin = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try origin.reconcile(localSessions: [first, second], at: now)
        try origin.recordAuthorizedCancellation(id: first.id, endsAt: first.endsAt)
        try origin.reconcile(localSessions: [second], at: now)
        let receiver = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        XCTAssertEqual(try receiver.reconcile(localSessions: [], at: now).active(at: now), [second])
    }

    func testStaleOfflineDeviceCannotUndoDeliveredCancellation() throws {
        let cloud = Transport(), stale = Transport(), held = session()
        let origin = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try origin.reconcile(localSessions: [held], at: now)
        stale.values = cloud.values
        let offline = ICloudLockdownStore(defaults: defaults(), cloud: stale)
        try offline.reconcile(localSessions: [], at: now)
        try origin.recordAuthorizedCancellation(id: held.id, endsAt: held.endsAt)
        try origin.reconcile(localSessions: [], at: now)
        cloud.values.merge(stale.values) { current, _ in current }
        stale.values = cloud.values
        XCTAssertTrue(try offline.reconcile(localSessions: [held], at: now).active(at: now).isEmpty)
    }

    func testLegacyPreferencesWriteDoesNotRemoveSessionKeys() throws {
        let cloud = Transport(), held = session()
        let origin = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try origin.reconcile(localSessions: [held], at: now)
        cloud.values[ICloudPreferencesStore.documentKey] = try JSONEncoder().encode(CloudPreferencesDocument())
        XCTAssertEqual(try origin.reconcile(localSessions: [], at: now).active(at: now), [held])
    }

    func testRepeatedReconcileDoesNotWriteOrGenerateNotificationLoop() throws {
        let cloud = Transport(), held = session()
        let store = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try store.reconcile(localSessions: [held], at: now)
        let writes = cloud.writes
        for _ in 0..<10 { try store.reconcile(localSessions: [held], at: now) }
        XCTAssertEqual(cloud.writes, writes)
    }

    func testExpiredSessionCannotBeReimportedAndTombstoneIsEventuallyPruned() throws {
        let cloud = Transport(), held = session()
        let store = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try store.reconcile(localSessions: [held], at: now)
        try store.recordAuthorizedCancellation(id: held.id, endsAt: held.endsAt)
        XCTAssertTrue(try store.reconcile(localSessions: [held], at: held.endsAt).active(at: held.endsAt).isEmpty)
        let later = held.endsAt.addingTimeInterval(86_401)
        let replica = try store.reconcile(localSessions: [held], at: later)
        XCTAssertTrue(replica.sessions.isEmpty)
        XCTAssertTrue(replica.cancellations.isEmpty)
        XCTAssertTrue(cloud.values.isEmpty)
    }

    func testQuotaRetainsOutboxAndStillAppliesReceivedCommitment() throws {
        let cloud = Transport(), held = session()
        cloud.values["other-large-document"] = Data(repeating: 0, count: 1_000_000)
        let store = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        XCTAssertEqual(try store.reconcile(localSessions: [held], at: now).active(at: now), [held])
        XCTAssertNotNil(store.pendingMessage)
        XCTAssertEqual(try store.load().active(at: now), [held])
        cloud.values = [:]
        try store.reconcile(localSessions: [], at: now)
        XCTAssertNil(store.pendingMessage)
        XCTAssertNotNil(cloud.values[ICloudLockdownStore.sessionPrefix + held.id.uuidString])
    }

    func testSnapshotCannotBeReplacedByLaterLocalRuleProjection() throws {
        let cloud = Transport(), held = session()
        let store = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        try store.reconcile(localSessions: [held], at: now)
        var edited = held
        edited.rules = []; edited.endsAt = now.addingTimeInterval(1)
        XCTAssertEqual(try store.reconcile(localSessions: [edited], at: now).active(at: now), [held])
    }

    func testExpiredKeysArePrunedBeforeQuotaCheck() throws {
        let cloud = Transport(), held = session()
        for _ in 0..<1_000 {
            var expired = session()
            expired.endsAt = now
            cloud.values[ICloudLockdownStore.sessionPrefix + expired.id.uuidString] = try JSONEncoder().encode(expired)
        }
        let store = ICloudLockdownStore(defaults: defaults(), cloud: cloud)
        XCTAssertEqual(try store.reconcile(localSessions: [held], at: now).active(at: now), [held])
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(cloud.values.count, 1)
    }
}
