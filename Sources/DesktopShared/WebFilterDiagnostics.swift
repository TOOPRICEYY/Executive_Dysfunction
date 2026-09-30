import Foundation

/// Fixed-cardinality counters emitted by the macOS web filter.
///
/// Counter names are persisted in `filter-status.json`; keep their raw values
/// stable. They describe control flow only and never include destinations,
/// applications, rules, payloads, or other browsing data.
enum WebFilterDiagnosticCounter: String, Codable, CaseIterable {
    case newFlows = "new_flows"
    case tcpFlows = "tcp_flows"
    case udpFlows = "udp_flows"
    case namedFlows = "named_flows"
    case unnamedFlows = "unnamed_flows"
    case sourceIdentityResolutionRequested = "source_identity_resolution_requested"
    case sourceIdentityResolutionSkipped = "source_identity_resolution_skipped"
    case newFlowAllowed = "new_flow_allowed"
    case newFlowInspected = "new_flow_inspected"
    case newFlowDroppedNamed = "new_flow_dropped_named"
    case newFlowDroppedUnidentified = "new_flow_dropped_unidentified"
    case outboundCallbacks = "outbound_callbacks"
    case outboundBytes = "outbound_bytes"
    case outboundBytesPassed = "outbound_bytes_passed"
    case outboundPeekBytesRequested = "outbound_peek_bytes_requested"
    case outboundOverlapBytes = "outbound_overlap_bytes"
    case outboundAllowed = "outbound_allowed"
    case outboundContinued = "outbound_continued"
    case outboundDroppedNamed = "outbound_dropped_named"
    case outboundDroppedUnidentified = "outbound_dropped_unidentified"
    case completionCallbacks = "completion_callbacks"
    case completionAllowed = "completion_allowed"
    case completionDroppedNamed = "completion_dropped_named"
    case completionDroppedUnidentified = "completion_dropped_unidentified"
    case completionUnclassifiedAllowed = "completion_unclassified_allowed"
    case completionUnclassifiedDropped = "completion_unclassified_dropped"
    case inspectionsStarted = "inspections_started"
    case inspectionsFinished = "inspections_finished"
    case invalidSequenceReleases = "invalid_sequence_releases"
    case callbackWithoutStateReleases = "callback_without_state_releases"
    case emptyCallbackReleases = "empty_callback_releases"
    case offsetGapReleases = "offset_gap_releases"
    case offsetConflictReleases = "offset_conflict_releases"
    case offsetReplayReleases = "offset_replay_releases"
    case streamLimitReleases = "stream_limit_releases"
    case staleStreamStateReleases = "stale_stream_state_releases"
    case invalidStreamRequirementReleases = "invalid_stream_requirement_releases"
    case continuationLimitReleases = "continuation_limit_releases"
    case inspectionTableResets = "inspection_table_resets"
    case completionWithoutInspectionState = "completion_without_inspection_state"
    case failOpenTrips = "fail_open_trips"
    case dropPressureWarnings = "drop_pressure_warnings"
    case failOpenRearms = "fail_open_rearms"
    case failOpenBypasses = "fail_open_bypasses"
    case policyRevisionChanges = "policy_revision_changes"
}

enum WebFilterDiagnosticStage: String, Codable, Equatable {
    case newFlow = "new_flow"
    case outboundData = "outbound_data"
    case outboundComplete = "outbound_complete"
}

enum WebFilterDiagnosticAnomalyCode: String, Codable, Equatable {
    case outboundCompletedUnclassified = "outbound_completed_unclassified"
    case invalidByteSequence = "invalid_byte_sequence"
    case outboundCallbackWithoutState = "outbound_callback_without_state"
    case emptyOutboundCallback = "empty_outbound_callback"
    case streamOffsetGap = "stream_offset_gap"
    case streamOffsetConflict = "stream_offset_conflict"
    case streamOffsetReplay = "stream_offset_replay"
    case streamByteLimitExceeded = "stream_byte_limit_exceeded"
    case staleStreamState = "stale_stream_state"
    case invalidStreamRequirement = "invalid_stream_requirement"
    case continuationLimit = "continuation_limit"
    case inspectionTableReset = "inspection_table_reset"
    case failOpenTripped = "fail_open_tripped"
    case failOpenRearmed = "fail_open_rearmed"
}

