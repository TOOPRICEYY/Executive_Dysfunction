import Foundation

/// Portable intent only. Screen Time tokens and live enforcement state never
/// leave their device. Session keys are immutable; cancellation has its own key
/// so an offline writer cannot resurrect a cancelled commitment.
struct CloudLockdownSession: Codable, Equatable, Identifiable {
    var id: UUID
    var rules: [CloudRulePreference]
    var startedAt: Date
    var endsAt: Date
    var exitPolicy: CloudLockdownExitPolicy
    var earlyExitPassage: String

    var ruleIDs: Set<UUID> { Set(rules.map(\.id)) }
}

struct CloudLockdownCancellation: Codable, Equatable {
    var sessionID: UUID
    var endsAt: Date
}

struct CloudLockdownReplica: Codable, Equatable {
    var sessions: [UUID: CloudLockdownSession] = [:]
    var cancellations: [UUID: CloudLockdownCancellation] = [:]

    mutating func merge(_ incoming: Self, at now: Date) {
        // Absence is never deletion. Only an explicit, passage-authorized
        // cancellation or the original deadline releases a session.
        for (id, session) in incoming.sessions where sessions[id] == nil {
            sessions[id] = session
        }
        for (id, cancellation) in incoming.cancellations {
            if cancellation.endsAt > (cancellations[id]?.endsAt ?? .distantPast) {
                cancellations[id] = cancellation
            }
        }
        sessions = sessions.filter { $0.value.endsAt > now }
        cancellations = cancellations.filter { $0.value.endsAt.addingTimeInterval(86_400) > now }
    }

    func active(at now: Date) -> [CloudLockdownSession] {
        sessions.values.filter { $0.endsAt > now && cancellations[$0.id] == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

protocol LockdownCloudTransport {
    var values: [String: Any] { get }
    func set(_ data: Data, forKey key: String)
    func remove(_ key: String)
    func synchronize()
}

private struct UbiquitousLockdownTransport: LockdownCloudTransport {
    let store = NSUbiquitousKeyValueStore.default
    var values: [String: Any] { store.dictionaryRepresentation }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func remove(_ key: String) { store.removeObject(forKey: key) }
    func synchronize() { store.synchronize() }
}

/// Independent keys avoid lost concurrent starts and remain intact when an
/// older Holdfast writes its preferences document. A durable local replica is
/// also the offline outbox; merging an empty cloud never clears it.
final class ICloudLockdownStore {
    static let sessionPrefix = "holdfast.lockdown.session.v1."
    static let cancellationPrefix = "holdfast.lockdown.cancel.v1."
    private static let cacheKey = "lockdown.cloud-replica.v1"
    private let cloud: any LockdownCloudTransport
    private let defaults: UserDefaults
    private(set) var pendingMessage: String?

    init(defaults: UserDefaults = .standard, cloud: (any LockdownCloudTransport)? = nil) {
        self.defaults = defaults
        self.cloud = cloud ?? UbiquitousLockdownTransport()
    }

    func load() throws -> CloudLockdownReplica {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return CloudLockdownReplica() }
        return try JSONDecoder().decode(CloudLockdownReplica.self, from: data)
    }

    @discardableResult
    func reconcile(localSessions: [CloudLockdownSession], at now: Date = Date()) throws -> CloudLockdownReplica {
        cloud.synchronize()
        var replica = try load()
        var remote = CloudLockdownReplica()
        for (key, value) in cloud.values {
            guard let data = value as? Data else { continue }
            if key.hasPrefix(Self.sessionPrefix) {
                let session = try JSONDecoder().decode(CloudLockdownSession.self, from: data)
                guard key == Self.sessionPrefix + session.id.uuidString else { continue }
                remote.sessions[session.id] = session
            } else if key.hasPrefix(Self.cancellationPrefix) {
                let cancellation = try JSONDecoder().decode(CloudLockdownCancellation.self, from: data)
                guard key == Self.cancellationPrefix + cancellation.sessionID.uuidString else { continue }
                remote.cancellations[cancellation.sessionID] = cancellation
            }
        }
        replica.merge(remote, at: now)
        // Import pre-sync local sessions once, preserving their original IDs,
        // targets, deadline and exit requirements.
        for session in localSessions where replica.sessions[session.id] == nil && session.endsAt > now {
            replica.sessions[session.id] = session
        }
        try persist(replica)
        pendingMessage = nil
        do { try flush(replica, at: now) }
        catch { pendingMessage = error.localizedDescription }
        return replica
    }

    /// Call ONLY after the originating platform has completed its saved exit
    /// policy. Receivers apply this explicit event, never a missing session.
    func recordAuthorizedCancellation(id: UUID, endsAt: Date) throws {
        var replica = try load()
        replica.cancellations[id] = CloudLockdownCancellation(sessionID: id, endsAt: endsAt)
        try persist(replica)
    }

    private func persist(_ replica: CloudLockdownReplica) throws {
        defaults.set(try JSONEncoder().encode(replica), forKey: Self.cacheKey)
    }

    private func flush(_ replica: CloudLockdownReplica, at now: Date) throws {
        var payload: [String: Data] = [:]
        for session in replica.sessions.values {
            payload[Self.sessionPrefix + session.id.uuidString] = try JSONEncoder().encode(session)
        }
        for cancellation in replica.cancellations.values {
            payload[Self.cancellationPrefix + cancellation.sessionID.uuidString] = try JSONEncoder().encode(cancellation)
        }
        // Prune only verifiably expired records before checking quota. A full
        // store must be able to recover as old sessions expire.
        for (key, value) in cloud.values where payload[key] == nil {
            guard let data = value as? Data else { continue }
            if key.hasPrefix(Self.sessionPrefix),
               let session = try? JSONDecoder().decode(CloudLockdownSession.self, from: data), session.endsAt <= now {
                cloud.remove(key)
            } else if key.hasPrefix(Self.cancellationPrefix),
                      let cancellation = try? JSONDecoder().decode(CloudLockdownCancellation.self, from: data),
                      cancellation.endsAt.addingTimeInterval(86_400) <= now { cloud.remove(key) }
        }
        let existing = cloud.values
        // Leave the bulk of KVS capacity for preferences. Never silently omit
        // a session: retain it in the outbox and report the quota problem.
        let otherBytes = existing.filter { !$0.key.hasPrefix(Self.sessionPrefix) && !$0.key.hasPrefix(Self.cancellationPrefix) }
            .reduce(0) { $0 + (($1.value as? Data)?.count ?? 0) }
        let payloadBytes = payload.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
        guard payloadBytes <= 100_000, otherBytes + payloadBytes <= 1_000_000,
              existing.count + payload.keys.filter({ existing[$0] == nil }).count < 1_000 else {
            throw NSError(domain: "Holdfast.LockdownSync", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "iCloud storage is full. Lockdown changes are saved here and queued; other devices may not have received them."])
        }
        for (key, data) in payload {
            // Immutable session values are written once, not re-encoded on
            // every notification (Set encoding order is not deterministic).
            if existing[key] == nil { cloud.set(data, forKey: key) }
            else if key.hasPrefix(Self.cancellationPrefix),
                    let old = existing[key] as? Data,
                    let previous = try? JSONDecoder().decode(CloudLockdownCancellation.self, from: old),
                    let next = try? JSONDecoder().decode(CloudLockdownCancellation.self, from: data),
                    next.endsAt > previous.endsAt { cloud.set(data, forKey: key) }
        }
        cloud.synchronize()
    }
}
