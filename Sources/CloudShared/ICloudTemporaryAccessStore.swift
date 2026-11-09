import Foundation

/// Replicates temporary-access spend between a person's devices.
///
/// Modelled on `ICloudLockdownStore`: one key per record so concurrent writers
/// cannot clobber each other, a durable local replica that doubles as the
/// offline outbox, and a quota guard that reports rather than silently dropping
/// records.
///
/// Carries pause authorization and cancellation as well as their cost. An
/// offline device uses its last received expiry until iCloud catches up.
final class ICloudTemporaryAccessStore {
    static let contributionPrefix = "holdfast.temporary-access.spend.v1."
    private static let cacheKey = "temporary-access.cloud-replica.v1"
    private static let deviceKey = "temporary-access.device-id.v1"

    private let cloud: any LockdownCloudTransport
    private let ledger: any KeyValueLedger
    private(set) var pendingMessage: String?

    init(ledger: any KeyValueLedger, cloud: (any LockdownCloudTransport)? = nil) {
        self.ledger = ledger
        self.cloud = cloud ?? UbiquitousTemporaryAccessTransport()
    }

    /// A stable identity for this installation, minted once. It is an opaque
    /// UUID: nothing about the device is published, only that its spend is
    /// distinct from the other devices'.
    lazy var deviceID: UUID = {
        if let data = ledger.data(forKey: Self.deviceKey),
           let stored = try? JSONDecoder().decode(UUID.self, from: data) {
            return stored
        }
        let minted = UUID()
        ledger.set(try? JSONEncoder().encode(minted), forKey: Self.deviceKey)
        return minted
    }()

    func load() -> TemporaryAccessLedger {
        guard let data = ledger.data(forKey: Self.cacheKey),
              let replica = try? JSONDecoder().decode(TemporaryAccessLedger.self, from: data)
        else { return TemporaryAccessLedger() }
        return replica
    }

    /// Pulls what the other devices have published and pushes this device's
    /// own entries. Returns the merged view, which is what callers should ask
    /// about other devices' spend.
    @discardableResult
    func reconcile(at now: Date = Date()) -> TemporaryAccessLedger {
        cloud.synchronize()
        var replica = load()
        var remote = TemporaryAccessLedger()
        for (key, value) in cloud.values where key.hasPrefix(Self.contributionPrefix) {
            guard let data = value as? Data,
                  let entry = try? JSONDecoder().decode(TemporaryAccessContribution.self, from: data),
                  key == Self.contributionPrefix + TemporaryAccessLedger.key(
                      rule: entry.ruleID, device: entry.deviceID)
            else { continue }
            remote.contributions[TemporaryAccessLedger.key(rule: entry.ruleID, device: entry.deviceID)] = entry
        }
        replica.merge(remote, at: now)
        persist(replica)
        flush(replica, at: now)
        return replica
    }

    /// Publishes this device's spend for one rule.
    @discardableResult
    func record(
        rule: UUID,
        minutesGranted: Int,
        pauseEndsAt: Date,
        backoffGrants: Int,
        backoffStartedAt: Date,
        at now: Date = Date(),
        sessionGrantCount: Int? = nil
    ) -> TemporaryAccessLedger {
        var replica = load()
        replica.record(TemporaryAccessContribution(
            deviceID: deviceID,
            ruleID: rule,
            minutesGranted: minutesGranted,
            pauseEndsAt: pauseEndsAt,
            backoffGrants: backoffGrants,
            backoffStartedAt: backoffStartedAt,
            updatedAt: now,
            sessionGrantCount: sessionGrantCount
        ))
        persist(replica)
        flush(replica, at: now)
        return replica
    }

    /// Stops this device's minutes counting against the others, used when a
    /// pause is cancelled early. The backoff grant deliberately survives: the
    /// passage was still spent.
    @discardableResult
    func releasePause(rule: UUID, backoffGrants: Int, backoffStartedAt: Date, at now: Date = Date()) -> TemporaryAccessLedger {
        record(
            rule: rule,
            minutesGranted: 0,
            pauseEndsAt: .distantPast,
            backoffGrants: backoffGrants,
            backoffStartedAt: backoffStartedAt,
            at: now
        )
    }

    private func persist(_ replica: TemporaryAccessLedger) {
        ledger.set(try? JSONEncoder().encode(replica), forKey: Self.cacheKey)
    }

    private func flush(_ replica: TemporaryAccessLedger, at now: Date) {
        pendingMessage = nil
        var payload: [String: Data] = [:]
        for (key, entry) in replica.contributions {
            guard let data = try? JSONEncoder().encode(entry) else { continue }
            payload[Self.contributionPrefix + key] = data
        }

        // Remove only records this device can verify are spent, so a crowded
        // store recovers as entries age out.
        for (key, value) in cloud.values where key.hasPrefix(Self.contributionPrefix) && payload[key] == nil {
            guard let data = value as? Data,
                  let entry = try? JSONDecoder().decode(TemporaryAccessContribution.self, from: data)
            else { continue }
            let longestBackoff = Double(TemporaryAllowanceBackoff.daysRange.upperBound) * 86_400
            if entry.pauseEndsAt <= now,
               now >= entry.backoffStartedAt.addingTimeInterval(longestBackoff) {
                cloud.remove(key)
            }
        }

        let existing = cloud.values
        let otherBytes = existing
            .filter { !$0.key.hasPrefix(Self.contributionPrefix) }
            .reduce(0) { $0 + (($1.value as? Data)?.count ?? 0) }
        let payloadBytes = payload.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
        guard payloadBytes <= 100_000, otherBytes + payloadBytes <= 1_000_000,
              existing.count + payload.keys.filter({ existing[$0] == nil }).count < 1_000 else {
            // The local replica already holds everything; say so rather than
            // dropping a record and under-counting someone's spend.
            pendingMessage = "iCloud storage is full. Temporary-access history is saved here and queued; other devices may not have received it yet."
            return
        }

        for (key, data) in payload where (existing[key] as? Data) != data {
            cloud.set(data, forKey: key)
        }
        cloud.synchronize()
    }
}

private struct UbiquitousTemporaryAccessTransport: LockdownCloudTransport {
    let store = NSUbiquitousKeyValueStore.default
    var values: [String: Any] { store.dictionaryRepresentation }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func remove(_ key: String) { store.removeObject(forKey: key) }
    func synchronize() { store.synchronize() }
}
