import Foundation

/// A bounded bridge between a flow whose framework-provided hostname was
/// explicitly blocked and an immediate retry that reaches the same endpoint
/// without a hostname.
///
/// This is deliberately short-lived and policy-revision scoped. IP addresses
/// can be shared by unrelated CDN customers, so a correlation must never turn
/// into a permanent IP block. It also performs no DNS or Security work on the
/// Network Extension callback path.
final class BlockedEndpointCorrelationCache: @unchecked Sendable {
    private struct Key: Hashable {
        var address: String
        var port: Int
        var policyRevision: UInt64
    }

    private let lock = NSLock()
    private let timeToLive: TimeInterval
    private let capacity: Int
    private var expirations: [Key: Date] = [:]

    init(timeToLive: TimeInterval = 30, capacity: Int = 256) {
        self.timeToLive = max(1, timeToLive)
        self.capacity = max(1, capacity)
    }

    func record(
        address: String?,
        port: Int?,
        policyRevision: UInt64,
        at now: Date = Date()
    ) {
        guard let key = key(address: address, port: port, policyRevision: policyRevision) else { return }
        lock.lock()
        if expirations.count >= capacity, expirations[key] == nil,
           let oldest = expirations.min(by: { $0.value < $1.value })?.key {
            expirations.removeValue(forKey: oldest)
        }
        expirations[key] = now.addingTimeInterval(timeToLive)
        lock.unlock()
    }

    func contains(
        address: String?,
        port: Int?,
        policyRevision: UInt64,
        at now: Date = Date()
    ) -> Bool {
        guard let key = key(address: address, port: port, policyRevision: policyRevision) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let expiration = expirations[key] else { return false }
        guard expiration > now else {
            expirations.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Runtime policy exceptions keep the signed revision unchanged. Clear old
    /// endpoint correlations when the effective rule set changes so a retry is
    /// not still blocked by an address learned before the exception began.
    func removeAll() {
        lock.lock()
        expirations.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func key(address: String?, port: Int?, policyRevision: UInt64) -> Key? {
        guard var address = address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !address.isEmpty,
              let port,
              (1...65_535).contains(port) else { return nil }
        if address.hasPrefix("[") { address.removeFirst() }
        if address.hasSuffix("]") { address.removeLast() }
        if let zone = address.firstIndex(of: "%") {
            address = String(address[..<zone])
        }
        guard !address.isEmpty else { return nil }
        return Key(address: address, port: port, policyRevision: policyRevision)
    }
}