enum WebFilterDiagnosticTransport: String, Codable, Equatable {
    case tcp
    case udp
}

enum WebFilterDiagnosticPortClass: String, Codable, Equatable {
    case web
    case dns
    case encryptedDNS = "encrypted_dns"
    case other
    case unknown

    init(port: Int?) {
        guard let port else {
            self = .unknown
            return
        }
        switch port {
        case 80, 443, 8080, 8443: self = .web
        case 53: self = .dns
        case 784, 853, 8853: self = .encryptedDNS
        default: self = .other
        }
    }
}

/// One bounded, redacted breadcrumb for an unusual decision.
struct WebFilterDiagnosticAnomaly: Codable, Equatable {
    /// Rounded down to a one-minute bucket. The exact event remains available
    /// in private Unified Logging without exposing browsing timing through the
    /// world-readable status file.
    var timestamp: Date
    var code: WebFilterDiagnosticAnomalyCode
    var stage: WebFilterDiagnosticStage
    var reason: WebFilterDecisionReason?
    var revision: UInt64
    var transport: WebFilterDiagnosticTransport
    var portClass: WebFilterDiagnosticPortClass
    var bytes: Int?
    var continuations: Int?
    var offset: Int? = nil
    var passedBytes: Int? = nil
    var requestedBytes: Int? = nil
}

/// Privacy-safe diagnostics for one provider process lifetime.
///
/// This snapshot is world-readable through `filter-status.json`, so its schema
/// intentionally has no field capable of carrying a hostname, IP address, URL,
/// application identity, executable path, rule name/ID, or payload bytes.
struct WebFilterDiagnosticsSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: String
    var providerStartedAt: Date
    var providerVersion: String
    var providerBuild: String
    /// Activity timestamps are rounded down to one-minute buckets.
    var lastEventAt: Date
    var lastFlowAt: Date?
    var policyRevision: UInt64
    var heartbeatSequence: UInt64
    var counters: [String: UInt64]
    var decisionReasons: [String: UInt64]
    var currentInspections: Int
    var peakInspections: Int
    var maximumInspectedBytes: Int
    var maximumObservedOffset: Int? = nil
    var failOpenActive: Bool
    var failOpenUntil: Date?
    var failOpenTrips: Int
    var unidentifiedDropsInWindow: Int
    var recentAnomalies: [WebFilterDiagnosticAnomaly]
    var dropPressureWarningActive: Bool? = nil

    func count(_ counter: WebFilterDiagnosticCounter) -> UInt64 {
        counters[counter.rawValue, default: 0]
    }

    func count(_ reason: WebFilterDecisionReason) -> UInt64 {
        decisionReasons[reason.rawValue, default: 0]
    }
}

/// Thread-safe, allocation-bounded provider telemetry.
///
/// Flow callbacks only update integer counters and a sixteen-entry anomaly
/// ring. Disk writes and routine OSLog summaries remain on the status queue.
final class WebFilterDiagnostics: @unchecked Sendable {
    static let maximumRecentAnomalies = 16

    private let lock = NSLock()
    private let sessionID: String
    private let providerStartedAt: Date
    private let providerVersion: String
    private let providerBuild: String
    private var lastEventAt: Date
    private var lastFlowAt: Date?
    private var policyRevision: UInt64 = 0
    private var counters: [String: UInt64] = [:]
    private var decisionReasons: [String: UInt64] = [:]
    private var currentInspections = 0
    private var peakInspections = 0
    private var maximumInspectedBytes = 0
    private var maximumObservedOffset = 0
    private var recentAnomalies: [WebFilterDiagnosticAnomaly] = []
    private var lastFailOpenActive = false

    init(
        sessionID: String = UUID().uuidString,
        providerStartedAt: Date = Date(),
        providerVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        providerBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    ) {
        self.sessionID = sessionID
        self.providerStartedAt = providerStartedAt
        self.providerVersion = providerVersion
        self.providerBuild = providerBuild
        lastEventAt = Self.privacyBucket(providerStartedAt)
    }

    func recordDecision(
        stage: WebFilterDiagnosticStage,
        outcome: WebFilterFlowOutcome,
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        bytes: Int? = nil,
        accumulatedBytes: Int? = nil,
        offset: Int? = nil,
        passedBytes: Int? = nil,
        requestedBytes: Int? = nil,
        overlapBytes: Int? = nil,
        at now: Date = Date()
    ) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        lastEventAt = eventAt
        lastFlowAt = eventAt

