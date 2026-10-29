import Foundation
import Darwin
import Network
import NetworkExtension
import OSLog

final class MacWebFilterProvider: NEFilterDataProvider, @unchecked Sendable {
    private typealias Inspection = WebFilterStreamingInspection

    private final class SettingsCompletion: @unchecked Sendable {
        private let handler: (Error?) -> Void

        init(_ handler: @escaping (Error?) -> Void) {
            self.handler = handler
        }

        func call(_ error: Error?) {
            handler(error)
        }
    }

    private struct InspectionCallback {
        var state: Inspection
        var append: WebFilterStreamingAppend
    }

    /// Ceiling on concurrently held flows. `finishInspection` is not guaranteed
    /// to run for every flow — a flow torn down by the peer may never deliver a
    /// final callback — so without a cap this dictionary grows for the lifetime
    /// of a root system extension.
    private static let maximumTrackedFlows = 4_096

    private let policyLoader = ResilientDesktopPolicyLoader()
    private let sourceResolver = FlowSourceResolver()
    private let statusPublisher = FilterStatusPublisher()
    private let failOpen = WebFilterFailOpenGovernor()
    private let diagnostics = WebFilterDiagnostics()
    private let blockedEndpointCache = BlockedEndpointCorrelationCache()
    private let temporaryPauseStore = BlockPageTemporaryPauseStore()
    private let inspectionLock = NSLock()
    private var inspections: [ObjectIdentifier: Inspection] = [:]
    private let settingsQueue = DispatchQueue(
        label: "com.GabrielPrice.ExecutiveDysfunction.filter-settings",
        qos: .utility
    )
    private let settingsLock = NSLock()
    private var settingsTimer: DispatchSourceTimer?
    private var settingsLifecycle = MacFilterSettingsLifecycle()
    private var physicalApplyState = MacFilterPhysicalApplyState()
    private var pendingStopStatus: FilterEnforcementStatus?
    private var pendingStopCompletionHandlers: [() -> Void] = []
    private var activeStopGeneration: UInt64?
    private var stopGeneration: UInt64 = 0
    private var stopPreparationComplete = false
    private var pendingStopApplyAction: MacFilterStopApplyAction = .none
    private var appliedInterceptionPlan: MacFilterInterceptionPlan?
    private var appliedPolicyRevision: UInt64?
    private var appliedEnforcementReady = false
    private var correlatedDomainResolution = MacFilterDomainAddressResolution()
    private var correlatedBlockedAddresses: Set<String> = []
    private var correlatedBlockedRevision: UInt64 = 0
    private var lastAddressResolutionAt = Date.distantPast
    /// Validated off the verdict path and consumed from callbacks without disk
    /// I/O. Revision binding makes a newly accepted policy fail closed before
    /// the next refresh reads the pause document.
    private var temporaryPausePolicyRevision: UInt64?
    private var temporaryPauseExpirations: [UUID: Date] = [:]
    private var browserBypassEvents = FilterStatusStore.read()?.browserBypassEvents ?? []
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "data-provider"
    )

    /// NetworkExtension callbacks are not guaranteed to arrive during a daemon
    /// failure. Disabling must still finish promptly enough for macOS to remove
    /// the compulsory filter from the network path.
    private static let stopCompletionDeadline: TimeInterval = 2

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        // Before any policy evaluation: from here on a wall-clock change makes
        // rule windows and lockdowns stricter, not looser.
        TamperJournal.shared.install(storage: UserDefaults.standard, origin: "mac-filter")
        ClockTamperGuard.shared.install()
        let now = Date()
        let operationToken = beginProviderSettingsLifecycle()
        let policy = refreshTemporaryPauses(
            for: loadBasePolicy(at: now),
            at: now
        )
        let failOpenState = failOpen.state(at: now)
        let startup = diagnostics.snapshot(
            policyRevision: policy.revision,
            heartbeatSequence: 0,
            failOpen: failOpenState,
            at: now
        )
        let plan = MacFilterInterceptionPlan.make(for: policy, at: now)
        logger.notice(
            "provider_started session=\(startup.sessionID, privacy: .public) version=\(startup.providerVersion, privacy: .public) build=\(startup.providerBuild, privacy: .public) revision=\(policy.revision, privacy: .public) rules=\(policy.rules.count, privacy: .public) active_web=\(policy.hasActiveWebRestrictions(at: now), privacy: .public) interception=\(plan.mode.rawValue, privacy: .public) default_action=\(plan.defaultAction.rawValue, privacy: .public) system_domain_rules=\(plan.blockedDomainSuffixes.count, privacy: .public) system_port_rules=\(plan.blockedDestinationPorts.count * 2, privacy: .public) settings_ready=false startup_action=complete-before-resolution"
        )
        DesktopDiagnosticTrace.record(
            component: "provider",
            event: "provider_started",
            fields: [
                "session": startup.sessionID,
                "build": startup.providerBuild,
                "revision": policy.revision,
                "rule_count": policy.rules.count,
                "active_web": policy.hasActiveWebRestrictions(at: now),
                "interception_mode": plan.mode.rawValue,
                "default_action": plan.defaultAction.rawValue,
                "settings_ready": false
            ]
        )

        // This is the outage boundary. Never make macOS wait for DNS, disk, or
        // an apply-settings callback while the compulsory filter session is in
        // Starting. Once completion fires, ordinary flows can receive explicit
        // provider verdicts and DNS can make progress. Settings are established
        // asynchronously and readiness remains false until the complete plan is
        // atomically installed.
        completionHandler(nil)
        startStatusPublisher(initialRevision: policy.revision)
        startSettingsRefreshTimer()
        settingsQueue.async { [weak self] in
            guard let self, self.settingsOperationIsCurrent(operationToken) else { return }
            self.applyInterceptionPlan(
                for: policy,
                at: now,
                operationToken: operationToken
            ) { [weak self] error in
                guard let self, let error else { return }
                let nsError = error as NSError
                self.logger.fault(
                    "provider_settings_degraded session=\(startup.sessionID, privacy: .public) revision=\(policy.revision, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private) provider_alive=true action=retry"
                )
            }
        }
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        settingsLock.lock()
        if activeStopGeneration != nil {
            pendingStopCompletionHandlers.append(completionHandler)
            let joinedGeneration = activeStopGeneration ?? 0
            settingsLock.unlock()
            logger.notice(
                "provider_stop_joined generation=\(joinedGeneration, privacy: .public)"
            )
            return
        }
        stopGeneration &+= 1
        let stopGeneration = stopGeneration
        activeStopGeneration = stopGeneration
        pendingStopCompletionHandlers = [completionHandler]
        settingsLock.unlock()

        let now = Date()
        let policy = loadCurrentPolicy(at: now)
        let snapshot = diagnostics.snapshot(
            policyRevision: policy.revision,
            heartbeatSequence: 0,
            failOpen: failOpen.state(at: now),
            at: now
        )
        let uptimeMilliseconds = max(
            0,
            Int(now.timeIntervalSince(snapshot.providerStartedAt) * 1_000)
        )
        logger.notice(
            "provider_stopping session=\(snapshot.sessionID, privacy: .public) build=\(snapshot.providerBuild, privacy: .public) revision=\(policy.revision, privacy: .public) reason=\(String(describing: reason), privacy: .public) uptime_ms=\(uptimeMilliseconds, privacy: .public) flows=\(snapshot.count(.newFlows), privacy: .public) tcp=\(snapshot.count(.tcpFlows), privacy: .public) udp=\(snapshot.count(.udpFlows), privacy: .public) named=\(snapshot.count(.namedFlows), privacy: .public) unnamed=\(snapshot.count(.unnamedFlows), privacy: .public) allowed=\(snapshot.count(.newFlowAllowed), privacy: .public) inspected=\(snapshot.count(.newFlowInspected), privacy: .public) drops_named=\(snapshot.count(.newFlowDroppedNamed), privacy: .public) drops_unidentified=\(snapshot.count(.newFlowDroppedUnidentified), privacy: .public) outbound_callbacks=\(snapshot.count(.outboundCallbacks), privacy: .public) outbound_allowed=\(snapshot.count(.outboundAllowed), privacy: .public) outbound_continued=\(snapshot.count(.outboundContinued), privacy: .public) outbound_dropped_named=\(snapshot.count(.outboundDroppedNamed), privacy: .public) outbound_dropped_unidentified=\(snapshot.count(.outboundDroppedUnidentified), privacy: .public) inspections_current=\(snapshot.currentInspections, privacy: .public) inspections_peak=\(snapshot.peakInspections, privacy: .public) identity_requested=\(snapshot.count(.sourceIdentityResolutionRequested), privacy: .public) identity_skipped=\(snapshot.count(.sourceIdentityResolutionSkipped), privacy: .public) fail_open=\(snapshot.failOpenActive, privacy: .public) fail_open_trips=\(snapshot.failOpenTrips, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "provider",
            event: "provider_stopping",
            fields: [
                "session": snapshot.sessionID,
                "build": snapshot.providerBuild,
                "revision": policy.revision,
                "reason": String(describing: reason),
                "uptime_ms": uptimeMilliseconds,
                "flows": snapshot.count(.newFlows),
                "named_flows": snapshot.count(.namedFlows),
                "unnamed_flows": snapshot.count(.unnamedFlows),
                "drops_named": snapshot.count(.newFlowDroppedNamed),
                "drops_unidentified": snapshot.count(.newFlowDroppedUnidentified),
                "fail_open": snapshot.failOpenActive
            ]
        )
        var stoppedStatus = FilterEnforcementStatus(
            policy: policy,
            at: now,
            diagnostics: snapshot
        )
        stoppedStatus.activeRuleCount = 0
        stoppedStatus.activeDomainCount = 0
        stoppedStatus.hasActiveWebRestrictions = false
        stoppedStatus.blockedDomains = nil
        stoppedStatus.blockPageRules = nil
        stoppedStatus.macFilterSettings = MacFilterSettingsStatus(
            isReady: false,
            planMode: MacFilterInterceptionPlan.Mode.bypass.rawValue,
            appliedPolicyRevision: nil,
            requiredRetryGuardDomainCount: 0,
            coveredRetryGuardDomainCount: 0,
            coveredRetryGuardDomainSuffixes: [],
            correlatedAddressCount: 0
        )

        // Invalidate logical work first. A physical apply that crossed this
        // linearization point is counted separately and must drain before one
        // final allow-all apply and the stop completion.
        settingsLock.lock()
        settingsLifecycle.stopProvider()
        appliedInterceptionPlan = nil
        appliedPolicyRevision = nil
        appliedEnforcementReady = false
        correlatedDomainResolution = MacFilterDomainAddressResolution()
        correlatedBlockedAddresses = []
        correlatedBlockedRevision = 0
        lastAddressResolutionAt = .distantPast
        temporaryPausePolicyRevision = nil
        temporaryPauseExpirations = [:]
        pendingStopStatus = stoppedStatus
        stopPreparationComplete = false
        pendingStopApplyAction = physicalApplyState.requestStop()
        settingsLock.unlock()

        // Lifecycle invalidation above is the linearization point. Resolver work
        // already queued is now harmless, so stopping must never synchronously
        // wait behind a stalled DNS lookup merely to cancel this timer.
        settingsQueue.async { [weak self] in
            self?.settingsTimer?.cancel()
            self?.settingsTimer = nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.stopCompletionDeadline
        ) { [weak self] in
            self?.finishDrainedStop(
                expectedGeneration: stopGeneration,
                forced: true
            )
        }
        statusPublisher.stop()
        settingsLock.lock()
        stopPreparationComplete = true
        let stopAction = pendingStopApplyAction
        pendingStopApplyAction = .none
        settingsLock.unlock()
        handleStopApplyAction(stopAction)
    }

    private func beginProviderSettingsLifecycle() -> MacFilterSettingsOperationToken {
        settingsLock.lock()
        let token = settingsLifecycle.startProvider()
        physicalApplyState.reset()
        pendingStopStatus = nil
        pendingStopCompletionHandlers = []
        activeStopGeneration = nil
        stopPreparationComplete = false
        pendingStopApplyAction = .none
        appliedInterceptionPlan = nil
        appliedPolicyRevision = nil
        appliedEnforcementReady = false
        correlatedDomainResolution = MacFilterDomainAddressResolution()
        correlatedBlockedAddresses = []
        correlatedBlockedRevision = 0
        lastAddressResolutionAt = .distantPast
        settingsLock.unlock()
        return token
    }

    private func settingsOperationIsCurrent(
        _ token: MacFilterSettingsOperationToken
    ) -> Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settingsLifecycle.accepts(token)
    }

    @discardableResult
    private func finishSettingsOperation(
        _ token: MacFilterSettingsOperationToken
    ) -> Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settingsLifecycle.finish(token)
    }

    private func markAppliedEnforcementNotReady(
        for token: MacFilterSettingsOperationToken
    ) -> Bool {
        settingsLock.lock()
        guard settingsLifecycle.accepts(token) else {
            settingsLock.unlock()
            return false
        }
        appliedEnforcementReady = false
        settingsLock.unlock()
        statusPublisher.publishNow(reason: "settings-pending")
        return true
    }

    private func commitAppliedSettings(
        operationToken: MacFilterSettingsOperationToken,
        policyRevision: UInt64,
        plan: MacFilterInterceptionPlan,
        resolution: MacFilterDomainAddressResolution,
        retryGuards: MacFilterRetryGuardSet,
        appliedAt date: Date
    ) -> Bool {
        settingsLock.lock()
        guard settingsLifecycle.accepts(operationToken),
              !physicalApplyState.isStopRequested else {
            settingsLock.unlock()
            return false
        }
        appliedInterceptionPlan = plan
        appliedPolicyRevision = policyRevision
        appliedEnforcementReady = true
        correlatedDomainResolution = resolution
        correlatedBlockedAddresses = retryGuards.addresses
        correlatedBlockedRevision = policyRevision
        lastAddressResolutionAt = date
        settingsLock.unlock()
        statusPublisher.publishNow(reason: "settings-applied")
        return true
    }

    private func replaceSettingsOperation(
        _ token: MacFilterSettingsOperationToken
    ) -> MacFilterSettingsOperationToken? {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        guard settingsLifecycle.finish(token) else { return nil }
        return settingsLifecycle.beginOperation()
    }

    private func restartSettingsOperation(
        replacing token: MacFilterSettingsOperationToken,
        oldPolicy: DesktopEnforcementPolicy,
        newPolicy: DesktopEnforcementPolicy,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let replacement = replaceSettingsOperation(token) else {
            completionHandler(settingsOperationCancelledError())
            return
        }
        guard markAppliedEnforcementNotReady(for: replacement) else {
            completionHandler(settingsOperationCancelledError())
            return
        }
        logger.notice(
            "filter_settings_operation_superseded old_revision=\(oldPolicy.revision, privacy: .public) new_revision=\(newPolicy.revision, privacy: .public) action=restart-latest"
        )
        applyInterceptionPlan(
            for: newPolicy,
            at: Date(),
            operationToken: replacement,
            completionHandler: completionHandler
        )
    }

    private func refreshedEffectivePolicy(at date: Date) -> DesktopEnforcementPolicy {
        refreshTemporaryPauses(
            for: loadBasePolicy(at: date),
            at: date
        )
    }

    private func settingsOperationCancelledError() -> NSError {
        NSError(
            domain: "Holdfast.FilterSettingsLifecycle",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "The filter settings operation is no longer current."]
        )
    }

    private func applyFilterSettings(
        _ settings: NEFilterSettings,
        operationToken: MacFilterSettingsOperationToken,
        completionHandler: @escaping (Error?) -> Void
    ) {
        settingsLock.lock()
        let accepted = physicalApplyState.beginLogicalApply(
            isCurrent: settingsLifecycle.accepts(operationToken)
        )
        settingsLock.unlock()
        guard accepted else {
            completionHandler(settingsOperationCancelledError())
            return
        }

        let completion = SettingsCompletion(completionHandler)
        apply(settings) { [weak self] error in
            guard let self else {
                completion.call(error)
                return
            }
            self.settingsLock.lock()
            let stopAction = self.physicalApplyState.logicalApplyFinished()
            self.settingsLock.unlock()
            completion.call(error)
            self.handleOrDeferStopApplyAction(stopAction)
        }
    }

    private func handleOrDeferStopApplyAction(_ action: MacFilterStopApplyAction) {
        guard action != .none else { return }
        settingsLock.lock()
        if physicalApplyState.isStopRequested, !stopPreparationComplete {
            pendingStopApplyAction = action
            settingsLock.unlock()
            return
        }
        settingsLock.unlock()
        handleStopApplyAction(action)
    }

    private func handleStopApplyAction(_ action: MacFilterStopApplyAction) {
        switch action {
        case .none:
            return
        case .applyFinalBypass:
            logger.notice("provider_stop_final_bypass_started")
            apply(makeBypassFilterSettings()) { [self] error in
                if let error {
                    let nsError = error as NSError
                    self.logger.fault(
                        "provider_stop_final_bypass_failed error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public) action=complete-stop"
                    )
                } else {
                    self.logger.notice("provider_stop_final_bypass_applied")
                }
                self.settingsLock.lock()
                let next = self.physicalApplyState.finalBypassFinished()
                self.settingsLock.unlock()
                self.handleOrDeferStopApplyAction(next)
            }
        case .finishStop:
            finishDrainedStop(forced: false)
        }
    }

    private func finishDrainedStop(
        expectedGeneration: UInt64? = nil,
        forced: Bool
    ) {
        settingsLock.lock()
        if let expectedGeneration,
           activeStopGeneration != expectedGeneration {
            settingsLock.unlock()
            return
        }
        guard activeStopGeneration != nil,
              !pendingStopCompletionHandlers.isEmpty else {
            settingsLock.unlock()
            return
        }
        let status = pendingStopStatus
        let completionHandlers = pendingStopCompletionHandlers
        pendingStopStatus = nil
        pendingStopCompletionHandlers = []
        activeStopGeneration = nil
        pendingStopApplyAction = .none
        settingsLock.unlock()

        if let status {
            do {
                try FilterStatusStore.write(status)
                logger.notice(
                    "provider_inactive_status_published revision=\(status.revision, privacy: .public) physical_applies_drained=\(!forced, privacy: .public) final_bypass=\(!forced, privacy: .public) forced_deadline=\(forced, privacy: .public)"
                )
            } catch {
                let nsError = error as NSError
                logger.error(
                    "provider_inactive_status_failed revision=\(status.revision, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
                )
            }
        }
        if forced {
            logger.fault(
                "provider_stop_deadline_reached action=complete-stop completion_handlers=\(completionHandlers.count, privacy: .public)"
            )
        }
        completionHandlers.forEach { $0() }
    }

    private func makeBypassFilterSettings() -> NEFilterSettings {
        makeFilterSettings(
            for: MacFilterInterceptionPlan(
                mode: .bypass,
                defaultAction: .allow,
                blockedDomainSuffixes: [],
                blockedDestinationPorts: []
            ),
            resolvedAddresses: []
        )
    }

    private func startStatusPublisher(initialRevision: UInt64) {
        statusPublisher.start(initialRevision: initialRevision) { [weak self] sequence, previousDiagnostics, timestamp in
            guard let self else {
                return FilterEnforcementStatus(
                    policy: .empty,
                    at: timestamp,
                    previousDiagnostics: previousDiagnostics
                )
            }
            let policy = self.loadCurrentPolicy(at: timestamp)
            let failOpenState = self.failOpen.state(at: timestamp)
            self.diagnostics.observeFailOpenState(
                failOpenState,
                revision: policy.revision,
                at: timestamp
            )
            return self.makePublishedStatus(
                policy: policy,
                at: timestamp,
                diagnostics: self.diagnostics.snapshot(
                    policyRevision: policy.revision,
                    heartbeatSequence: sequence,
                    failOpen: failOpenState,
                    at: timestamp
                ),
                previousDiagnostics: previousDiagnostics
            )
        }
    }

    private func makePublishedStatus(
        policy: DesktopEnforcementPolicy,
        at date: Date,
        diagnostics: WebFilterDiagnosticsSnapshot,
        previousDiagnostics: WebFilterDiagnosticsSnapshot?
    ) -> FilterEnforcementStatus {
        let plan = MacFilterInterceptionPlan.make(for: policy, at: date)
        settingsLock.lock()
        let planMatches = appliedInterceptionPlan == plan
        let appliedRevision = appliedPolicyRevision
        let resolution = planMatches
            ? correlatedDomainResolution
            : MacFilterDomainAddressResolution()
        let correlatedAddressCount = planMatches ? correlatedBlockedAddresses.count : 0
        let isFiltering = appliedEnforcementReady
            && planMatches
            && appliedRevision == policy.revision
        settingsLock.unlock()

        let retryGuards = resolution.retryGuards(for: plan)
        let isReady = isFiltering && (retryGuards.hasCompleteRequiredCoverage || !plan.inspectedWebPorts.isEmpty)
        let missing = Set(retryGuards.missingRequiredDomainSuffixes)
        let coveredDomains = plan.retryGuardRequiredDomainSuffixes.filter {
            !missing.contains($0)
        }
        var status = FilterEnforcementStatus(
            policy: policy,
            at: date,
            diagnostics: diagnostics,
            previousDiagnostics: previousDiagnostics
        )
        settingsLock.lock()
        let browserAllowances = temporaryPausePolicyRevision == policy.revision
            ? temporaryPauseExpirations.filter { $0.value > date } : [:]
        status.browserBypassEvents = browserBypassEvents
        settingsLock.unlock()
        status.tamperEvents = Array(TamperJournal.shared.events().suffix(100))
        status.temporaryAllowanceExpirations = (status.temporaryAllowanceExpirations ?? [:]).merging(browserAllowances, uniquingKeysWith: max)
        status.macFilterSettings = MacFilterSettingsStatus(
            isReady: isReady,
            planMode: plan.mode.rawValue,
            appliedPolicyRevision: appliedRevision,
            requiredRetryGuardDomainCount: plan.retryGuardRequiredDomainSuffixes.count,
            coveredRetryGuardDomainCount: isFiltering ? coveredDomains.count : 0,
            coveredRetryGuardDomainSuffixes: isFiltering ? coveredDomains : [],
            correlatedAddressCount: isFiltering ? correlatedAddressCount : 0,
            isFiltering: isFiltering,
            inspectedWebPorts: isFiltering ? plan.inspectedWebPorts : [],
            missingRetryGuardDomainSuffixes: retryGuards.missingRequiredDomainSuffixes
        )
        if !isFiltering {
            status.activeRuleCount = 0
            status.activeDomainCount = 0
            status.hasActiveWebRestrictions = false
        }
        if !isReady {
            // Avoid loopback host mappings while recovery needs public DNS.
            status.blockedDomains = nil
            status.blockPageRules = nil
        }
        return status
    }

    /// Schedules can cross a boundary without restarting the provider. Refresh
    /// the system rule plan on the same five-second cadence as the status
    /// heartbeat so a rule begins and ends promptly without funneling ordinary
    /// traffic back through `handleNewFlow`.
    private func startSettingsRefreshTimer() {
        settingsQueue.async { [weak self] in
            guard let self else { return }
            settingsTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: settingsQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Date()
                let policy = self.refreshTemporaryPauses(
                    for: self.loadBasePolicy(at: now),
                    at: now
                )
                let plan = MacFilterInterceptionPlan.make(for: policy, at: now)
                self.settingsLock.lock()
                let needsUpdate = plan != self.appliedInterceptionPlan
                    || policy.revision != self.appliedPolicyRevision
                    || !self.appliedEnforcementReady
                let needsAddressRefresh = plan.mode == .domainRules
                    && now.timeIntervalSince(self.lastAddressResolutionAt) >= 30
                let operationToken = (needsUpdate || needsAddressRefresh)
                    ? self.settingsLifecycle.beginOperation()
                    : nil
                let shouldPublishPending = operationToken != nil
                    && needsUpdate
                    && self.appliedEnforcementReady
                if shouldPublishPending {
                    self.appliedEnforcementReady = false
                }
                self.settingsLock.unlock()
                guard let operationToken else { return }
                if shouldPublishPending {
                    self.statusPublisher.publishNow(reason: "settings-target-pending")
                }
                self.applyInterceptionPlan(
                    for: policy,
                    at: now,
                    operationToken: operationToken
                ) { _ in }
            }
            settingsTimer = timer
            timer.resume()
        }
    }

    private func applyInterceptionPlan(
        for policy: DesktopEnforcementPolicy,
        at date: Date,
        startupState: MacFilterStartupResolutionState = .initial,
        operationToken: MacFilterSettingsOperationToken,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard settingsOperationIsCurrent(operationToken) else {
            completionHandler(settingsOperationCancelledError())
            return
        }
        if startupState != .initial {
            let latest = refreshedEffectivePolicy(at: date)
            if latest != policy {
                restartSettingsOperation(
                    replacing: operationToken,
                    oldPolicy: policy,
                    newPolicy: latest,
                    completionHandler: completionHandler
                )
                return
            }
        }
        let plan = MacFilterInterceptionPlan.make(for: policy, at: date)
        let resolution = domainResolution(
            for: plan,
            policyRevision: policy.revision,
            at: date
        )
        let retryGuards = resolution.retryGuards(for: plan)
        let hasManagedHostMappings = blockPageHostMappingsArePresent()
        settingsLock.lock()
        // Schedule changes also need to preserve blocking while a newly-active
        // suffix resolves. Never clear an installed plan just to refresh DNS.
        var permitsIncompleteCoverage = appliedInterceptionPlan != nil
        settingsLock.unlock()
        if let prepared = DesktopPolicyConfigurationTransport.preparedRetryGuards(from: filterConfiguration.vendorConfiguration),
           prepared.permitsIncompleteCoverage == true,
           case .accepted = prepared.validate(for: plan, policyRevision: policy.revision, at: date) {
            permitsIncompleteCoverage = true
        }
        let startupAction = MacFilterStartupResolutionCoordinator.action(
            plan: plan,
            retryGuards: retryGuards,
            hasManagedHostMappings: hasManagedHostMappings,
            state: startupState,
            permitsIncompleteCoverage: permitsIncompleteCoverage
        )

        switch startupAction {
        case .applyFinalSettings:
            if startupState.didApplyWarmupSettings {
                logger.notice(
                    "correlated_address_resolution_warmup_finished revision=\(policy.revision, privacy: .public) result=recovered attempts=\(startupState.attempt, privacy: .public) addresses=\(retryGuards.addresses.count, privacy: .public) required_domains=\(plan.retryGuardRequiredDomainSuffixes.count, privacy: .public) managed_hosts=\(hasManagedHostMappings, privacy: .public)"
                )
            }

        case .publishInactiveStatus:
            guard markAppliedEnforcementNotReady(for: operationToken) else {
                completionHandler(settingsOperationCancelledError())
                return
            }
            publishInactiveResolutionWarmupStatus(for: policy, at: date)
            var next = startupState
            next.didPublishInactiveStatus = true
            applyInterceptionPlan(
                for: policy,
                at: Date(),
                startupState: next,
                operationToken: operationToken,
                completionHandler: completionHandler
            )
            return

        case .waitForManagedHostsRelease, .waitForPublicResolution:
            logger.notice(
                "correlated_address_resolution_deferred revision=\(policy.revision, privacy: .public) reason=\(startupAction.rawValue, privacy: .public) attempt=\(startupState.attempt + 1, privacy: .public) maximum_attempts=\(MacFilterStartupResolutionCoordinator.maximumAttempts, privacy: .public) managed_hosts=\(hasManagedHostMappings, privacy: .public) delay_ms=\(Int(MacFilterStartupResolutionCoordinator.retryDelay * 1_000), privacy: .public)"
            )
            scheduleResolutionRetry(
                for: policy,
                state: startupState,
                operationToken: operationToken,
                completionHandler: completionHandler
            )
            return

        case .applyWarmupSettings:
            // Replacement can leave the old provider's hostname rules installed
            // after /etc/hosts is clean. Clear those inherited rules exactly once
            // before asking the system resolver for public addresses again.
            guard markAppliedEnforcementNotReady(for: operationToken) else {
                completionHandler(settingsOperationCancelledError())
                return
            }
            applyResolutionWarmupSettings(
                operationToken: operationToken
            ) { [weak self] error in
                guard let self else {
                    completionHandler(error)
                    return
                }
                guard self.settingsOperationIsCurrent(operationToken) else {
                    completionHandler(self.settingsOperationCancelledError())
                    return
                }
                let latest = self.refreshedEffectivePolicy(at: Date())
                if latest != policy {
                    self.restartSettingsOperation(
                        replacing: operationToken,
                        oldPolicy: policy,
                        newPolicy: latest,
                        completionHandler: completionHandler
                    )
                    return
                }
                if let error {
                    let nsError = error as NSError
                    self.logger.fault(
                        "correlated_address_resolution_warmup_settings_failed revision=\(policy.revision, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public) provider_alive=true settings_ready=false action=remain-alive-degraded"
                    )
                    self.finishSettingsOperation(operationToken)
                    completionHandler(error)
                    return
                }
                self.logger.notice(
                    "correlated_address_resolution_warmup_settings_applied revision=\(policy.revision, privacy: .public) default_action=allow"
                )
                var next = startupState
                next.didApplyWarmupSettings = true
                self.applyInterceptionPlan(
                    for: policy,
                    at: Date(),
                    startupState: next,
                    operationToken: operationToken,
                    completionHandler: completionHandler
                )
            }
            return

        case .applyLimitedSettings:
            logger.notice(
                "correlated_address_resolution_warmup_finished revision=\(policy.revision, privacy: .public) result=partial attempts=\(startupState.attempt, privacy: .public) addresses=\(retryGuards.addresses.count, privacy: .public) missing_required_domains=\(retryGuards.missingRequiredDomainSuffixes.count, privacy: .public) managed_hosts=\(hasManagedHostMappings, privacy: .public) action=apply-named-blocks-and-continue-dns-recovery"
            )
        }

        let settings = makeFilterSettings(
            for: plan,
            resolvedAddresses: retryGuards.addresses,
            unresolvedDomains: plan.recoveryDNSDomains(for: retryGuards)
        )
        applyFilterSettings(
            settings,
            operationToken: operationToken
        ) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            guard self.settingsOperationIsCurrent(operationToken) else {
                completionHandler(self.settingsOperationCancelledError())
                return
            }
            if let error {
                let nsError = error as NSError
                self.logger.error(
                    "filter_settings_apply_failed revision=\(policy.revision, privacy: .public) interception=\(plan.mode.rawValue, privacy: .public) default_action=\(plan.defaultAction.rawValue, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
                )
            } else {
                guard self.commitAppliedSettings(
                    operationToken: operationToken,
                    policyRevision: policy.revision,
                    plan: plan,
                    resolution: resolution,
                    retryGuards: retryGuards,
                    appliedAt: date
                ) else {
                    completionHandler(self.settingsOperationCancelledError())
                    return
                }
                let snapshot = self.diagnostics.snapshot(
                    policyRevision: policy.revision,
                    heartbeatSequence: 0,
                    failOpen: self.failOpen.state(at: date),
                    at: date
                )
                self.logger.notice(
                    "filter_settings_applied session=\(snapshot.sessionID, privacy: .public) build=\(snapshot.providerBuild, privacy: .public) revision=\(policy.revision, privacy: .public) interception=\(plan.mode.rawValue, privacy: .public) default_action=\(plan.defaultAction.rawValue, privacy: .public) system_domain_rules=\(plan.blockedDomainSuffixes.count, privacy: .public) system_port_rules=\(plan.blockedDestinationPorts.count * 2, privacy: .public) required_retry_domains=\(plan.retryGuardRequiredDomainSuffixes.count, privacy: .public) covered_retry_domains=\(plan.retryGuardRequiredDomainSuffixes.count - retryGuards.missingRequiredDomainSuffixes.count, privacy: .public) correlated_addresses=\(retryGuards.addresses.count, privacy: .public) correlated_ip_rules=\(retryGuards.addresses.count * MacFilterInterceptionPlan.correlatedWebPorts.count, privacy: .public)"
                )
            }
            let latest = self.refreshedEffectivePolicy(at: Date())
            if latest != policy {
                self.restartSettingsOperation(
                    replacing: operationToken,
                    oldPolicy: policy,
                    newPolicy: latest,
                    completionHandler: completionHandler
                )
                return
            }
            self.finishSettingsOperation(operationToken)
            completionHandler(error)
        }
    }

    private func scheduleResolutionRetry(
        for policy: DesktopEnforcementPolicy,
        state: MacFilterStartupResolutionState,
        operationToken: MacFilterSettingsOperationToken,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = SettingsCompletion(completionHandler)
        settingsQueue.asyncAfter(deadline: .now() + MacFilterStartupResolutionCoordinator.retryDelay) { [weak self] in
            guard let self else {
                completion.call(NSError(
                    domain: "Holdfast.FilterStartup",
                    code: NSUserCancelledError
                ))
                return
            }
            guard self.settingsOperationIsCurrent(operationToken) else {
                completion.call(self.settingsOperationCancelledError())
                return
            }
            var next = state
            next.attempt += 1
            self.applyInterceptionPlan(
                for: policy,
                at: Date(),
                startupState: next,
                operationToken: operationToken,
                completionHandler: completion.call
            )
        }
    }

    private func applyResolutionWarmupSettings(
        operationToken: MacFilterSettingsOperationToken,
        completionHandler: @escaping (Error?) -> Void
    ) {
        applyFilterSettings(
            makeBypassFilterSettings(),
            operationToken: operationToken,
            completionHandler: completionHandler
        )
    }

    private func blockPageHostMappingsArePresent() -> Bool {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            return false
        }
        return hosts.components(separatedBy: .newlines).contains(BlockPageHostPolicy.markerBegin)
    }

    /// The root block-page daemon removes managed host mappings only after it
    /// sees an inactive status. Publishing this transient warm-up state keeps
    /// replacement startup honest: filtering has not started yet, and public
    /// endpoint resolution must finish before the active heartbeat returns.
    private func publishInactiveResolutionWarmupStatus(
        for policy: DesktopEnforcementPolicy,
        at date: Date
    ) {
        let snapshot = diagnostics.snapshot(
            policyRevision: policy.revision,
            heartbeatSequence: 0,
            failOpen: failOpen.state(at: date),
            at: date
        )
        var status = FilterEnforcementStatus(
            policy: policy,
            at: date,
            diagnostics: snapshot
        )
        status.activeRuleCount = 0
        status.activeDomainCount = 0
        status.hasActiveWebRestrictions = false
        status.blockedDomains = nil
        status.blockPageRules = nil
        let plan = MacFilterInterceptionPlan.make(for: policy, at: date)
        settingsLock.lock()
        let warmupAppliedRevision = appliedPolicyRevision
        settingsLock.unlock()
        status.macFilterSettings = MacFilterSettingsStatus(
            isReady: false,
            planMode: plan.mode.rawValue,
            appliedPolicyRevision: warmupAppliedRevision,
            requiredRetryGuardDomainCount: plan.retryGuardRequiredDomainSuffixes.count,
            coveredRetryGuardDomainCount: 0,
            coveredRetryGuardDomainSuffixes: [],
            correlatedAddressCount: 0
        )
        do {
            try FilterStatusStore.write(status)
            logger.notice(
                "correlated_address_resolution_warmup_started revision=\(policy.revision, privacy: .public) action=publish-inactive"
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                "correlated_address_resolution_warmup_status_failed revision=\(policy.revision, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
            )
        }
    }

    private func makeFilterSettings(
        for plan: MacFilterInterceptionPlan,
        resolvedAddresses: Set<String>,
        unresolvedDomains: [String] = []
    ) -> NEFilterSettings {
        switch plan.defaultAction {
        case .filterData:
            return NEFilterSettings(rules: [], defaultAction: .filterData)

        case .allow:
            let allOutbound = makeAllOutboundNetworkRule()
            let allowAllSettings = NEFilterSettings(
                rules: [NEFilterRule(networkRule: allOutbound, action: .allow)],
                defaultAction: .allow
            )
            if plan.mode == .bypass {
                return allowAllSettings
            }
            // DNS-only exceptions let unresolved names acquire public addresses
            // without clearing web blocks. Rule order is first-match.
            var rules = unresolvedDomains.map { domain in
                NEFilterRule(networkRule: makeDestinationHostNetworkRule(domain: domain, port: MacFilterInterceptionPlan.recoveryDNSPort), action: .allow)
            }
            // First match wins. Classify web traffic before hostname/IP rules
            // so a DNS-derived shared CDN address cannot drop an allowed SNI.
            for port in plan.inspectedWebPorts {
                for address in ["0.0.0.0", "::"] {
                    rules.append(NEFilterRule(networkRule: makeDestinationNetworkRule(
                        address: address, port: port, prefix: 0), action: .filterData))
                }
            }
            rules += plan.blockedDomainSuffixes.map { domain in
                NEFilterRule(
                    networkRule: makeDestinationHostNetworkRule(domain: domain),
                    action: .drop
                )
            }
            for port in plan.blockedDestinationPorts {
                for address in ["0.0.0.0", "::"] {
                    rules.append(
                        NEFilterRule(
                            networkRule: makeDestinationNetworkRule(
                                address: address,
                                port: port,
                                prefix: 0
                            ),
                            action: .drop
                        )
                    )
                }
            }
            for address in resolvedAddresses.sorted() {
                for port in MacFilterInterceptionPlan.correlatedWebPorts {
                    // Named destinations still go through the ordinary policy
                    // decision, so a co-hosted allowed domain is released. An
                    // unnamed retry to an address currently resolved for a
                    // blocked domain is dropped immediately without waiting
                    // for TLS bytes.
                    rules.append(
                        NEFilterRule(
                            networkRule: makeDestinationNetworkRule(
                                address: address,
                                port: port,
                                prefix: address.contains(":") ? 128 : 32
                            ),
                            action: .filterData
                        )
                    )
                }
            }
            // NEFilterSettings requires at least one rule when the default is
            // allow. An idle policy uses a redundant outbound allow rule so it
            // bypasses the provider instead of reverting to implicit filtering.
            if rules.isEmpty {
                rules.append(NEFilterRule(networkRule: allOutbound, action: .allow))
            }
            return NEFilterSettings(rules: rules, defaultAction: .allow)
        }
    }

    /// NetworkExtension replaced `NWHostEndpoint` rule initializers in macOS
    /// 15. Keep the equivalent legacy path for macOS 14 so bypass and active
    /// domain filtering remain selective instead of reverting to all-traffic
    /// `.filterData`, which can turn a provider failure into a network outage.
    private func makeAllOutboundNetworkRule() -> NENetworkRule {
        if #available(macOS 15.0, *) {
            return NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .any,
                direction: .outbound
            )
        }
        return NENetworkRule(
            __remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .outbound
        )
    }

    private func makeDestinationHostNetworkRule(domain: String, port: Int = 0) -> NENetworkRule {
        if #available(macOS 15.0, *) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(domain),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
            return NENetworkRule(destinationHostEndpoint: endpoint, protocol: .any)
        }
        return NENetworkRule(
            __destinationHost: __NWHostEndpoint(hostname: domain, port: String(port)),
            protocol: .any
        )
    }

    private func makeDestinationNetworkRule(
        address: String,
        port: Int,
        prefix: Int
    ) -> NENetworkRule {
        if #available(macOS 15.0, *) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(address),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
            return NENetworkRule(
                destinationNetworkEndpoint: endpoint,
                prefix: prefix,
                protocol: .any
            )
        }
        return NENetworkRule(
            __destinationNetwork: __NWHostEndpoint(
                hostname: address,
                port: String(port)
            ),
            prefix: prefix,
            protocol: .any
        )
    }

    /// Uses the containing app's complete, revision-bound resolution for the
    /// first application of a policy. This check is deliberately before the
    /// legacy live resolver so a normal cold start performs no provider-side
    /// DNS at all. Once this exact plan is ready, periodic refreshes return to
    /// live resolution rather than reusing a potentially aging startup set.
    ///
    /// An unavailable or rejected snapshot is not a provider-start failure.
    /// `startFilter` has already completed, readiness remains false, and the
    /// existing bounded warm-up state machine retries resolution in the
    /// background. `stopFilter` never waits for this settings queue.
    private func domainResolution(
        for plan: MacFilterInterceptionPlan,
        policyRevision: UInt64,
        at date: Date
    ) -> MacFilterDomainAddressResolution {
        guard plan.mode == .domainRules, plan.maximumCorrelatedAddresses > 0 else {
            return MacFilterDomainAddressResolution()
        }

        settingsLock.lock()
        let needsPreparedStartupResolution = appliedPolicyRevision != policyRevision
            || appliedInterceptionPlan != plan
            || !appliedEnforcementReady
        settingsLock.unlock()

        guard needsPreparedStartupResolution else {
            return resolvedDomainAddresses(for: plan)
        }

        guard let prepared = DesktopPolicyConfigurationTransport.preparedRetryGuards(
            from: filterConfiguration.vendorConfiguration
        ) else {
            logger.error(
                "prepared_retry_guards_rejected revision=\(policyRevision, privacy: .public) reason=missing-or-undecodable provider_alive=true settings_ready=false action=background-resolution-retry"
            )
            return resolvedDomainAddresses(for: plan)
        }

        switch prepared.validate(
            for: plan,
            policyRevision: policyRevision,
            at: date
        ) {
        case let .accepted(accepted):
            let expiresInMilliseconds = max(
                0,
                Int(accepted.expiresAt.timeIntervalSince(date) * 1_000)
            )
            logger.notice(
                "prepared_retry_guards_accepted revision=\(policyRevision, privacy: .public) domains=\(plan.retryGuardResolutionDomainSuffixes.count, privacy: .public) required_domains=\(plan.retryGuardRequiredDomainSuffixes.count, privacy: .public) addresses=\(accepted.retryGuards.addresses.count, privacy: .public) expires_in_ms=\(expiresInMilliseconds, privacy: .public) action=apply-without-provider-dns"
            )
            return accepted.resolution

        case let .rejected(reason):
            logger.error(
                "prepared_retry_guards_rejected revision=\(policyRevision, privacy: .public) snapshot_revision=\(prepared.policyRevision, privacy: .public) reason=\(reason.rawValue, privacy: .public) provider_alive=true settings_ready=false action=background-resolution-retry"
            )
            return resolvedDomainAddresses(for: plan)
        }
    }

    /// Resolves only the configured blocked suffixes, off the flow-verdict
    /// path, before their DNS rules are installed. These addresses create
    /// selective provider rules for Chrome/curl retries that reuse an IP and
    /// present no hostname to Network Extension.
    private func resolvedDomainAddresses(
        for plan: MacFilterInterceptionPlan
    ) -> MacFilterDomainAddressResolution {
        guard plan.mode == .domainRules, plan.maximumCorrelatedAddresses > 0 else {
            return MacFilterDomainAddressResolution()
        }
        var resolution = MacFilterDomainAddressResolution()
        for domain in plan.retryGuardResolutionDomainSuffixes {
            var domainAddresses = Set<String>()
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(domain, nil, &hints, &result) == 0, let result else { continue }
            defer { freeaddrinfo(result) }
            var cursor: UnsafeMutablePointer<addrinfo>? = result
            while let item = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    item.pointee.ai_addr,
                    item.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let address = String(
                        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    ).lowercased()
                    if MacFilterInterceptionPlan.shouldCorrelateResolvedAddress(address) {
                        domainAddresses.insert(address)
                    }
                }
                cursor = item.pointee.ai_next
            }
            resolution.record(domainAddresses, forDomainSuffix: domain)
        }

        // Once system hostname drops are active, any subset of the refresh can
        // be refused. Merge at domain granularity so one successful helper lookup
        // cannot erase a still-cached endpoint for an explicit blocked site.
        settingsLock.lock()
        let previous = appliedInterceptionPlan == plan
            ? correlatedDomainResolution
            : MacFilterDomainAddressResolution()
        settingsLock.unlock()
        let merged = resolution.merging(previous)
        let freshAddressCount = resolution.retryGuards(for: plan).addresses.count
        let mergedRetryGuards = merged.retryGuards(for: plan)
        if mergedRetryGuards.addresses.count == plan.maximumCorrelatedAddresses,
           mergedRetryGuards.addresses.count > freshAddressCount {
            logger.notice(
                "correlated_address_rules_at_capacity fresh=\(freshAddressCount, privacy: .public) installed=\(mergedRetryGuards.addresses.count, privacy: .public) maximum_rules=\(MacFilterInterceptionPlan.maximumSystemRules, privacy: .public)"
            )
        }
        return merged
    }

    private func matchesResolvedBlockedEndpoint(
        address rawAddress: String?,
        port: Int?,
        policyRevision: UInt64
    ) -> Bool {
        guard var address = rawAddress?.lowercased(),
              let port,
              MacFilterInterceptionPlan.correlatedWebPorts.contains(port) else { return false }
        if address.hasPrefix("[") { address.removeFirst() }
        if address.hasSuffix("]") { address.removeLast() }
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return correlatedBlockedRevision == policyRevision
            && correlatedBlockedAddresses.contains(address)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let policy = currentPolicy()
        let now = Date()
        let resolvesSourceIdentity = policy.hasActiveMacApplicationRestrictions(at: now)
        var didRequestSourceIdentity = resolvesSourceIdentity
        var descriptor = self.descriptor(
            for: flow,
            resolveSourceIdentity: resolvesSourceIdentity
        )

        // Measures how the framework actually honours `peekOutboundBytes`:
        // whether it delivers whatever the client wrote, or waits for the full
        // request. The answer decides how much a ClientHello peek can safely
        // ask for. Scoped to one port so no real traffic can be affected.
        if FilterProbe.isEnabled, descriptor.remotePort == FilterProbe.port {
            logger.notice("PROBE new flow port \(FilterProbe.port, privacy: .public) peek \(FilterProbe.peekBytes, privacy: .public)")
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: FilterProbe.peekBytes
            )
        }
        if FilterProbe.isEnabled, FilterProbe.probeOnly { return .allow() }

        let matchesBlockedEndpoint = blockedEndpointCache.contains(
            address: descriptor.remoteAddress,
            port: descriptor.remotePort,
            policyRevision: policy.revision,
            at: now
        ) || matchesResolvedBlockedEndpoint(
            address: descriptor.remoteAddress,
            port: descriptor.remotePort,
            policyRevision: policy.revision
        )
        var outcome = WebFilterFlowDecider.outcome(
            for: descriptor,
            policy: policy,
            at: now,
            matchesRecentlyBlockedEndpoint: matchesBlockedEndpoint,
            inspectUnnamedWebFlows: true
        )
        // Usually no process lookup is necessary. Only a web flow we would
        // otherwise drop can need the OS captive-login exception. Resolve its
        // audit-token owner once per process (cached), never every allowed
        // browser connection. A public portal IP can be returned by captive
        // DNS for a blocked domain, so this must precede the final retry drop.
        if outcome.decision == .drop, !resolvesSourceIdentity,
           MacCaptivePortalPolicy.isAuthenticationTransport(descriptor),
           !policy.blocksDomainExplicitly(descriptor.hostname ?? "", at: now) {
            didRequestSourceIdentity = true
            resolveSource(of: flow, into: &descriptor)
            outcome = WebFilterFlowDecider.outcome(
                for: descriptor,
                policy: policy,
                at: now,
                matchesRecentlyBlockedEndpoint: matchesBlockedEndpoint,
                inspectUnnamedWebFlows: true
            )
        }
        diagnostics.recordSourceIdentityResolution(
            requested: didRequestSourceIdentity, revision: policy.revision, at: now
        )
        diagnostics.recordDecision(
            stage: .newFlow,
            outcome: outcome,
            descriptor: descriptor,
            revision: policy.revision
        )
        switch outcome.decision {
        case .allow:
            return .allow()
        case .drop:
            rememberEndpointIfNamedDrop(outcome, descriptor: descriptor, policy: policy, at: now)
            noteDrop(
                outcome.dropKind,
                reason: outcome.reason,
                stage: .newFlow,
                descriptor: descriptor,
                policy: policy
            )
            return .drop()
        case let .inspect(peekBytes):
            // The data callback either resolves the payload or, for a declared
            // partial TLS record, requests the exact larger prefix needed to
            // classify the ClientHello.
            beginInspection(
                of: flow,
                descriptor: descriptor,
                revision: policy.revision
            )
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: peekBytes
            )
        }
    }

    override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        let policy = currentPolicy()
        let now = Date()
        let descriptor = self.descriptor(
            for: flow,
            resolveSourceIdentity: policy.hasActiveMacApplicationRestrictions(at: now)
        )

        if FilterProbe.isEnabled, descriptor.remotePort == FilterProbe.port {
            logger.notice("PROBE outbound data offset \(offset, privacy: .public) bytes \(readBytes.count, privacy: .public)")
            return .allow()
        }

        guard descriptor.isTCP else {
            diagnostics.recordCallbackWithoutInspectionState(
                descriptor: descriptor,
                revision: policy.revision,
                offset: offset,
                bytes: readBytes.count
            )
            _ = finishInspection(of: flow)
            return .allow()
        }

        // An empty, out-of-order, overlapping, or replayed callback means this
        // filter cannot safely account for `passBytes`. Release it; a stream
        // sequencing ambiguity is not evidence that the destination is blocked.
        let callback: InspectionCallback
        switch accumulate(readBytes, at: offset, for: flow) {
        case let .success(value):
            callback = value
        case let .failure(error):
            diagnostics.recordInvalidSequence(
                error,
                descriptor: descriptor,
                revision: policy.revision,
                offset: offset,
                bytes: readBytes.count
            )
            let transport = descriptor.isTCP ? "tcp" : "udp"
            let portClass = WebFilterDiagnosticPortClass(port: descriptor.remotePort).rawValue
            logger.error(
                "inspection_invalid_sequence revision=\(policy.revision, privacy: .public) error=\(error.rawValue, privacy: .public) offset=\(offset, privacy: .public) chunk_bytes=\(readBytes.count, privacy: .public) transport=\(transport, privacy: .public) port_class=\(portClass, privacy: .public) action=allow"
            )
            _ = finishInspection(of: flow)
            return .allow()
        }

        let outcome = WebFilterFlowDecider.outcome(
            forOutboundBytes: callback.state.prefix,
            flow: descriptor,
            policy: policy,
            at: now
        )
        diagnostics.recordDecision(
            stage: .outboundData,
            outcome: outcome,
            descriptor: descriptor,
            revision: policy.revision,
            bytes: readBytes.count,
            accumulatedBytes: callback.state.prefix.count,
            offset: offset,
            overlapBytes: callback.append.overlapBytes
        )
        switch outcome.decision {
        case .drop:
            rememberEndpointIfNamedDrop(outcome, descriptor: descriptor, policy: policy, at: now)
            noteDrop(
                outcome.dropKind,
                reason: outcome.reason,
                stage: .outboundData,
                descriptor: descriptor,
                policy: policy
            )
            _ = finishInspection(of: flow)
            return .drop()
        case let .inspect(peekBytes):
            // `peekBytes` from the parser is an absolute prefix requirement.
            // Network Extension's verdict is relative to the bytes passed in
            // this callback. Passing the current incomplete suffix lets the
            // client continue writing; the callback that finally identifies a
            // blocked name is dropped without passing that completing suffix.
            let continuation: WebFilterStreamingContinuation
            switch continueInspection(of: flow, requiredPrefixBytes: peekBytes) {
            case let .success(value):
                continuation = value
            case let .failure(error):
                diagnostics.recordInvalidSequence(
                    error,
                    descriptor: descriptor,
                    revision: policy.revision,
                    offset: offset,
                    bytes: readBytes.count
                )
                logger.error(
                    "inspection_invalid_requirement revision=\(policy.revision, privacy: .public) error=\(error.rawValue, privacy: .public) offset=\(offset, privacy: .public) chunk_bytes=\(readBytes.count, privacy: .public) accumulated_bytes=\(callback.state.prefix.count, privacy: .public) required_prefix_bytes=\(peekBytes, privacy: .public) action=allow"
                )
                _ = finishInspection(of: flow)
                return .allow()
            }
            diagnostics.recordStreamingContinuation(
                descriptor: descriptor,
                revision: policy.revision,
                offset: offset,
                bytes: readBytes.count,
                accumulatedBytes: callback.state.prefix.count,
                passedBytes: continuation.passBytes,
                requestedBytes: continuation.peekBytes,
                overlapBytes: callback.append.overlapBytes
            )
            logger.debug(
                "flow_decision stage=outbound_data verdict=inspect reason=\(outcome.reason.rawValue, privacy: .public) revision=\(policy.revision, privacy: .public) offset=\(offset, privacy: .public) chunk_bytes=\(readBytes.count, privacy: .public) accumulated_bytes=\(callback.state.prefix.count, privacy: .public) passed_through_offset=\(continuation.passedThroughOffset, privacy: .public) pass_bytes=\(continuation.passBytes, privacy: .public) peek_bytes=\(continuation.peekBytes, privacy: .public)"
            )
            return NEFilterDataVerdict(
                passBytes: continuation.passBytes,
                peekBytes: continuation.peekBytes
            )

        case .allow:
            logger.debug(
                "flow_decision stage=outbound_data verdict=allow reason=\(outcome.reason.rawValue, privacy: .public) revision=\(policy.revision, privacy: .public) accumulated_bytes=\(callback.state.prefix.count, privacy: .public) passed_through_offset=\(callback.state.passedThroughOffset, privacy: .public)"
            )
            _ = finishInspection(of: flow)
            return .allow()
        }
    }

    /// The outbound stream ended while the flow was still unclassified.
    ///
    /// This used to re-run the *new flow* decision and treat its `.inspect`
    /// result as a drop, which killed every held flow that never produced a
    /// readable ClientHello. `decisionAtOutboundCompletion` drops only what is
    /// positively identified as blocked; see its documentation for why the
    /// previous behaviour was the primary cause of intermittent total outages.
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        let policy = currentPolicy()
        let now = Date()
        let descriptor = self.descriptor(
            for: flow,
            resolveSourceIdentity: policy.hasActiveMacApplicationRestrictions(at: now)
        )
        let inspection = finishInspection(of: flow)
        if inspection == nil {
            diagnostics.recordCompletionWithoutInspectionState(revision: policy.revision)
            logger.debug(
                "flow_completion_without_inspection_state revision=\(policy.revision, privacy: .public)"
            )
        }
        let outcome = WebFilterFlowDecider.decisionAtOutboundCompletion(
            for: descriptor,
            policy: policy,
            at: now
        )
        diagnostics.recordDecision(
            stage: .outboundComplete,
            outcome: outcome,
            descriptor: descriptor,
            revision: policy.revision
        )
        if let inspection,
           outcome.reason == .completionUnclassifiedAllowed
            || outcome.reason == .completionUnclassifiedFortressBlocked {
            diagnostics.recordUnclassifiedCompletion(
                descriptor: descriptor,
                revision: policy.revision,
                bytes: inspection.prefix.count,
                continuations: inspection.callbacks,
                reason: outcome.reason
            )
            let verdict = outcome.decision == .drop ? "drop" : "allow"
            logger.debug(
                "flow_terminal_unclassified verdict=\(verdict, privacy: .public) reason=\(outcome.reason.rawValue, privacy: .public) revision=\(policy.revision, privacy: .public) accumulated_bytes=\(inspection.prefix.count, privacy: .public) passed_through_offset=\(inspection.passedThroughOffset, privacy: .public) callbacks=\(inspection.callbacks, privacy: .public)"
            )
        }
        switch outcome.decision {
        case .drop:
            rememberEndpointIfNamedDrop(outcome, descriptor: descriptor, policy: policy, at: now)
            noteDrop(
                outcome.dropKind,
                reason: outcome.reason,
                stage: .outboundComplete,
                descriptor: descriptor,
                policy: policy
            )
            return .drop()
        case .allow, .inspect:
            return .allow()
        }
    }

    /// Feeds the safety valve and logs the transition exactly once.
    private func rememberEndpointIfNamedDrop(
        _ outcome: WebFilterFlowOutcome,
        descriptor: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at now: Date
    ) {
        guard outcome.dropKind == .named else { return }
        blockedEndpointCache.record(
            address: descriptor.remoteAddress,
            port: descriptor.remotePort,
            policyRevision: policy.revision,
            at: now
        )
    }

    private func noteDrop(
        _ kind: WebFilterDropKind?,
        reason: WebFilterDecisionReason,
        stage: WebFilterDiagnosticStage,
        descriptor: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy
    ) {
        let kind = kind ?? .unidentified
        let kindDescription = String(describing: kind)
        let transport = descriptor.isTCP ? "tcp" : "udp"
        let portClass = WebFilterDiagnosticPortClass(port: descriptor.remotePort).rawValue
        let hasHostname = descriptor.hostname?.isEmpty == false
        logger.debug(
            "flow_decision stage=\(stage.rawValue, privacy: .public) verdict=drop kind=\(kindDescription, privacy: .public) reason=\(reason.rawValue, privacy: .public) revision=\(policy.revision, privacy: .public) transport=\(transport, privacy: .public) port_class=\(portClass, privacy: .public) hostname_present=\(hasHostname, privacy: .public)"
        )
        if failOpen.record(kind) {
            diagnostics.recordDropPressureWarning(revision: policy.revision)
            logger.error(
                "drop_pressure_warning revision=\(policy.revision, privacy: .public) threshold=\(WebFilterFailOpenGovernor.defaultThreshold, privacy: .public) action=preserve-enforcement-offer-passage-disable"
            )
        }
    }

    private func currentPolicy() -> DesktopEnforcementPolicy {
        let now = Date()
        let basePolicy = loadBasePolicy(at: now)
        let policy = effectivePolicy(from: basePolicy, at: now)
        // No allocation or disk I/O unless the revision actually changed.
        statusPublisher.recordIfRevisionChanged(policy.revision)
        return policy
    }

    private func loadCurrentPolicy(at now: Date = Date()) -> DesktopEnforcementPolicy {
        effectivePolicy(from: loadBasePolicy(at: now), at: now)
    }

    private func loadBasePolicy(at now: Date = Date()) -> DesktopEnforcementPolicy {
        policyLoader.current(
            vendorConfiguration: filterConfiguration.vendorConfiguration,
            now: now
        )
    }

    /// Reads the root-owned request document only from provider lifecycle or
    /// settings-refresh work, validates each request against the authenticated
    /// base policy, and publishes a small in-memory snapshot for flow callbacks.
    @discardableResult
    private func refreshTemporaryPauses(
        for basePolicy: DesktopEnforcementPolicy,
        at now: Date
    ) -> DesktopEnforcementPolicy {
        var expirations: [UUID: Date] = [:]
        var history: [BypassEvent] = []
        do {
            expirations = basePolicy.validatedTemporaryPauseExpirations(
                from: try temporaryPauseStore.activePauses(at: now),
                at: now
            )
            history = try temporaryPauseStore.bypassEvents(at: now)
        } catch {
            let error = error as NSError
            logger.error(
                "temporary_pause_read_failed revision=\(basePolicy.revision, privacy: .public) error_domain=\(error.domain, privacy: .public) error_code=\(error.code, privacy: .public) action=fail_closed"
            )
        }

        settingsLock.lock()
        var recordedIDs = Set(browserBypassEvents.map(\.id))
        browserBypassEvents += history.filter { $0.isValid && recordedIDs.insert($0.id).inserted }
        browserBypassEvents.sort { $0.grantedAt < $1.grantedAt }
        browserBypassEvents = Array(browserBypassEvents.suffix(1_000))
        let changed = temporaryPausePolicyRevision != basePolicy.revision
            || temporaryPauseExpirations != expirations
        temporaryPausePolicyRevision = basePolicy.revision
        temporaryPauseExpirations = expirations
        settingsLock.unlock()

        if changed {
            blockedEndpointCache.removeAll()
            logger.notice(
                "temporary_pause_state_changed revision=\(basePolicy.revision, privacy: .public) active_rules=\(expirations.count, privacy: .public)"
            )
        }
        return basePolicy.excludingTemporarilyPausedRules(Set(expirations.keys))
    }

    private func effectivePolicy(
        from basePolicy: DesktopEnforcementPolicy,
        at now: Date
    ) -> DesktopEnforcementPolicy {
        settingsLock.lock()
        let pausedRuleIDs: Set<UUID>
        if temporaryPausePolicyRevision == basePolicy.revision {
            pausedRuleIDs = Set(
                temporaryPauseExpirations.compactMap { entry in
                    entry.value > now ? entry.key : nil
                }
            )
        } else {
            pausedRuleIDs = []
        }
        settingsLock.unlock()
        return basePolicy.excludingTemporarilyPausedRules(pausedRuleIDs)
    }

    private func beginInspection(
        of flow: NEFilterFlow,
        descriptor: WebFilterFlowDescriptor,
        revision: UInt64
    ) {
        inspectionLock.lock()
        // A flow the framework never finishes leaves its entry behind, so the
        // table is capped rather than trusted to drain. Dropping tracking state
        // only costs classification accuracy on flows already in flight; it
        // never drops traffic, because a missing prefix starts empty again.
        let discarded = inspections.count >= Self.maximumTrackedFlows
            ? inspections.count
            : 0
        if discarded > 0 {
            inspections.removeAll(keepingCapacity: true)
        }
        inspections[ObjectIdentifier(flow)] = Inspection()
        if discarded > 0 {
            diagnostics.recordInspectionTableReset(
                revision: revision,
                discarded: discarded
            )
        }
        // Keep the diagnostic gauge serialized with its authoritative table.
        // No code ever acquires these locks in the opposite order.
        diagnostics.inspectionStarted()
        inspectionLock.unlock()
        if discarded > 0 {
            let transport = descriptor.isTCP ? "tcp" : "udp"
            logger.error(
                "inspection_table_reset revision=\(revision, privacy: .public) capacity=\(Self.maximumTrackedFlows, privacy: .public) discarded=\(discarded, privacy: .public) transport=\(transport, privacy: .public)"
            )
        }
    }

    private func accumulate(
        _ readBytes: Data,
        at offset: Int,
        for flow: NEFilterFlow
    ) -> Result<InspectionCallback, WebFilterStreamingSequenceError> {
        inspectionLock.lock()
        defer { inspectionLock.unlock() }
        let key = ObjectIdentifier(flow)
        guard var state = inspections[key] else {
            return .failure(.staleState)
        }
        switch state.append(readBytes, at: offset) {
        case let .failure(error):
            return .failure(error)
        case let .success(append):
            inspections[key] = state
            return .success(InspectionCallback(state: state, append: append))
        }
    }

    private func continueInspection(
        of flow: NEFilterFlow,
        requiredPrefixBytes: Int
    ) -> Result<WebFilterStreamingContinuation, WebFilterStreamingSequenceError> {
        inspectionLock.lock()
        defer { inspectionLock.unlock() }
        let key = ObjectIdentifier(flow)
        guard var state = inspections[key] else { return .failure(.staleState) }
        switch state.continueInspection(requiredPrefixBytes: requiredPrefixBytes) {
        case let .failure(error):
            return .failure(error)
        case let .success(continuation):
            inspections[key] = state
            return .success(continuation)
        }
    }

    @discardableResult
    private func finishInspection(of flow: NEFilterFlow) -> Inspection? {
        inspectionLock.lock()
        let state = inspections.removeValue(forKey: ObjectIdentifier(flow))
        if state != nil { diagnostics.inspectionFinished() }
        inspectionLock.unlock()
        return state
    }

    private func descriptor(
        for flow: NEFilterFlow,
        resolveSourceIdentity: Bool
    ) -> WebFilterFlowDescriptor {
        var descriptor = WebFilterFlowDescriptor(
            hostname: flow.url?.host,
            remotePort: MacCaptivePortalPolicy.webPort(for: flow.url)
        )
        // macOS supplies an audit token rather than iOS's bundle identifier.
        // Resolve only for application restrictions or the lazy captive-login
        // check on an otherwise-denied authentication flow.
        if resolveSourceIdentity {
            resolveSource(of: flow, into: &descriptor)
        }
        guard let socketFlow = flow as? NEFilterSocketFlow else { return descriptor }

        if descriptor.hostname?.isEmpty != false {
            descriptor.hostname = socketFlow.remoteHostname
        }
        descriptor.isTCP = socketFlow.socketProtocol == IPPROTO_TCP
        let endpoint = remoteEndpoint(of: socketFlow)
        descriptor.remoteAddress = endpoint.address
        descriptor.remotePort = endpoint.port ?? descriptor.remotePort
        return descriptor
    }

    private func resolveSource(of flow: NEFilterFlow, into descriptor: inout WebFilterFlowDescriptor) {
        guard let identity = sourceResolver.identity(forAuditToken: flow.sourceAppAuditToken) else { return }
        descriptor.sourceSigningIdentifier = identity.signingIdentifier
        descriptor.sourceExecutablePath = identity.executablePath
        descriptor.sourceIsVerifiedCaptivePortalComponent = identity.isVerifiedCaptivePortalComponent
    }

    private func remoteEndpoint(of flow: NEFilterSocketFlow) -> (address: String?, port: Int?) {
        if #available(macOS 15.0, *) {
            guard let endpoint = flow.remoteFlowEndpoint,
                  case let .hostPort(host, port) = endpoint else { return (nil, nil) }
            let address: String? = switch host {
            case let .ipv4(value): "\(value)"
            case let .ipv6(value): "\(value)"
            case let .name(name, _): name
            @unknown default: nil
            }
            return (address, Int(port.rawValue))
        }
        // macOS 14 is still supported. Returning nil here previously prevented
        // both local-network classification and any port-scoped exception.
        guard let endpoint = flow.__remoteEndpoint as? __NWHostEndpoint else { return (nil, nil) }
        return (endpoint.hostname, Int(endpoint.port))
    }
}
