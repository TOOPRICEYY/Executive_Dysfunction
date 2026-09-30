import Foundation
import OSLog

/// Publishes what the filter is enforcing, plus a redacted explanation of how
/// it has handled traffic during this provider process lifetime.
///
/// The old implementation called its writes a heartbeat, but `record` was only
/// reached from flow callbacks. A quiet, healthy provider therefore stopped
/// updating the file, looked dead after 120 seconds, and caused the app to try
/// policy repair. This publisher owns a real timer. Disk I/O and summary logs
/// stay on its utility queue and never run on a Network Extension flow callback.
final class FilterStatusPublisher: @unchecked Sendable {
    typealias SnapshotProvider = @Sendable (
        _ heartbeatSequence: UInt64,
        _ previousDiagnostics: WebFilterDiagnosticsSnapshot?,
        _ now: Date
    ) -> FilterEnforcementStatus

    private let queue = DispatchQueue(
        label: "com.GabrielPrice.ExecutiveDysfunction.filter-status",
        qos: .utility
    )
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "status"
    )
    private let heartbeat: TimeInterval
    private let writer: @Sendable (FilterEnforcementStatus) throws -> Void
    private let previousDiagnosticsReader: @Sendable () -> WebFilterDiagnosticsSnapshot?

    /// Generation/revision state is touched by flow callbacks. Everything that
    /// can write the status file is instead serialized on `queue`.
    private let stateLock = NSLock()
    private var activeGeneration: UInt64 = 0
    private var isRunning = false
    private var lastObservedRevision: UInt64?

    // Queue-confined state.
    private var timer: DispatchSourceTimer?
    private var snapshotProvider: SnapshotProvider?
    private var previousDiagnostics: WebFilterDiagnosticsSnapshot?
    private var heartbeatSequence: UInt64 = 0

    init(
        // Five seconds keeps a bounded smoke test observable. The old
        // 30-second cadence meant every 15-second outage report contained only
        // the empty provider-start snapshot, even when hundreds of flows had
        // already accumulated.
        heartbeat: TimeInterval = 5,
        writer: @escaping @Sendable (FilterEnforcementStatus) throws -> Void = { status in
            try FilterStatusStore.write(status)
        },
        previousDiagnosticsReader: @escaping @Sendable () -> WebFilterDiagnosticsSnapshot? = {
            FilterStatusStore.read()?.diagnostics
        }
    ) {
        self.heartbeat = heartbeat
        self.writer = writer
        self.previousDiagnosticsReader = previousDiagnosticsReader
    }

    /// Starts a genuine time-based heartbeat and publishes immediately.
    /// Calling this twice replaces the prior timer rather than creating two
    /// writers for one provider.
    func start(
        initialRevision: UInt64? = nil,
        snapshotProvider: @escaping SnapshotProvider
    ) {
        let previous = previousDiagnosticsReader()
        stateLock.lock()
        activeGeneration &+= 1
        let generation = activeGeneration
        isRunning = true
        lastObservedRevision = initialRevision
        stateLock.unlock()

        // A synchronous hand-off drains any job from a previous generation
        // before the new provider can publish its first heartbeat.
        queue.sync {
            timer?.cancel()
            self.snapshotProvider = snapshotProvider
            previousDiagnostics = previous
            heartbeatSequence = 0

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + heartbeat,
                repeating: heartbeat,
                leeway: .seconds(2)
            )
            timer.setEventHandler { [weak self] in
                self?.publishOnQueue(reason: "heartbeat", generation: generation)
            }
            self.timer = timer
            timer.resume()
            publishOnQueue(reason: "provider-start", generation: generation)
        }
    }

    /// Publishes promptly when the accepted revision changes. Routine flows at
    /// the same revision do no allocation and enqueue no work.
    func recordIfRevisionChanged(_ revision: UInt64) {
        stateLock.lock()
        guard isRunning, revision != lastObservedRevision else {
            stateLock.unlock()
            return
        }
        lastObservedRevision = revision
        let generation = activeGeneration
        stateLock.unlock()
        queue.async { [weak self] in
            self?.publishOnQueue(reason: "policy-revision", generation: generation)
        }
    }

    /// Drains any snapshot already being built, then writes one from the latest
    /// applied-settings state before returning. Provider transitions call this
    /// after changing pending/ready state so an older same-revision heartbeat
    /// can never be the last record observed by the app or block-page daemon.
    func publishNow(reason: String) {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        let generation = activeGeneration
        stateLock.unlock()
        queue.sync {
            publishOnQueue(reason: reason, generation: generation)
        }
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        activeGeneration &+= 1
        lastObservedRevision = nil
        stateLock.unlock()

        // Wait for a write already executing on the serial queue, then tear
        // down its source. Once this returns, no old-generation job can write.
        queue.sync {
            timer?.cancel()
            timer = nil
            snapshotProvider = nil
            previousDiagnostics = nil
        }
    }

    private func publishOnQueue(reason: String, generation: UInt64) {
        guard generationIsActive(generation), let provider = snapshotProvider else { return }
        heartbeatSequence &+= 1
        let sequence = heartbeatSequence
        let previous = previousDiagnostics

        let now = Date()
        let status = provider(sequence, previous, now)
        // `stop()` invalidates the generation before waiting for this queue.
        // Re-check after snapshot construction so a slow provider cannot write
        // a status record after shutdown has begun.
        guard generationIsActive(generation) else { return }
        do {
            try writer(status)
            logSummary(status, reason: reason)
            let diagnostics = status.diagnostics
            DesktopDiagnosticTrace.record(
                component: "provider-status",
                event: reason == "heartbeat" ? "heartbeat" : "status_published",
                fields: [
                    "reason": reason,
                    "session": diagnostics?.sessionID ?? "missing",
                    "build": diagnostics?.providerBuild ?? "unknown",
                    "heartbeat": diagnostics?.heartbeatSequence ?? 0,
                    "revision": status.revision,
                    "settings_ready": status.macFilterSettings?.isReady ?? false,
                    "active_rule_count": status.activeRuleCount,
                    "active_domain_count": status.activeDomainCount,
                    "flows": diagnostics?.count(.newFlows) ?? 0,
                    "current_inspections": diagnostics?.currentInspections ?? 0,
                    "fail_open": diagnostics?.failOpenActive ?? false
                ]
            )
        } catch {
            let error = error as NSError
            logger.error(
                "status_write_failed reason=\(reason, privacy: .public) heartbeat=\(sequence, privacy: .public) revision=\(status.revision, privacy: .public) error_domain=\(error.domain, privacy: .public) error_code=\(error.code, privacy: .public) description=\(error.localizedDescription, privacy: .private)"
            )
            DesktopDiagnosticTrace.record(
                component: "provider-status",
                event: "status_write_failed",
                fields: [
                    "reason": reason,
                    "heartbeat": sequence,
                    "revision": status.revision,
                    "error_domain": error.domain,
                    "error_code": error.code
                ]
            )
        }
    }

    private func generationIsActive(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning && activeGeneration == generation
    }

    private func logSummary(_ status: FilterEnforcementStatus, reason: String) {
        let diagnostics = status.diagnostics
        let session = diagnostics?.sessionID ?? "missing"
        let build = diagnostics?.providerBuild ?? "unknown"
        let heartbeatSequence = diagnostics?.heartbeatSequence ?? 0
        let flows = diagnostics?.count(.newFlows) ?? 0
        let currentInspections = diagnostics?.currentInspections ?? 0
        let peakInspections = diagnostics?.peakInspections ?? 0
        let namedDrops = (diagnostics?.count(.newFlowDroppedNamed) ?? 0)
            + (diagnostics?.count(.outboundDroppedNamed) ?? 0)
            + (diagnostics?.count(.completionDroppedNamed) ?? 0)
        let unidentifiedDrops = (diagnostics?.count(.newFlowDroppedUnidentified) ?? 0)
            + (diagnostics?.count(.outboundDroppedUnidentified) ?? 0)
            + (diagnostics?.count(.completionDroppedUnidentified) ?? 0)
        let terminalUnclassified = diagnostics?.count(
            WebFilterDiagnosticCounter.completionUnclassifiedAllowed
        ) ?? 0
        let invalidSequences = diagnostics?.count(.invalidSequenceReleases) ?? 0
        let continuationReleases = diagnostics?.count(.continuationLimitReleases) ?? 0
        let isFailOpen = diagnostics?.failOpenActive ?? false
        let failOpenTrips = diagnostics?.failOpenTrips ?? 0
        let settingsReady = status.macFilterSettings?.isReady ?? false
        let requiredRetryDomains = status.macFilterSettings?.requiredRetryGuardDomainCount ?? 0
        let coveredRetryDomains = status.macFilterSettings?.coveredRetryGuardDomainCount ?? 0
        let correlatedAddresses = status.macFilterSettings?.correlatedAddressCount ?? 0
        let level: OSLogType = reason == "heartbeat" ? .debug : .default
        logger.log(
            level: level,
            "diagnostic_summary reason=\(reason, privacy: .public) session=\(session, privacy: .public) build=\(build, privacy: .public) heartbeat=\(heartbeatSequence, privacy: .public) revision=\(status.revision, privacy: .public) settings_ready=\(settingsReady, privacy: .public) required_retry_domains=\(requiredRetryDomains, privacy: .public) covered_retry_domains=\(coveredRetryDomains, privacy: .public) correlated_addresses=\(correlatedAddresses, privacy: .public) flows=\(flows, privacy: .public) inspections_current=\(currentInspections, privacy: .public) inspections_peak=\(peakInspections, privacy: .public) drops_named=\(namedDrops, privacy: .public) drops_unidentified=\(unidentifiedDrops, privacy: .public) terminal_unclassified=\(terminalUnclassified, privacy: .public) invalid_sequences=\(invalidSequences, privacy: .public) continuation_releases=\(continuationReleases, privacy: .public) fail_open=\(isFailOpen, privacy: .public) fail_open_trips=\(failOpenTrips, privacy: .public)"
        )
    }
}