        if stage == .newFlow {
            incrementLocked(.newFlows)
            incrementLocked(descriptor.isTCP ? .tcpFlows : .udpFlows)
            let hasName = descriptor.hostname?.isEmpty == false
            incrementLocked(hasName ? .namedFlows : .unnamedFlows)
        } else if stage == .outboundData {
            incrementLocked(.outboundCallbacks)
            if let bytes {
                incrementLocked(.outboundBytes, by: UInt64(max(0, bytes)))
            }
            if let passedBytes {
                incrementLocked(.outboundBytesPassed, by: UInt64(max(0, passedBytes)))
            }
            if let requestedBytes {
                incrementLocked(.outboundPeekBytesRequested, by: UInt64(max(0, requestedBytes)))
            }
            if let overlapBytes {
                incrementLocked(.outboundOverlapBytes, by: UInt64(max(0, overlapBytes)))
            }
            if let offset {
                maximumObservedOffset = max(maximumObservedOffset, max(0, offset))
            }
            maximumInspectedBytes = max(
                maximumInspectedBytes,
                accumulatedBytes ?? bytes ?? 0
            )
        } else {
            incrementLocked(.completionCallbacks)
        }

        decisionReasons[outcome.reason.rawValue, default: 0] += 1
        if outcome.reason == .completionUnclassifiedAllowed {
            incrementLocked(.completionUnclassifiedAllowed)
        } else if outcome.reason == .completionUnclassifiedFortressBlocked {
            incrementLocked(.completionUnclassifiedDropped)
        }
        switch (stage, outcome.decision, outcome.dropKind) {
        case (.newFlow, .allow, _): incrementLocked(.newFlowAllowed)
        case (.newFlow, .inspect, _): incrementLocked(.newFlowInspected)
        case (.newFlow, .drop, .named): incrementLocked(.newFlowDroppedNamed)
        case (.newFlow, .drop, _): incrementLocked(.newFlowDroppedUnidentified)
        case (.outboundData, .allow, _): incrementLocked(.outboundAllowed)
        case (.outboundData, .inspect, _): incrementLocked(.outboundContinued)
        case (.outboundData, .drop, .named): incrementLocked(.outboundDroppedNamed)
        case (.outboundData, .drop, _): incrementLocked(.outboundDroppedUnidentified)
        case (.outboundComplete, .allow, _), (.outboundComplete, .inspect, _):
            incrementLocked(.completionAllowed)
        case (.outboundComplete, .drop, .named): incrementLocked(.completionDroppedNamed)
        case (.outboundComplete, .drop, _): incrementLocked(.completionDroppedUnidentified)
        }
        lock.unlock()
    }

    func recordSourceIdentityResolution(
        requested: Bool,
        revision: UInt64,
        at now: Date = Date()
    ) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        incrementLocked(
            requested ? .sourceIdentityResolutionRequested : .sourceIdentityResolutionSkipped,
            at: eventAt
        )
        lock.unlock()
    }

    func inspectionStarted(at now: Date = Date()) {
        lock.lock()
        currentInspections += 1
        peakInspections = max(peakInspections, currentInspections)
        incrementLocked(.inspectionsStarted, at: Self.privacyBucket(now))
        lock.unlock()
    }

    func inspectionFinished(at now: Date = Date()) {
        lock.lock()
        currentInspections = max(0, currentInspections - 1)
        incrementLocked(.inspectionsFinished, at: Self.privacyBucket(now))
        lock.unlock()
    }

    func recordInvalidSequence(
        _ error: WebFilterStreamingSequenceError,
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        offset: Int,
        bytes: Int,
        at now: Date = Date()
    ) {
        let details: (WebFilterDiagnosticAnomalyCode, WebFilterDiagnosticCounter) = switch error {
        case .emptyCallback: (.emptyOutboundCallback, .emptyCallbackReleases)
        case .negativeOffset, .offsetGap: (.streamOffsetGap, .offsetGapReleases)
        case .conflictingOverlap: (.streamOffsetConflict, .offsetConflictReleases)
        case .replayOnly: (.streamOffsetReplay, .offsetReplayReleases)
        case .byteLimitExceeded: (.streamByteLimitExceeded, .streamLimitReleases)
        case .staleState: (.staleStreamState, .staleStreamStateReleases)
        case .invalidRequirement: (.invalidStreamRequirement, .invalidStreamRequirementReleases)
        }
        recordAnomaly(
            details.0,
            stage: .outboundData,
            reason: .streamInvalidSequenceAllowed,
            descriptor: descriptor,
            revision: revision,
            bytes: bytes,
            continuations: nil,
            counter: details.1,
            offset: offset,
            at: now
        )
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        incrementLocked(.invalidSequenceReleases, at: eventAt)
        lock.unlock()
    }

    func recordCallbackWithoutInspectionState(
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        offset: Int,
        bytes: Int,
        at now: Date = Date()
    ) {
        recordAnomaly(
            .outboundCallbackWithoutState,
            stage: .outboundData,
            reason: .streamMissingStateAllowed,
            descriptor: descriptor,
            revision: revision,
            bytes: bytes,
            continuations: nil,
            counter: .callbackWithoutStateReleases,
            offset: offset,
            at: now
        )
    }

    /// Records the cursor movement requested after an already-counted outbound
    /// decision. Kept separate from `recordDecision` so one callback never
    /// increments the callback or reason counters twice.
    func recordStreamingContinuation(
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        offset: Int,
        bytes: Int,
        accumulatedBytes: Int,
        passedBytes: Int,
        requestedBytes: Int,
        overlapBytes: Int,
        at now: Date = Date()
    ) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        lastEventAt = eventAt
        lastFlowAt = eventAt
        incrementLocked(.outboundBytesPassed, by: UInt64(max(0, passedBytes)))
        incrementLocked(.outboundPeekBytesRequested, by: UInt64(max(0, requestedBytes)))
        incrementLocked(.outboundOverlapBytes, by: UInt64(max(0, overlapBytes)))
        maximumObservedOffset = max(maximumObservedOffset, max(0, offset))
        maximumInspectedBytes = max(maximumInspectedBytes, max(0, accumulatedBytes))
        lock.unlock()
    }

    func recordCompletionWithoutInspectionState(
        revision: UInt64,
        at now: Date = Date()
    ) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        incrementLocked(.completionWithoutInspectionState, at: eventAt)
        lock.unlock()
    }

    func recordContinuationLimit(
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        bytes: Int,
        continuations: Int,
        at now: Date = Date()
    ) {
        recordAnomaly(
            .continuationLimit,
            stage: .outboundData,
            reason: .tlsIncomplete,
            descriptor: descriptor,
            revision: revision,
            bytes: bytes,
            continuations: continuations,
            counter: .continuationLimitReleases,
            at: now
        )
    }

    func recordUnclassifiedCompletion(
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        bytes: Int,
        continuations: Int,
        reason: WebFilterDecisionReason,
        at now: Date = Date()
    ) {
        recordAnomaly(
            .outboundCompletedUnclassified,
            stage: .outboundComplete,
            reason: reason,
            descriptor: descriptor,
            revision: revision,
            bytes: bytes,
            continuations: continuations,
            counter: nil,
            at: now
        )
    }

    func recordInspectionTableReset(
        revision: UInt64,
        discarded: Int,
        at now: Date = Date()
    ) {
        let descriptor = WebFilterFlowDescriptor()
        lock.lock()
        currentInspections = 0
        lock.unlock()
        recordAnomaly(
            .inspectionTableReset,
            stage: .newFlow,
            reason: nil,
            descriptor: descriptor,
            revision: revision,
            bytes: nil,
            continuations: discarded,
            counter: .inspectionTableResets,
            at: now
        )
    }

    func recordDropPressureWarning(revision: UInt64, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let eventAt = Self.privacyBucket(now)
        noteRevisionLocked(revision, at: eventAt)
        incrementLocked(.dropPressureWarnings, at: eventAt)
    }

    func recordFailOpenTrip(revision: UInt64, at now: Date = Date()) {
        recordAnomaly(
            .failOpenTripped,
            stage: .newFlow,
            reason: nil,
            descriptor: WebFilterFlowDescriptor(),
            revision: revision,
            bytes: nil,
            continuations: nil,
            counter: .failOpenTrips,
            at: now
        )
        lock.lock()
        lastFailOpenActive = true
        lock.unlock()
    }

    func recordFailOpenBypass(revision: UInt64, at now: Date = Date()) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        incrementLocked(.failOpenBypasses, at: eventAt)
        lastFlowAt = eventAt
        lock.unlock()
    }

    /// Records the open -> closed edge once. The governor re-arms lazily when
    /// queried, so without this edge a future report cannot tell whether the
    /// valve recovered or the provider simply restarted.
    func observeFailOpenState(_ state: WebFilterFailOpenState, revision: UInt64, at now: Date = Date()) {
        lock.lock()
        let rearmed = lastFailOpenActive && !state.isOpen
        lastFailOpenActive = state.isOpen
        lock.unlock()
        guard rearmed else { return }
        recordAnomaly(
            .failOpenRearmed,
            stage: .newFlow,
            reason: nil,
            descriptor: WebFilterFlowDescriptor(),
            revision: revision,
            bytes: nil,
            continuations: nil,
            counter: .failOpenRearms,
            at: now
        )
    }

    func snapshot(
        policyRevision: UInt64,
        heartbeatSequence: UInt64,
        failOpen: WebFilterFailOpenState,
        at now: Date = Date()
    ) -> WebFilterDiagnosticsSnapshot {
        lock.lock()
        noteRevisionLocked(policyRevision, at: Self.privacyBucket(now))
        let snapshot = WebFilterDiagnosticsSnapshot(
            schemaVersion: WebFilterDiagnosticsSnapshot.currentSchemaVersion,
            sessionID: sessionID,
            providerStartedAt: providerStartedAt,
            providerVersion: providerVersion,
            providerBuild: providerBuild,
            lastEventAt: lastEventAt,
            lastFlowAt: lastFlowAt,
            policyRevision: policyRevision,
            heartbeatSequence: heartbeatSequence,
            counters: counters,
            decisionReasons: decisionReasons,
            currentInspections: currentInspections,
            peakInspections: peakInspections,
            maximumInspectedBytes: maximumInspectedBytes,
            maximumObservedOffset: maximumObservedOffset,
            failOpenActive: failOpen.isOpen,
            failOpenUntil: failOpen.openUntil,
            failOpenTrips: failOpen.trips,
            unidentifiedDropsInWindow: failOpen.unidentifiedDropsInWindow,
            recentAnomalies: recentAnomalies,
            dropPressureWarningActive: failOpen.warningActive
        )
        lock.unlock()
        return snapshot
    }

    private func recordAnomaly(
        _ code: WebFilterDiagnosticAnomalyCode,
        stage: WebFilterDiagnosticStage,
        reason: WebFilterDecisionReason?,
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64,
        bytes: Int?,
        continuations: Int?,
        counter: WebFilterDiagnosticCounter?,
        offset: Int? = nil,
        passedBytes: Int? = nil,
        requestedBytes: Int? = nil,
        at now: Date
    ) {
        let eventAt = Self.privacyBucket(now)
        lock.lock()
        noteRevisionLocked(revision, at: eventAt)
        if let counter { incrementLocked(counter) }
        lastEventAt = eventAt
        recentAnomalies.append(
            WebFilterDiagnosticAnomaly(
                timestamp: eventAt,
                code: code,
                stage: stage,
                reason: reason,
                revision: revision,
                transport: descriptor.isTCP ? .tcp : .udp,
                portClass: WebFilterDiagnosticPortClass(port: descriptor.remotePort),
                bytes: bytes,
                continuations: continuations,
                offset: offset,
                passedBytes: passedBytes,
                requestedBytes: requestedBytes
            )
        )
        if recentAnomalies.count > Self.maximumRecentAnomalies {
            recentAnomalies.removeFirst(recentAnomalies.count - Self.maximumRecentAnomalies)
        }
        lock.unlock()
    }

    private func noteRevisionLocked(_ revision: UInt64, at now: Date) {
        guard revision != policyRevision else { return }
        if policyRevision != 0 {
            incrementLocked(.policyRevisionChanges)
        }
        policyRevision = revision
        lastEventAt = now
    }

    private static func privacyBucket(_ date: Date) -> Date {
        let seconds = floor(date.timeIntervalSince1970 / 60) * 60
        return Date(timeIntervalSince1970: seconds)
    }

    private func incrementLocked(
        _ counter: WebFilterDiagnosticCounter,
        by amount: UInt64 = 1,
        at now: Date? = nil
    ) {
        counters[counter.rawValue, default: 0] += amount
        if let now { lastEventAt = now }
    }
}
