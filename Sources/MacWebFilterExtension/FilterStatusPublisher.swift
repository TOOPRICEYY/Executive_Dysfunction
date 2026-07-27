import Foundation
import OSLog

/// Publishes what the filter is enforcing, so a wedged or stale policy is
/// visible instead of presenting as rules that quietly do nothing.
///
/// Writes happen on a utility queue and never on a flow callback: the flow path
/// must not touch the file system. A heartbeat is emitted even when nothing
/// changes, so the app can tell "enforcing an old revision" apart from "not
/// running at all".
final class FilterStatusPublisher: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.GabrielPrice.ExecutiveDysfunction.filter-status",
        qos: .utility
    )
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "status"
    )
    private let heartbeat: TimeInterval = 30

    private let lock = NSLock()
    private var lastRevision: UInt64?
    private var lastWrite = Date.distantPast
    private var isWriting = false

    func record(_ policy: DesktopEnforcementPolicy, now: Date = Date()) {
        lock.lock()
        let changed = policy.revision != lastRevision
        let due = now.timeIntervalSince(lastWrite) >= heartbeat
        guard !isWriting, changed || due else {
            lock.unlock()
            return
        }
        isWriting = true
        lastRevision = policy.revision
        lastWrite = now
        lock.unlock()

        queue.async { [self] in
            do {
                try FilterStatusStore.write(FilterEnforcementStatus(policy: policy, at: now))
            } catch {
                logger.error("Could not publish filter status: \(error.localizedDescription, privacy: .public)")
            }
            lock.lock()
            isWriting = false
            lock.unlock()
        }
    }
}
