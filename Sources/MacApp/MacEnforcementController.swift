import Darwin
import Foundation
@preconcurrency import NetworkExtension
import OSLog
import SystemExtensions

private enum MacEnforcementLog {
    static let lifecycle = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "system-extension"
    )
    static let delivery = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "policy-delivery"
    )
    static let sameBootReset = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction",
        category: "same-boot-reset"
    )
}

private enum NetworkFilterConfigurationTrigger: String, Sendable {
    case policyUpdate = "policy-update"
    case healthRedelivery = "health-redelivery"
    case activationCompleted = "activation-completed"
}

private enum NetworkFilterDeliveryStage: String, Sendable {
    case loadPreferences = "load-preferences"
    case savePreferences = "save-preferences"
}

private struct SystemExtensionLogContext: Sendable {
    var operationID: String
    var action: String
    var trigger: String
    var configurationTrigger: NetworkFilterConfigurationTrigger?
    var startedAt: Date
    var stateGeneration: UInt64
    var preferenceGeneration: UInt64? = nil
}

private struct SystemExtensionPropertyObservation: Sendable {
    var bundleIdentifier: String
    var bundleVersion: String
    var isEnabled: Bool
    var isAwaitingUserApproval: Bool
    var isUninstalling: Bool
}

/// `vendorConfiguration` accepts a property-list dictionary whose concrete
/// values are `Data` and `NSNumber`. This carrier is immutable after encoding;
/// the unchecked conformance is narrowly scoped to crossing NetworkExtension's
/// legacy callback boundary without making the policy itself global mutable
/// state.
private struct ImmutableVendorConfiguration: @unchecked Sendable {
    let value: [String: Any]
}

private enum FilterPreferenceGoal: Sendable {
    case enabled(
        revision: UInt64,
        vendorConfiguration: ImmutableVendorConfiguration,
        trigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64,
        preparationGeneration: UInt64,
        preparationCompletion: MacFilterPreparationCompletion,
        retry: Int
    )
    /// Every activation begins by serially proving the existing Network
    /// Extension preference is disabled. This prevents a provider-less enabled
    /// preference from remaining live while sysextd waits for approval or
    /// reports the installed extension's state.
    case disabledForActivation(
        trigger: String,
        configurationTrigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64,
        retry: Int
    )
    /// A short, availability-first handoff before resolving public retry-guard
    /// addresses. Stopping the old provider makes the root block-page daemon
    /// release its `/etc/hosts` loopback mappings, so preflight cannot mistake
    /// 127.0.0.1 for the blocked site's real endpoint.
    case suspendedForPreparation(
        revision: UInt64,
        trigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64,
        retry: Int
    )
    case disabled(trigger: String, retry: Int)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var revision: UInt64 {
        switch self {
        case let .enabled(revision, _, _, _, _, _, _): revision
        case let .suspendedForPreparation(revision, _, _, _): revision
        case .disabledForActivation, .disabled: 0
        }
    }

    var retry: Int {
        switch self {
        case let .enabled(_, _, _, _, _, _, retry), let .disabled(_, retry): retry
        case let .disabledForActivation(_, _, _, retry): retry
        case let .suspendedForPreparation(_, _, _, retry): retry
        }
    }

    var triggerDescription: String {
        switch self {
        case let .enabled(_, _, trigger, _, _, _, _): trigger.rawValue
        case let .disabledForActivation(trigger, _, _, _): trigger
        case let .suspendedForPreparation(_, trigger, _, _): trigger.rawValue
        case let .disabled(trigger, _): trigger
        }
    }

    var isExplicitDisable: Bool {
        if case .disabled = self { return true }
        return false
    }

    var isPreparationSuspension: Bool {
        if case .suspendedForPreparation = self { return true }
        return false
    }

    var activationGeneration: UInt64? {
        switch self {
        case let .enabled(_, _, _, activationGeneration, _, _, _),
             let .disabledForActivation(_, _, activationGeneration, _),
             let .suspendedForPreparation(_, _, activationGeneration, _):
            activationGeneration
        case .disabled:
            nil
        }
    }

    var preparationGeneration: UInt64? {
        if case let .enabled(_, _, _, _, preparationGeneration, _, _) = self {
            return preparationGeneration
        }
        return nil
    }

    func retrying(_ retry: Int) -> FilterPreferenceGoal {
        switch self {
        case let .enabled(
            revision,
            vendorConfiguration,
            trigger,
            activationGeneration,
            preparationGeneration,
            preparationCompletion,
            _
        ):
            .enabled(
                revision: revision,
                vendorConfiguration: vendorConfiguration,
                trigger: trigger,
                activationGeneration: activationGeneration,
                preparationGeneration: preparationGeneration,
                preparationCompletion: preparationCompletion,
                retry: retry
            )
        case let .disabledForActivation(
            trigger,
            configurationTrigger,
            activationGeneration,
            _
        ):
            .disabledForActivation(
                trigger: trigger,
                configurationTrigger: configurationTrigger,
                activationGeneration: activationGeneration,
                retry: retry
            )
        case let .suspendedForPreparation(revision, trigger, activationGeneration, _):
            .suspendedForPreparation(
                revision: revision,
                trigger: trigger,
                activationGeneration: activationGeneration,
                retry: retry
            )
        case let .disabled(trigger, _):
            .disabled(trigger: trigger, retry: retry)
        }
    }
}

private struct PendingFinalEnableVerification {
    var requestOperationID: String
    var mutation: FilterPreferenceMutation
    var manager: NEFilterManager
    var preferenceOperationID: String
    var preferenceStartedAt: Date
}

private struct FilterPreferenceMutation: Sendable {
    var generation: UInt64
    var goal: FilterPreferenceGoal
    var baselineProviderSessionID: String? = nil
}

extension FilterPreferenceMutation: GenerationStamped {}

private struct SameBootResetHTTPSObservation: Sendable {
    var isHealthy: Bool
    var statusCode: Int?
    var errorDomain: String?
    var errorCode: Int?
}

/// Delegate callbacks arrive on the request queue rather than the main actor.
/// Keep only opaque correlation metadata here; no policy or browsing data ever
/// crosses this boundary.
private final class SystemExtensionLogRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [ObjectIdentifier: SystemExtensionLogContext] = [:]

    func register(_ context: SystemExtensionLogContext, for request: OSSystemExtensionRequest) {
        lock.lock()
        contexts[ObjectIdentifier(request)] = context
        lock.unlock()
    }

    func context(for request: OSSystemExtensionRequest) -> SystemExtensionLogContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[ObjectIdentifier(request)]
    }

    func remove(for request: OSSystemExtensionRequest) -> SystemExtensionLogContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts.removeValue(forKey: ObjectIdentifier(request))
    }
}

private let systemExtensionLogRegistry = SystemExtensionLogRegistry()

private func diagnosticOperationID() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

private func diagnosticElapsedMilliseconds(since start: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(start) * 1_000))
}

@MainActor
final class MacEnforcementController: NSObject, ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case activating
        case awaitingApproval
        case active
        case disabling
        case disabled
        case rebootRequired
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled: "Not installed"
            case .activating: "Installing system enforcement…"
            case .awaitingApproval: "Approval required in System Settings"
            case .active: "Local enforcement active"
            case .disabling: "Disabling web blocking…"
            case .disabled: "Web blocking disabled"
            case .rebootRequired: "Restart required"
            case let .failed(message): "Enforcement error: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .notInstalled
    /// Where a pending uninstall stands. Published so the countdown is visible
    /// rather than hidden: a removal the user has forgotten about is one they
    /// cannot reconsider.
    @Published private(set) var removalState: DesktopRemovalGate.State = .notRequested
    /// The last policy that failed to reach the filter, if any. Kept apart from
    /// `status` so a delivery fault is visible without being mistaken for a
    /// failed installation.
    @Published private(set) var deliveryError: String?
    @Published private(set) var recoveryWarning: String?
    @Published private(set) var enforcementPreparationMessage: String?
    private var recoveryWarnings: [String: String] = [:]
    /// External (System Settings) disable tracking; see ExternalFilterToggleGate.
    private var externalToggleObserver: NSObjectProtocol?
    private var externalToggleObservedOffAt: Date?
    private var externalToggleRecheckTask: Task<Void, Never>?

    /// Diagnostic failures are not authorization to pause every rule.
    func reportRecoveryWarning(trigger: String, message: String) {
        guard !isBlockingDisabled, !isRemoving else { return }
        guard recoveryWarnings[trigger] != message else { return }
        recoveryWarnings[trigger] = message
        recoveryWarning = recoveryWarnings.keys.sorted().compactMap { recoveryWarnings[$0] }.joined(separator: "\n")
        DesktopDiagnosticTrace.record(component: "enforcement", event: "recovery_warning", fields: [
            "trigger": trigger, "action": "preserve-enforcement-offer-passage-disable"
        ])
    }

    func clearRecoveryWarning(trigger: String) {
        guard recoveryWarnings.removeValue(forKey: trigger) != nil else { return }
        recoveryWarning = recoveryWarnings.isEmpty ? nil : recoveryWarnings.keys.sorted().compactMap { recoveryWarnings[$0] }.joined(separator: "\n")
        DesktopDiagnosticTrace.record(component: "enforcement", event: "recovery_warning_cleared", fields: ["trigger": trigger])
    }
    /// Emergency pause state. Persisted so relaunching the app cannot silently
    /// re-enable a filter the user disabled to recover connectivity.
    @Published private(set) var isBlockingDisabled: Bool
    /// Set after a startup/health failure that may have interrupted all traffic.
    /// It clears automatically after a restart, or after the bounded same-boot
    /// recovery proves the preference absent and ordinary connectivity healthy.
    @Published private(set) var activationSafetyRequiresRestart: Bool
    @Published private(set) var activationSafetyReason: String?
    /// Same-boot recovery never enables filtering. It removes and verifies the
    /// preference, proves connectivity repeatedly, and clears only our latch.
    @Published private(set) var isResettingEnforcement = false
    @Published private(set) var enforcementResetStatus: String?
    /// Written immediately before an enabled preference can be committed. If
    /// this process exits before a ready heartbeat clears it, the next launch
    /// interprets the record as an interrupted unsafe activation and stays off.
    private var hasPersistedActivationAttempt = false
    private let requestQueue = DispatchQueue(label: "com.GabrielPrice.ExecutiveDysfunction.system-extension-requests")
    /// Exposed read-only so the banner can replace all mutation buttons with a
    /// single progress/restart message while deactivation is outstanding.
    private(set) var isRemoving = false
    var isProviderStartupTransitionInProgress: Bool {
        if startupWatchdogAttempt != nil || deferredStartupWatchdogAttempt != nil {
            return true
        }
        switch status {
        case .activating, .awaitingApproval:
            return true
        default:
            return false
        }
    }
    private var latestPolicy = DesktopEnforcementPolicy.empty
    private var lastDeliveryAttempt = Date.distantPast
    private var redeliveryAttempts = 0
    private var didLogRedeliveryCap = false
    private var configurationOperations: Set<String> = []
    /// Network Extension preferences expose asynchronous load/save calls but no
    /// cancellation. Keeping one mutation in flight ensures an old enable can
    /// never commit after a newer emergency disable without the disable being
    /// applied last. New requests replace `pendingPreferenceMutation` with the
    /// latest desired state.
    private var preferenceQueue = GenerationalMutationQueue<FilterPreferenceMutation>()
    /// Views onto `preferenceQueue`, kept under their original names so every
    /// existing call site behaves exactly as before the extraction.
    private var preferenceGeneration: UInt64 {
        get { preferenceQueue.generation }
        set { preferenceQueue.generation = newValue }
    }
    private var desiredStateGeneration: UInt64 = 0
    private var activePreferenceMutation: FilterPreferenceMutation? {
        get { preferenceQueue.active }
        set { preferenceQueue.active = newValue }
    }
    private var pendingPreferenceMutation: FilterPreferenceMutation? {
        get { preferenceQueue.pending }
        set { preferenceQueue.pending = newValue }
    }
    private var preferenceMutationDeadlineTask: Task<Void, Never>?
    private var preferenceMutationDeadlineGeneration: UInt64?
    private var isBreakGlassRemovalInFlight = false
    private var breakGlassRemovalOperationID: String?
    private var breakGlassRemovalDeadlineTask: Task<Void, Never>?
    private var pendingActivationTrigger: String?
    private var activationRequestGeneration: UInt64?
    /// Typed proofs are authority for exactly one desired-state generation. Any
    /// newer policy, disable, or removal request invalidates the whole chain.
    private var activationAttempt: MacFilterActivationAttempt?
    private var disabledPreferenceProof: MacFilterDisabledPreferenceProof?
    private var initialPropertiesProof: MacFilterExactBuildPropertiesProof?
    /// Holds an already-loaded manager while a just-in-time properties request
    /// proves the exact provider build is still enabled. No enabled preference
    /// fields are changed before this request succeeds.
    private var pendingFinalEnableVerification: PendingFinalEnableVerification?
    /// An enabled save that times out or reports a write failure is an uncertain
    /// commit: NetworkExtension may still apply it after the callback deadline.
    /// Keep checking/removing the preference for a bounded grace window while
    /// the same-boot activation latch prevents any legitimate re-enable.
    private var lateEnablePreferenceQuarantine: MacFilterLateEnableQuarantineState?
    /// This generation belongs to the quarantine itself. It must not follow
    /// `preferenceGeneration` or `desiredStateGeneration`: a button press or a
    /// late callback cannot be allowed to invalidate an uncertain-save guard.
    private var lateEnableQuarantineGeneration: UInt64 = 0
    private var lateEnableQuarantineTimedOutPreferenceGeneration: UInt64?
    private var lateEnableQuarantineTask: Task<Void, Never>?
    private var lateEnableQuarantineProbeOperationID: String?
    private var lateEnableQuarantineProbeAttemptSequence: UInt64?
    private var lateEnableQuarantineProbeDeadlineTask: Task<Void, Never>?
    /// `saveToPreferences` has no cancellation API. Keep enabled saves visible
    /// even if a newer break-glass removal succeeds and clears the ordinary
    /// mutation lane; reset cannot call that state settled until the callback or
    /// the bounded late-enable quarantine's final sweep resolves it.
    private var outstandingEnabledPreferenceSaveOperations: [String: UInt64] = [:]
    /// Reset operations have their own generation and operation identity. NE
    /// callbacks cannot be cancelled, so both are required to reject a late
    /// callback from a previous reset attempt.
    private var sameBootResetGeneration: UInt64 = 0
    private var sameBootResetAttemptIdentifier: String?
    private var sameBootResetState: MacFilterSameBootResetState?
    private var sameBootResetCleanupTask: Task<Void, Never>?
    private var sameBootResetPreferenceOperationID: String?
    private var sameBootResetPreferenceDeadlineTask: Task<Void, Never>?
    private var sameBootResetConnectivityTask: Task<Void, Never>?
    private var sameBootResetDNSResolutionTask: MacFilterDNSResolutionTask?
    private var sameBootResetConnectivityProbeIdentity:
        MacFilterSameBootResetConnectivityProbeIdentity?
    /// The preference is already confirmed off while sysextd activation and the
    /// first exact-build properties request run. This deadline prevents a lost
    /// callback from leaving the UI in a permanent activation transition.
    private var activationEvidenceDeadlineTask: Task<Void, Never>?
    private var activationEvidenceDeadlineGeneration: UInt64?
    /// A completed activation request may still report the exact build as
    /// `activated disabled` until the user enables it in System Settings. Poll
    /// properties inside the existing evidence deadline without ever enabling
    /// the Network Extension preference early.
    private var activationPropertiesRetryTask: Task<Void, Never>?
    private var activationPropertiesRetryGeneration: UInt64?
    private var deferredStartupWatchdogAttempt: MacFilterStartupWatchdogAttempt?
    private var startupWatchdogAttempt: MacFilterStartupWatchdogAttempt?
    private var startupWatchdogTask: Task<Void, Never>?
    /// Domain retry guards are prepared while the old configuration is still
    /// active (or while filtering is disabled). A provider must never need DNS
    /// in order to acknowledge `startFilter`, because Network Extension may
    /// already be holding the very DNS traffic that would answer that lookup.
    private let retryGuardResolver = MacFilterAsyncDomainResolver()
    private var retryGuardResolutionTask: MacFilterDNSResolutionTask?
    private var retryGuardPreparationRecoveryTask: Task<Void, Never>?
    private var retryGuardPreparationGeneration: UInt64 = 0
    /// A successful old provider configuration can carry a still-valid retry
    /// guard snapshot across an in-place app update. It is only ever used after
    /// exact-plan validation and never has its expiry extended.
    private var retainedRetryGuardSnapshot: MacFilterPreparedRetryGuardSnapshot?
    /// Removal first disables the filter preference, then deactivates the
    /// system extension. Submitting both requests together lets sysextd race
    /// the preference save and can leave filtering in an unknown state.
    private var pendingDeactivationAfterDisable = false
    private let removalStore: DesktopRemovalRequestPersisting
    private static let blockingDisabledKey =
        MacEnforcementSafetyPersistence.blockingDisabledKey
    private static let activationSafetyBootSessionKey =
        MacEnforcementSafetyPersistence.activationSafetyBootSessionKey
    private static let activationSafetyBootTimeKey =
        MacEnforcementSafetyPersistence.activationSafetyBootTimeKey
    private static let activationSafetyTriggeredAtKey =
        MacEnforcementSafetyPersistence.activationSafetyTriggeredAtKey
    private static let activationSafetyReasonKey =
        MacEnforcementSafetyPersistence.activationSafetyReasonKey

    init(removalStore: DesktopRemovalRequestPersisting = KeychainRemovalRequestStore()) {
        self.removalStore = removalStore
        let defaults = UserDefaults.standard
        let forcedDisable = CommandLine.arguments.contains("--disable-web-filter-now")
        let forcedUnsafeDisable = forcedDisable
            && CommandLine.arguments.contains("--mark-filter-startup-unsafe")
        let currentBootSessionIdentifier = Self.currentBootSessionIdentifier()
        let currentEstimatedBootTime = Self.currentEstimatedBootTime()
        if forcedUnsafeDisable {
            Self.persistActivationSafetyRecord(
                MacFilterActivationSafetyRecord(
                    bootSessionIdentifier: currentBootSessionIdentifier,
                    estimatedBootTime: currentEstimatedBootTime,
                    triggeredAt: Date(),
                    reason: "forced-emergency-disable"
                ),
                defaults: defaults
            )
        }
        var activationSafetyRecord = Self.readActivationSafetyRecord(defaults: defaults)
        let activationSafetyState = MacFilterActivationSafetyGate.state(
            record: activationSafetyRecord,
            currentBootSessionIdentifier: currentBootSessionIdentifier,
            currentEstimatedBootTime: currentEstimatedBootTime
        )
        if activationSafetyState == .restartObserved {
            Self.clearActivationSafetyRecord(defaults: defaults)
            activationSafetyRecord = nil
        }
        let requiresRestartForActivationSafety = activationSafetyState == .lockedUntilRestart
        activationSafetyRequiresRestart = requiresRestartForActivationSafety
        activationSafetyReason = requiresRestartForActivationSafety
            ? activationSafetyRecord?.reason
            : nil
        isBlockingDisabled = forcedDisable
            || defaults.bool(forKey: Self.blockingDisabledKey)
            || requiresRestartForActivationSafety
        if forcedDisable || requiresRestartForActivationSafety {
            defaults.set(true, forKey: Self.blockingDisabledKey)
        }
        super.init()
        DesktopDiagnosticTrace.record(
            component: "enforcement",
            event: "controller_initialized",
            fields: [
                "blocking_disabled": isBlockingDisabled,
                "activation_latched": activationSafetyRequiresRestart,
                "activation_reason": activationSafetyReason ?? "none",
                "forced_disable": forcedDisable
            ]
        )
        if isBlockingDisabled { status = .disabling }
        if activationSafetyRequiresRestart {
            MacEnforcementLog.lifecycle.fault(
                "Network Extension activation safety interlock active reason=\(self.activationSafetyReason ?? "unknown", privacy: .public) action=remain-disabled-until-restart-or-proven-reset"
            )
        } else if activationSafetyState == .restartObserved {
            MacEnforcementLog.lifecycle.notice(
                "Network Extension activation safety interlock cleared reason=restart-observed blockingRemainsDisabled=\(self.isBlockingDisabled, privacy: .public)"
            )
        }
        refreshRemovalState()
    }

    /// Delivery must not depend on `status`.
    ///
    /// It used to run only when `status == .active`, and `status` latches: a
    /// single failed save — a filter restart racing an activation is enough —
    /// left it on `.failed`, after which every later policy was dropped on the
    /// floor while the filter went on enforcing a stale snapshot. Observed
    /// live: the app published 203 while the filter enforced 199 for sixteen
    /// minutes, with the only symptom being new rules that quietly did nothing.
    ///
    /// A save attempted before the extension is approved simply fails and is
    /// retried, which is cheaper than the alternative failure.
    /// Saving is never free — see `redeliverPolicy` — so an unchanged policy
    /// must not reach `saveToPreferences`. This is a second line of defence
    /// behind the model's own check.
    func updatePolicy(_ policy: DesktopEnforcementPolicy) {
        let isUnchanged = policy.hasSameContent(as: latestPolicy) && latestPolicy.revision > 0
        latestPolicy = policy
        guard !isRemoving, !isBlockingDisabled, !isUnchanged else { return }
        redeliveryAttempts = 0
        didLogRedeliveryCap = false
        desiredStateGeneration &+= 1
        invalidateVerifiedActivation(reason: "policy-update")
        requestActivationBeforeEnablingPreferences(
            trigger: "policy-update",
            configurationTrigger: .policyUpdate
        )
    }

    /// Seeds the policy loaded from the authenticated shared file without
    /// writing Network Extension preferences. Launch reassertion performs the
    /// one intentional save after `MacAppModel` has compared iCloud state with
    /// this baseline.
    func seedLatestPolicyForLaunch(_ policy: DesktopEnforcementPolicy) {
        guard latestPolicy.revision == 0 else { return }
        latestPolicy = policy
    }

    /// Re-sends the newest policy when the filter reports a lower revision.
    ///
    /// A running `NEFilterDataProvider` reads `vendorConfiguration` as it stood
    /// when `startFilter` ran, so a policy only reaches it when the provider
    /// restarts — and saving the configuration is what restarts it. Saving is
    /// therefore both the delivery mechanism and the cost. Live tracing showed
    /// a roughly 302 ms default-drop window during provider startup. That brief
    /// window was not the sustained outage (held 16,640-byte classification
    /// peeks were), but repeated saves still create avoidable disruption.
    ///
    /// An earlier version cycled `isEnabled` off and on to force the restart,
    /// on a timer, whenever the filter looked behind. Because the app also
    /// republished on every iCloud notification, "behind" was near-permanent
    /// and the machine took a recurring total outage. That mechanism is gone;
    /// what remains is a small, capped number of plain re-saves.
    func redeliverPolicy() {
        guard !isRemoving, !isBlockingDisabled, latestPolicy.revision > 0 else { return }
        // A stale/behind heartbeat during our own DNS preparation must not
        // cancel the bounded recovery and start another disable/enable cycle.
        guard !isProviderStartupTransitionInProgress else { return }
        // Hard cap. Re-saving restarts the provider and live tracing measured a
        // roughly 302 ms default-drop window during startup. A retry loop driven
        // by a condition that can stay true indefinitely would repeatedly
        // interrupt traffic even though it cannot repair a held-flow defect.
        guard redeliveryAttempts < 3 else {
            if !didLogRedeliveryCap {
                didLogRedeliveryCap = true
                MacEnforcementLog.delivery.error(
                    "Automatic redelivery capped trigger=health-redelivery revision=\(self.latestPolicy.revision, privacy: .public) attempts=\(self.redeliveryAttempts, privacy: .public)"
                )
            }
            return
        }
        guard Date().timeIntervalSince(lastDeliveryAttempt) >= 30 else { return }
        redeliveryAttempts += 1
        desiredStateGeneration &+= 1
        invalidateVerifiedActivation(reason: "health-redelivery")
        requestActivationBeforeEnablingPreferences(
            trigger: "health-redelivery",
            configurationTrigger: .healthRedelivery
        )
    }

    /// Called when the filter is level with the app, so a later lag gets a
    /// fresh budget of retries.
    func noteDeliveryUpToDate() {
        redeliveryAttempts = 0
        didLogRedeliveryCap = false
    }

    func install() {
        guard !isResettingEnforcement,
              !activationSafetyRequiresRestart,
              lateEnableQuarantineAllowsEnabledPreference else {
            isBlockingDisabled = true
            UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
            status = .disabled
            deliveryError = isResettingEnforcement
                ? "The safe enforcement reset is still running. Blocking remains disabled."
                : "A previous Network Extension startup interrupted connectivity. Run Reset Enforcement Without Restart before trying to enable it again."
            MacEnforcementLog.delivery.fault(
                "Network Extension enable suppressed reason=activation-safety-interlock failure=\(self.activationSafetyReason ?? "unknown", privacy: .public) resetInProgress=\(self.isResettingEnforcement, privacy: .public) action=remain-disabled"
            )
            DesktopDiagnosticTrace.record(
                component: "enforcement",
                event: "enable_suppressed",
                fields: [
                    "reason": activationSafetyReason ?? "activation-safety-interlock",
                    "reset_in_progress": isResettingEnforcement,
                    "late_enable_quarantine_clear": lateEnableQuarantineAllowsEnabledPreference
                ]
            )
            return
        }
        guard !isBreakGlassRemovalInFlight else {
            deliveryError = "Emergency filter cleanup is still running. Web enforcement will remain disabled until it finishes or reaches its safety deadline."
            status = .disabling
            MacEnforcementLog.delivery.error(
                "Network Extension enable suppressed reason=break-glass-removal-in-flight op=\(self.breakGlassRemovalOperationID ?? "unknown", privacy: .public)"
            )
            return
        }
        cancelStartupWatchdog(reason: "install-requested")
        cancelRetryGuardPreparation(reason: "install-requested")
        desiredStateGeneration &+= 1
        invalidateVerifiedActivation(reason: "install-requested")
        isRemoving = false
        isBlockingDisabled = false
        UserDefaults.standard.set(false, forKey: Self.blockingDisabledKey)
        DesktopDiagnosticTrace.record(
            component: "enforcement",
            event: "enable_requested",
            fields: [
                "state_generation": desiredStateGeneration,
                "policy_revision": latestPolicy.revision
            ]
        )
        requestActivationBeforeEnablingPreferences(
            trigger: "install",
            configurationTrigger: .activationCompleted
        )
    }

    /// Re-submits the activation request every time the app launches, then
    /// verifies the registered extension is actually enabled before touching
    /// Network Extension preferences.
    ///
    /// Enforcement that waits for a button is enforcement the user can end by
    /// simply not pressing it. macOS treats a repeat activation from the same
    /// team as a silent upgrade, so this repairs an extension left behind at an
    /// older version. A system extension switched off in System Settings is not
    /// silently repaired: macOS can return `.completed` while leaving it
    /// disabled, so the properties request below must prove `isEnabled` first.
    ///
    /// Note that an activation request for a version that is *already*
    /// installed is a no-op — it does not restart the provider. Only a
    /// configuration save does that.
    func reassert() {
        guard !isRemoving,
              !isBlockingDisabled,
              !isResettingEnforcement,
              !activationSafetyRequiresRestart else { return }
        desiredStateGeneration &+= 1
        invalidateVerifiedActivation(reason: "launch-reassert")
        requestActivationBeforeEnablingPreferences(
            trigger: "launch-reassert",
            configurationTrigger: .activationCompleted
        )
    }

    /// Immediately disables traffic filtering without uninstalling the system
    /// extension. This recovery path deliberately has no delay or passage: a
    /// filter that has taken the machine offline must always have an escape
    /// hatch that works now. The choice persists across app launches.
    func disableBlockingImmediately(
        trigger: String = "manual-emergency-disable",
        requireRestartBeforeReenable: Bool = false
    ) {
        if isResettingEnforcement,
           let attemptIdentifier = sameBootResetAttemptIdentifier {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: sameBootResetGeneration,
                message: "The enforcement reset was interrupted by another disable request. Blocking remains disabled; you can retry the reset."
            )
        }
        if requireRestartBeforeReenable {
            latchActivationSafetyUntilRestart(reason: trigger)
        } else if hasPersistedActivationAttempt, !activationSafetyRequiresRestart {
            Self.clearActivationSafetyRecord(defaults: .standard)
            hasPersistedActivationAttempt = false
            MacEnforcementLog.lifecycle.notice(
                "Network Extension in-flight activation record cleared reason=explicit-disable trigger=\(trigger, privacy: .public)"
            )
        }
        cancelRetryGuardPreparation(reason: trigger)
        cancelActivationEvidenceDeadline(reason: trigger)
        let disableAlreadyQueued = activePreferenceMutation?.goal.isExplicitDisable == true
            || pendingPreferenceMutation?.goal.isExplicitDisable == true
        if status == .disabling, disableAlreadyQueued {
            return
        }
        desiredStateGeneration &+= 1
        cancelStartupWatchdog(reason: trigger)
        invalidateVerifiedActivation(reason: trigger)
        isBlockingDisabled = true
        UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
        DesktopDiagnosticTrace.record(
            component: "enforcement",
            event: "disable_requested",
            fields: [
                "trigger": trigger,
                "requires_safety_reset": requireRestartBeforeReenable,
                "state_generation": desiredStateGeneration
            ]
        )
        pendingActivationTrigger = nil
        recoveryWarning = nil
        recoveryWarnings.removeAll()
        activationRequestGeneration = nil
        status = .disabling
        deliveryError = nil
        disableNetworkFilter(trigger: trigger)
        // On this Mac, saving an installed filter preference as disabled can
        // leave a provider-less IP Drop-All layer behind. That makes a launch
        // while blocking is already paused capable of taking DNS and HTTPS
        // offline. Remove the preference on every explicit disable; enabling
        // reconstructs it, while the signed system extension stays installed.
        beginBreakGlassPreferenceRemoval(trigger: "disabled-\(trigger)")
    }

    /// Availability-first failure path. Removing the NE preference as well as
    /// saving `isEnabled = false` is intentional: the live incident showed a
    /// successful disable save could leave a provider-less NE agent wedged until
    /// the configuration was removed and the network stack rebuilt it.
    func disableBlockingForSafety(trigger: String) {
        disableBlockingImmediately(
            trigger: trigger,
            requireRestartBeforeReenable: true
        )
    }

    private func latchActivationSafetyUntilRestart(reason: String) {
        let record = MacFilterActivationSafetyRecord(
            bootSessionIdentifier: Self.currentBootSessionIdentifier(),
            estimatedBootTime: Self.currentEstimatedBootTime(),
            triggeredAt: Date(),
            reason: reason
        )
        Self.persistActivationSafetyRecord(record, defaults: .standard)
        activationSafetyRequiresRestart = true
        activationSafetyReason = reason
        hasPersistedActivationAttempt = false
        isBlockingDisabled = true
        UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
        MacEnforcementLog.lifecycle.fault(
            "Network Extension activation safety interlock set reason=\(reason, privacy: .public) action=remain-disabled-until-restart-or-proven-reset"
        )
        DesktopDiagnosticTrace.record(
            component: "safety",
            event: "activation_interlock_set",
            fields: ["reason": reason]
        )
    }

    /// Clears the app-owned activation interlock without restarting macOS.
    ///
    /// This is deliberately not an enable operation. It keeps disabled intent
    /// persisted, waits for every uncancellable Network Extension preference
    /// callback and late-enable quarantine sweep to settle, removes the filter
    /// preference, proves it absent, observes fresh DNS+HTTPS connectivity, and
    /// proves the preference absent once more before clearing only our latch.
    func resetEnforcementWithoutRestart() {
        guard activationSafetyRequiresRestart else {
            enforcementResetStatus = "No safety reset is required. Web blocking remains disabled until you enable it."
            return
        }
        guard !isResettingEnforcement else { return }
        guard !isRemoving else {
            enforcementResetStatus = "Network Extension removal is already running. Finish that operation before resetting enforcement."
            return
        }

        cancelSameBootResetWork()
        sameBootResetGeneration &+= 1
        let generation = sameBootResetGeneration
        let attemptIdentifier = diagnosticOperationID()
        sameBootResetAttemptIdentifier = attemptIdentifier
        sameBootResetState = nil
        isResettingEnforcement = true
        isBlockingDisabled = true
        UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
        status = .disabling
        deliveryError = nil
        enforcementResetStatus = "Waiting for earlier Network Extension operations to settle…"

        // Invalidate every source of enabled-preference authority without
        // cancelling an uncancellable NE callback. The cleanup wait below owns
        // the handoff once those callbacks have actually settled.
        desiredStateGeneration &+= 1
        cancelRetryGuardPreparation(reason: "same-boot-reset")
        cancelActivationEvidenceDeadline(reason: "same-boot-reset")
        cancelStartupWatchdog(reason: "same-boot-reset")
        invalidateVerifiedActivation(reason: "same-boot-reset")
        pendingActivationTrigger = nil
        activationRequestGeneration = nil

        let cleanupStartedAt = Date()
        let initialCleanupDeadline =
            MacFilterSameBootResetSafety.initialCleanupObservationDeadline(
                startedAt: cleanupStartedAt,
                ownerCycleBudget:
                    Self.sameBootResetOrphanedCleanupRemediationBudget,
                pollSlack: Self.sameBootResetCleanupObservationSlack
            )
        MacEnforcementLog.sameBootReset.notice(
            "Same-boot enforcement reset started attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) cleanupDeadlineMs=\(Int(Self.sameBootResetCleanupDeadline * 1_000), privacy: .public) blockingDisabled=\(self.isBlockingDisabled, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "safety",
            event: "same_boot_reset_started",
            fields: [
                "operation_id": attemptIdentifier,
                "generation": generation,
                "blocking_disabled": isBlockingDisabled
            ]
        )
        sameBootResetCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var cleanupDeadline = initialCleanupDeadline
            var orphanedRedriveDeadlineExtensionWasUsed = false
            while !Task.isCancelled,
                  self.sameBootResetGeneration == generation,
                  self.sameBootResetAttemptIdentifier == attemptIdentifier,
                  self.activationSafetyRequiresRestart,
                  self.isBlockingDisabled,
                  !self.sameBootResetCleanupIsSettled,
                  Date() < cleanupDeadline {
                let claimedOrphanedCleanup =
                    self.redriveOrphanedSameBootResetCleanupIfNeeded(
                        attemptIdentifier: attemptIdentifier,
                        resetGeneration: generation
                    )
                if claimedOrphanedCleanup,
                   !orphanedRedriveDeadlineExtensionWasUsed {
                    let claimedAt = Date()
                    cleanupDeadline = MacFilterSameBootResetSafety
                        .cleanupDeadlineAfterClaimingOrphanedRedrive(
                            currentDeadline: cleanupDeadline,
                            claimedAt: claimedAt,
                            remediationBudget:
                                Self.sameBootResetOrphanedCleanupRemediationBudget,
                            extensionAlreadyUsed: false
                        )
                    orphanedRedriveDeadlineExtensionWasUsed = true
                    MacEnforcementLog.sameBootReset.notice(
                        "Same-boot reset granted one orphan-cleanup budget attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) remainingBudgetMs=\(Int(cleanupDeadline.timeIntervalSince(claimedAt) * 1_000), privacy: .public) furtherExtensionsAllowed=false"
                    )
                }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            Self.sameBootResetCleanupPollInterval
                                * 1_000_000_000
                        )
                    )
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  self.sameBootResetGeneration == generation,
                  self.sameBootResetAttemptIdentifier == attemptIdentifier else {
                return
            }
            self.sameBootResetCleanupTask = nil
            guard self.activationSafetyRequiresRestart,
                  self.isBlockingDisabled else {
                self.failSameBootReset(
                    attemptIdentifier: attemptIdentifier,
                    generation: generation,
                    message: "The disabled safety state changed while reset was running. The interlock was kept."
                )
                return
            }
            guard self.sameBootResetCleanupIsSettled else {
                self.failSameBootReset(
                    attemptIdentifier: attemptIdentifier,
                    generation: generation,
                    message: "Earlier Network Extension operations did not settle within the bounded cleanup deadline. Blocking remains disabled; try the reset again."
                )
                return
            }
            self.beginSameBootResetProof(
                attemptIdentifier: attemptIdentifier,
                generation: generation
            )
        }
    }

    private var sameBootResetCleanupIsSettled: Bool {
        sameBootResetUncertainWorkEvidence == .confirmedIdle
    }

    private var sameBootResetUncertainWorkSnapshot:
        MacFilterSameBootResetUncertainWorkSnapshot {
        MacFilterSameBootResetUncertainWorkSnapshot(
            lateEnableQuarantineExists: lateEnablePreferenceQuarantine != nil,
            lateEnableQuarantineTaskExists: lateEnableQuarantineTask != nil,
            lateEnableProbeExists: lateEnableQuarantineProbeOperationID != nil,
            lateEnableProbeDeadlineExists:
                lateEnableQuarantineProbeDeadlineTask != nil,
            breakGlassRemovalIsInFlight: isBreakGlassRemovalInFlight,
            activePreferenceMutationExists: activePreferenceMutation != nil,
            pendingPreferenceMutationExists: pendingPreferenceMutation != nil,
            pendingFinalEnableVerificationExists:
                pendingFinalEnableVerification != nil,
            configurationOperationCount: configurationOperations.count,
            outstandingEnabledSaveCount:
                outstandingEnabledPreferenceSaveOperations.count
        )
    }

    private var sameBootResetUncertainWorkEvidence:
        MacFilterSameBootResetUncertainWorkEvidence {
        MacFilterSameBootResetSafety.uncertainWorkEvidence(
            for: sameBootResetUncertainWorkSnapshot
        )
    }

    private func redriveOrphanedSameBootResetCleanupIfNeeded(
        attemptIdentifier: String,
        resetGeneration: UInt64
    ) -> Bool {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: resetGeneration
        ) else { return false }
        let snapshot = sameBootResetUncertainWorkSnapshot
        guard MacFilterSameBootResetSafety
            .shouldRedriveOrphanedEnabledSaveCleanup(for: snapshot),
              let outstandingPreferenceGeneration =
                  outstandingEnabledPreferenceSaveOperations.values.max() else {
            return false
        }

        let didStartCleanupOwner = beginLateEnablePreferenceQuarantine(
            timedOutPreferenceGeneration: outstandingPreferenceGeneration,
            trigger: "same-boot-reset-orphaned-enabled-save"
        )
        guard didStartCleanupOwner else { return false }

        enforcementResetStatus = "Recovering an interrupted Network Extension cleanup…"
        MacEnforcementLog.sameBootReset.fault(
            "Same-boot reset claimed orphaned enabled-save cleanup attempt=\(attemptIdentifier, privacy: .public) generation=\(resetGeneration, privacy: .public) outstanding=\(snapshot.outstandingEnabledSaveCount, privacy: .public) timedOutPreferenceGeneration=\(outstandingPreferenceGeneration, privacy: .public) action=restart-bounded-quarantine"
        )
        return true
    }

    private func beginSameBootResetProof(
        attemptIdentifier: String,
        generation: UInt64
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ) else { return }
        let transition = MacFilterSameBootResetSafety.start(
            attemptIdentifier: attemptIdentifier,
            context: sameBootResetContext(generation: generation),
            configuration: MacFilterSameBootResetConfiguration(
                requiredHealthyConnectivityObservations: 3,
                minimumHealthyObservationInterval: 1,
                timeout: 60
            )
        )
        guard let state = transition.state,
              case let .removeNetworkExtensionPreference(token) = transition.command else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The safe reset proof could not start. Blocking remains disabled."
            )
            return
        }
        sameBootResetState = state
        // With no older preference operation remaining, advance the preference
        // generation once. Any truly orphaned callback can no longer be current.
        preferenceGeneration &+= 1
        enforcementResetStatus = "Removing the Network Extension traffic-filter preference…"
        startSameBootResetPreferenceRemoval(
            attemptIdentifier: attemptIdentifier,
            generation: generation,
            token: token
        )
    }

    private func startSameBootResetPreferenceRemoval(
        attemptIdentifier: String,
        generation: UInt64,
        token: MacFilterSameBootResetProbeToken
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ) else { return }
        let operationID = diagnosticOperationID()
        sameBootResetPreferenceOperationID = operationID
        armSameBootResetPreferenceDeadline(
            attemptIdentifier: attemptIdentifier,
            generation: generation,
            operationID: operationID,
            stage: "remove"
        )
        let manager = NEFilterManager.shared()
        MacEnforcementLog.sameBootReset.notice(
            "Same-boot preference removal started attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public)"
        )
        manager.loadFromPreferences { [weak self] loadError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sameBootResetAttemptIsCurrent(
                    attemptIdentifier,
                    generation: generation
                ), self.sameBootResetPreferenceOperationID == operationID else {
                    MacEnforcementLog.sameBootReset.notice(
                        "Late same-boot preference removal callback ignored attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public)"
                    )
                    return
                }
                guard loadError == nil else {
                    self.completeSameBootResetPreferenceRemoval(
                        error: loadError,
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        operationID: operationID,
                        token: token
                    )
                    return
                }
                manager.removeFromPreferences { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.completeSameBootResetPreferenceRemoval(
                            error: error,
                            attemptIdentifier: attemptIdentifier,
                            generation: generation,
                            operationID: operationID,
                            token: token
                        )
                    }
                }
            }
        }
    }

    private func completeSameBootResetPreferenceRemoval(
        error: Error?,
        attemptIdentifier: String,
        generation: UInt64,
        operationID: String,
        token: MacFilterSameBootResetProbeToken
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ), sameBootResetPreferenceOperationID == operationID else {
            MacEnforcementLog.sameBootReset.notice(
                "Late same-boot preference removal callback ignored attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public)"
            )
            return
        }
        clearSameBootResetPreferenceOperation(operationID: operationID)
        let callbackEvidence: MacFilterSameBootResetRemovalCallbackEvidence
        if let error {
            callbackEvidence = .returnedError
            let nsError = error as NSError
            // A load or remove error is not evidence either way. Continue to
            // the separate authoritative load below, which fails closed if a
            // configured preference remains.
            MacEnforcementLog.sameBootReset.notice(
                "Same-boot preference removal callback returned error attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) action=reload-and-prove-state"
            )
        } else {
            callbackEvidence = .succeeded
            MacEnforcementLog.sameBootReset.notice(
                "Same-boot preference removal callback succeeded attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) action=reload-and-prove-absent"
            )
        }
        guard let resetState = sameBootResetState else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset lost its removal proof state. The safety interlock was kept."
            )
            return
        }
        let transition = MacFilterSameBootResetSafety.recordPreferenceRemovalCallback(
            callbackEvidence,
            token: token,
            for: resetState,
            context: sameBootResetContext(generation: generation)
        )
        switch transition.command {
        case let .loadNetworkExtensionPreference(.initial, proofToken):
            guard let proofState = transition.state else {
                failSameBootReset(
                    attemptIdentifier: attemptIdentifier,
                    generation: generation,
                    message: "The reset could not begin its authoritative preference proof. The safety interlock was kept."
                )
                return
            }
            sameBootResetState = proofState
            enforcementResetStatus = "Verifying that the Network Extension preference is absent…"
            startSameBootResetPreferenceVerification(
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        stage: .initial,
                        token: proofToken
            )
        case .ignoreStaleObservation:
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset received a stale removal callback after its active operation completed. The safety interlock was kept."
            )
        case let .keepApplicationSafetyLatch(reason):
            sameBootResetState = transition.state
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: sameBootResetFailureMessage(reason)
            )
        case .removeNetworkExtensionPreference,
             .loadNetworkExtensionPreference(.final, _),
             .verifyNoUncertainPreferenceWork,
             .observeConnectivity,
             .authorized:
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset received removal evidence out of order. The safety interlock was kept."
            )
        }
    }

    private func startSameBootResetPreferenceVerification(
        attemptIdentifier: String,
        generation: UInt64,
        stage: MacFilterSameBootResetPreferenceProofStage,
        token: MacFilterSameBootResetProbeToken
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ) else { return }
        let operationID = diagnosticOperationID()
        let stageDescription = stage == .final
            ? "final-absence-load"
            : "initial-absence-load"
        sameBootResetPreferenceOperationID = operationID
        armSameBootResetPreferenceDeadline(
            attemptIdentifier: attemptIdentifier,
            generation: generation,
            operationID: operationID,
            stage: stageDescription
        )
        let manager = NEFilterManager.shared()
        MacEnforcementLog.sameBootReset.notice(
            "Same-boot preference verification started attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) stage=\(stageDescription, privacy: .public)"
        )
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sameBootResetAttemptIsCurrent(
                    attemptIdentifier,
                    generation: generation
                ), self.sameBootResetPreferenceOperationID == operationID else {
                    MacEnforcementLog.sameBootReset.notice(
                        "Late same-boot preference verification callback ignored attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) stage=\(stageDescription, privacy: .public)"
                    )
                    return
                }
                self.clearSameBootResetPreferenceOperation(operationID: operationID)
                if let error {
                    let nsError = error as NSError
                    MacEnforcementLog.sameBootReset.error(
                        "Same-boot preference verification failed attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) stage=\(stageDescription, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)"
                    )
                    self.failSameBootReset(
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        message: "macOS could not confirm that the Network Extension preference is absent. The safety interlock was kept."
                    )
                    return
                }

                let preferenceIsAbsent = !manager.isEnabled
                    && manager.providerConfiguration == nil
                MacEnforcementLog.sameBootReset.notice(
                    "Same-boot preference verification completed attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) stage=\(stageDescription, privacy: .public) enabled=\(manager.isEnabled, privacy: .public) configurationPresent=\(manager.providerConfiguration != nil, privacy: .public) absent=\(preferenceIsAbsent, privacy: .public)"
                )
                guard preferenceIsAbsent else {
                    self.failSameBootReset(
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        message: "The Network Extension preference is still present. Blocking remains disabled; retry the reset after cleanup finishes."
                    )
                    return
                }

                if stage == .final {
                    self.recordFinalSameBootResetPreferenceProof(
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        token: token
                    )
                } else {
                    self.recordInitialSameBootResetPreferenceProof(
                        attemptIdentifier: attemptIdentifier,
                        generation: generation,
                        token: token
                    )
                }
            }
        }
    }

    private func recordInitialSameBootResetPreferenceProof(
        attemptIdentifier: String,
        generation: UInt64,
        token: MacFilterSameBootResetProbeToken
    ) {
        guard let state = sameBootResetState,
              sameBootResetAttemptIsCurrent(
                  attemptIdentifier,
                  generation: generation
              ) else { return }
        let preferenceTransition = MacFilterSameBootResetSafety.recordInitialPreferenceEvidence(
            .preferenceAbsent,
            token: token,
            for: state,
            context: sameBootResetContext(generation: generation)
        )
        guard let quarantineState = preferenceTransition.state,
              case let .verifyNoUncertainPreferenceWork(uncertainWorkToken) =
                  preferenceTransition.command else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset rejected its initial preference proof. The safety interlock was kept."
            )
            return
        }
        sameBootResetState = quarantineState

        // Re-evaluate the full lane set after the removal/reload callback. A
        // quarantine final sweep can be scheduled while its public state is nil.
        let quarantineEvidence = sameBootResetUncertainWorkEvidence
        let quarantineTransition = MacFilterSameBootResetSafety.recordUncertainPreferenceWorkEvidence(
            quarantineEvidence,
            token: uncertainWorkToken,
            for: quarantineState,
            context: sameBootResetContext(generation: generation)
        )
        guard let connectivityState = quarantineTransition.state else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "An earlier enabled-preference operation is still being quarantined. Blocking remains disabled; retry when cleanup finishes."
            )
            return
        }
        sameBootResetState = connectivityState
        continueSameBootReset(
            quarantineTransition,
            attemptIdentifier: attemptIdentifier,
            generation: generation
        )
    }

    private func continueSameBootReset(
        _ transition: MacFilterSameBootResetTransition,
        attemptIdentifier: String,
        generation: UInt64
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ) else { return }
        switch transition.command {
        case let .observeConnectivity(token, remaining, notBefore):
            sameBootResetState = transition.state
            enforcementResetStatus = "Checking DNS and HTTPS connectivity (\(remaining) confirmation\(remaining == 1 ? "" : "s") remaining)…"
            scheduleSameBootResetConnectivityObservation(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                token: token,
                notBefore: notBefore
            )
        case let .loadNetworkExtensionPreference(.final, token):
            sameBootResetState = transition.state
            enforcementResetStatus = "Connectivity is healthy. Rechecking the Network Extension preference…"
            startSameBootResetPreferenceVerification(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                stage: .final,
                token: token
            )
        case let .authorized(authorization):
            finishSameBootReset(
                authorization: authorization,
                attemptIdentifier: attemptIdentifier,
                generation: generation
            )
        case let .keepApplicationSafetyLatch(reason):
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: sameBootResetFailureMessage(reason)
            )
        case .ignoreStaleObservation:
            break
        case .removeNetworkExtensionPreference,
             .loadNetworkExtensionPreference(.initial, _),
             .verifyNoUncertainPreferenceWork(_):
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset received evidence out of order. The safety interlock was kept."
            )
        }
    }

    private func scheduleSameBootResetConnectivityObservation(
        attemptIdentifier: String,
        generation: UInt64,
        token: MacFilterSameBootResetProbeToken,
        notBefore: Date
    ) {
        sameBootResetConnectivityTask?.cancel()
        sameBootResetConnectivityTask = nil
        sameBootResetDNSResolutionTask?.cancel()
        sameBootResetDNSResolutionTask = nil
        sameBootResetConnectivityProbeIdentity = nil
        let probeIdentity = MacFilterSameBootResetConnectivityProbeIdentity(
            attemptIdentifier: attemptIdentifier,
            resetGeneration: generation,
            operationIdentifier: diagnosticOperationID(),
            token: token
        )
        sameBootResetConnectivityProbeIdentity = probeIdentity
        sameBootResetConnectivityTask = Task { @MainActor [weak self] in
            let delay = max(0, notBefore.timeIntervalSinceNow)
            if delay > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.sameBootResetAttemptIsCurrent(
                      attemptIdentifier,
                      generation: generation
                  ),
                  MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                      identity: probeIdentity,
                      activeIdentity: self.sameBootResetConnectivityProbeIdentity
                  ) else { return }
            self.sameBootResetConnectivityTask = nil
            self.startSameBootResetDNSObservation(
                identity: probeIdentity
            )
        }
    }

    private func startSameBootResetDNSObservation(
        identity: MacFilterSameBootResetConnectivityProbeIdentity
    ) {
        guard sameBootResetAttemptIsCurrent(
            identity.attemptIdentifier,
            generation: identity.resetGeneration
        ), MacFilterSameBootResetSafety.acceptsConnectivityCallback(
            identity: identity,
            activeIdentity: sameBootResetConnectivityProbeIdentity
        ) else { return }
        sameBootResetDNSResolutionTask?.cancel()
        MacEnforcementLog.sameBootReset.notice(
            "Same-boot connectivity DNS observation started attempt=\(identity.attemptIdentifier, privacy: .public) generation=\(identity.resetGeneration, privacy: .public) probe=\(identity.operationIdentifier, privacy: .public) domain=\(Self.sameBootResetConnectivityDomain, privacy: .public)"
        )
        sameBootResetDNSResolutionTask = retryGuardResolver.resolve(
            domainSuffixes: [Self.sameBootResetConnectivityDomain],
            timeout: Self.sameBootResetDNSDeadline
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.sameBootResetAttemptIsCurrent(
                          identity.attemptIdentifier,
                          generation: identity.resetGeneration
                      ),
                      MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                          identity: identity,
                          activeIdentity:
                              self.sameBootResetConnectivityProbeIdentity
                      ) else { return }
                self.sameBootResetDNSResolutionTask = nil
                let dnsHealthy = !result.wasCancelled
                    && !result.didReachDeadline
                    && result.unresolvedDomainSuffixes.isEmpty
                    && !(result.resolution.addressesByDomainSuffix[
                        Self.sameBootResetConnectivityDomain
                    ] ?? []).isEmpty
                MacEnforcementLog.sameBootReset.notice(
                    "Same-boot connectivity DNS observation completed attempt=\(identity.attemptIdentifier, privacy: .public) generation=\(identity.resetGeneration, privacy: .public) probe=\(identity.operationIdentifier, privacy: .public) healthy=\(dnsHealthy, privacy: .public) deadlineReached=\(result.didReachDeadline, privacy: .public) cancelled=\(result.wasCancelled, privacy: .public) unresolved=\(result.unresolvedDomainSuffixes.count, privacy: .public)"
                )
                guard dnsHealthy else {
                    self.sameBootResetConnectivityProbeIdentity = nil
                    self.recordSameBootResetConnectivityEvidence(
                        .unhealthy,
                        attemptIdentifier: identity.attemptIdentifier,
                        generation: identity.resetGeneration,
                        token: identity.token,
                        failureMessage: "DNS did not recover during the safety check. Blocking remains disabled; check the connection and retry."
                    )
                    return
                }
                self.startSameBootResetHTTPSObservation(
                    identity: identity
                )
            }
        }
    }

    private func startSameBootResetHTTPSObservation(
        identity: MacFilterSameBootResetConnectivityProbeIdentity
    ) {
        guard sameBootResetAttemptIsCurrent(
            identity.attemptIdentifier,
            generation: identity.resetGeneration
        ), MacFilterSameBootResetSafety.acceptsConnectivityCallback(
            identity: identity,
            activeIdentity: sameBootResetConnectivityProbeIdentity
        ) else { return }
        sameBootResetConnectivityTask?.cancel()
        sameBootResetConnectivityTask = Task { @MainActor [weak self] in
            let observation = await Self.performSameBootResetHTTPSObservation(
                attemptIdentifier: identity.attemptIdentifier,
                timeout: Self.sameBootResetHTTPSDeadline
            )
            guard let self,
                  !Task.isCancelled,
                  self.sameBootResetAttemptIsCurrent(
                      identity.attemptIdentifier,
                      generation: identity.resetGeneration
                  ),
                  MacFilterSameBootResetSafety.acceptsConnectivityCallback(
                      identity: identity,
                      activeIdentity: self.sameBootResetConnectivityProbeIdentity
                  ) else { return }
            self.sameBootResetConnectivityTask = nil
            self.sameBootResetConnectivityProbeIdentity = nil
            MacEnforcementLog.sameBootReset.notice(
                "Same-boot connectivity HTTPS observation completed attempt=\(identity.attemptIdentifier, privacy: .public) generation=\(identity.resetGeneration, privacy: .public) probe=\(identity.operationIdentifier, privacy: .public) healthy=\(observation.isHealthy, privacy: .public) status=\(observation.statusCode ?? 0, privacy: .public) errorDomain=\(observation.errorDomain ?? "none", privacy: .public) errorCode=\(observation.errorCode ?? 0, privacy: .public)"
            )
            self.recordSameBootResetConnectivityEvidence(
                observation.isHealthy ? .healthy : .unhealthy,
                attemptIdentifier: identity.attemptIdentifier,
                generation: identity.resetGeneration,
                token: identity.token,
                failureMessage: "HTTPS did not recover during the safety check. Blocking remains disabled; check the connection and retry."
            )
        }
    }

    nonisolated private static func performSameBootResetHTTPSObservation(
        attemptIdentifier: String,
        timeout: TimeInterval
    ) async -> SameBootResetHTTPSObservation {
        var components = URLComponents(
            string: "https://example.com/"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "executive-dysfunction-reset",
                value: "\(attemptIdentifier)-\(UUID().uuidString)"
            )
        ]
        guard let url = components?.url else {
            return SameBootResetHTTPSObservation(
                isHealthy: false,
                statusCode: nil,
                errorDomain: "HoldfastReset",
                errorCode: 1
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            return SameBootResetHTTPSObservation(
                isHealthy: statusCode.map { (200..<400).contains($0) } == true,
                statusCode: statusCode,
                errorDomain: nil,
                errorCode: nil
            )
        } catch {
            let nsError = error as NSError
            return SameBootResetHTTPSObservation(
                isHealthy: false,
                statusCode: nil,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        }
    }

    private func recordSameBootResetConnectivityEvidence(
        _ evidence: MacFilterSameBootResetConnectivityEvidence,
        attemptIdentifier: String,
        generation: UInt64,
        token: MacFilterSameBootResetProbeToken,
        failureMessage: String
    ) {
        guard let state = sameBootResetState,
              sameBootResetAttemptIsCurrent(
                  attemptIdentifier,
                  generation: generation
              ) else { return }
        let transition = MacFilterSameBootResetSafety.recordConnectivityEvidence(
            evidence,
            token: token,
            for: state,
            context: sameBootResetContext(generation: generation)
        )
        if case .keepApplicationSafetyLatch = transition.command {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: failureMessage
            )
            return
        }
        sameBootResetState = transition.state
        continueSameBootReset(
            transition,
            attemptIdentifier: attemptIdentifier,
            generation: generation
        )
    }

    private func recordFinalSameBootResetPreferenceProof(
        attemptIdentifier: String,
        generation: UInt64,
        token: MacFilterSameBootResetProbeToken
    ) {
        guard let state = sameBootResetState,
              sameBootResetAttemptIsCurrent(
                  attemptIdentifier,
                  generation: generation
              ) else { return }
        let uncertainWork = sameBootResetUncertainWorkEvidence
        let transition = MacFilterSameBootResetSafety.recordFinalPreferenceEvidence(
            .preferenceAbsent,
            uncertainWork: uncertainWork,
            token: token,
            for: state,
            context: sameBootResetContext(generation: generation)
        )
        sameBootResetState = transition.state
        continueSameBootReset(
            transition,
            attemptIdentifier: attemptIdentifier,
            generation: generation
        )
    }

    private func finishSameBootReset(
        authorization: MacFilterSameBootResetAuthorization,
        attemptIdentifier: String,
        generation: UInt64
    ) {
        guard sameBootResetAttemptIsCurrent(
            attemptIdentifier,
            generation: generation
        ), sameBootResetCleanupIsSettled,
           authorization.attemptIdentifier == attemptIdentifier,
           authorization.enforcementGeneration == generation,
           authorization.bootSessionIdentifier == Self.currentBootSessionIdentifier(),
           authorization.disposition ==
               .clearApplicationSafetyLatchOnlyWhileRemainingDisabled else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "A Network Extension operation reappeared during the final check. The safety interlock was kept."
            )
            return
        }

        // Commit one coherent receipt while the latch is still present. Only a
        // successful CFPreferences durability barrier permits the latch-clear
        // transaction to begin; an external verifier can therefore never see a
        // cleared latch without the receipt and disabled intent that authorize it.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.blockingDisabledKey)
        guard Self.persistSameBootResetReceipt(
            attemptIdentifier: attemptIdentifier,
            bootSessionIdentifier: authorization.bootSessionIdentifier,
            completedAt: authorization.completedAt,
            defaults: defaults
        ) else {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset proof succeeded, but its disabled-state receipt could not be saved durably. The safety interlock was kept."
            )
            return
        }

        Self.clearActivationSafetyRecord(defaults: defaults)
        guard defaults.synchronize() else {
            // Restore a latch newer than the receipt. Even if CFPreferences later
            // flushes a partial transaction, the signed reporter and smoke harness
            // will reject the receipt while this replacement latch is present.
            Self.persistActivationSafetyRecord(
                MacFilterActivationSafetyRecord(
                    bootSessionIdentifier: Self.currentBootSessionIdentifier(),
                    estimatedBootTime: Self.currentEstimatedBootTime(),
                    triggeredAt: Date(),
                    reason: "same-boot-reset-latch-clear-not-durable"
                ),
                defaults: defaults
            )
            defaults.set(true, forKey: Self.blockingDisabledKey)
            _ = defaults.synchronize()
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "The reset proof succeeded, but macOS did not durably clear the safety interlock. Blocking remains disabled; retry the reset."
            )
            return
        }
        activationSafetyRequiresRestart = false
        activationSafetyReason = nil
        hasPersistedActivationAttempt = false
        isBlockingDisabled = true
        status = .disabled
        deliveryError = nil
        enforcementResetStatus = "Enforcement was reset safely. Blocking is still disabled; no Mac restart was required."
        isResettingEnforcement = false
        sameBootResetState = nil
        sameBootResetAttemptIdentifier = nil
        sameBootResetPreferenceOperationID = nil
        sameBootResetPreferenceDeadlineTask?.cancel()
        sameBootResetPreferenceDeadlineTask = nil
        sameBootResetConnectivityTask?.cancel()
        sameBootResetConnectivityTask = nil
        sameBootResetDNSResolutionTask?.cancel()
        sameBootResetDNSResolutionTask = nil
        sameBootResetConnectivityProbeIdentity = nil
        MacEnforcementLog.sameBootReset.notice(
            "Same-boot enforcement reset completed attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) action=clear-application-latch-only blockingDisabled=\(self.isBlockingDisabled, privacy: .public) enabledPreferenceSaved=false"
        )
        DesktopDiagnosticTrace.record(
            component: "safety",
            event: "same_boot_reset_completed",
            fields: [
                "operation_id": attemptIdentifier,
                "generation": generation,
                "blocking_disabled": isBlockingDisabled
            ]
        )
    }

    private func failSameBootReset(
        attemptIdentifier: String,
        generation: UInt64,
        message: String
    ) {
        guard sameBootResetGeneration == generation,
              sameBootResetAttemptIdentifier == attemptIdentifier else { return }
        cancelSameBootResetWork()
        isResettingEnforcement = false
        isBlockingDisabled = true
        UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
        status = .disabled
        enforcementResetStatus = message
        MacEnforcementLog.sameBootReset.error(
            "Same-boot enforcement reset failed attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) message=\(message, privacy: .public) action=keep-application-latch-and-remain-disabled"
        )
        DesktopDiagnosticTrace.record(
            component: "safety",
            event: "same_boot_reset_failed",
            fields: [
                "operation_id": attemptIdentifier,
                "generation": generation,
                "message": message
            ]
        )
    }

    private func sameBootResetAttemptIsCurrent(
        _ attemptIdentifier: String,
        generation: UInt64
    ) -> Bool {
        isResettingEnforcement
            && activationSafetyRequiresRestart
            && isBlockingDisabled
            && sameBootResetGeneration == generation
            && sameBootResetAttemptIdentifier == attemptIdentifier
    }

    private func sameBootResetContext(
        generation: UInt64
    ) -> MacFilterSameBootResetContext {
        MacFilterSameBootResetContext(
            applicationSafetyLatchIsSet: activationSafetyRequiresRestart,
            blockingIsDisabled: isBlockingDisabled,
            enforcementGeneration: generation,
            bootSessionIdentifier: Self.currentBootSessionIdentifier()
        )
    }

    private func cancelSameBootResetWork() {
        sameBootResetCleanupTask?.cancel()
        sameBootResetCleanupTask = nil
        sameBootResetPreferenceDeadlineTask?.cancel()
        sameBootResetPreferenceDeadlineTask = nil
        sameBootResetConnectivityTask?.cancel()
        sameBootResetConnectivityTask = nil
        sameBootResetDNSResolutionTask?.cancel()
        sameBootResetDNSResolutionTask = nil
        sameBootResetConnectivityProbeIdentity = nil
        sameBootResetPreferenceOperationID = nil
        sameBootResetState = nil
        sameBootResetAttemptIdentifier = nil
    }

    private func armSameBootResetPreferenceDeadline(
        attemptIdentifier: String,
        generation: UInt64,
        operationID: String,
        stage: String
    ) {
        sameBootResetPreferenceDeadlineTask?.cancel()
        sameBootResetPreferenceDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.sameBootResetPreferenceDeadline * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self,
                  self.sameBootResetAttemptIsCurrent(
                      attemptIdentifier,
                      generation: generation
                  ),
                  self.sameBootResetPreferenceOperationID == operationID else {
                return
            }
            self.sameBootResetPreferenceOperationID = nil
            self.sameBootResetPreferenceDeadlineTask = nil
            MacEnforcementLog.sameBootReset.error(
                "Same-boot preference operation timed out attempt=\(attemptIdentifier, privacy: .public) generation=\(generation, privacy: .public) op=\(operationID, privacy: .public) stage=\(stage, privacy: .public) deadlineMs=\(Int(Self.sameBootResetPreferenceDeadline * 1_000), privacy: .public)"
            )
            self.failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: generation,
                message: "macOS stopped responding during the Network Extension \(stage) check. Blocking remains disabled; try the reset again."
            )
        }
    }

    private func clearSameBootResetPreferenceOperation(operationID: String) {
        guard sameBootResetPreferenceOperationID == operationID else { return }
        sameBootResetPreferenceDeadlineTask?.cancel()
        sameBootResetPreferenceDeadlineTask = nil
        sameBootResetPreferenceOperationID = nil
    }

    private func sameBootResetFailureMessage(
        _ failure: MacFilterSameBootResetFailure
    ) -> String {
        switch failure {
        case .applicationSafetyLatchNotSet, .blockingIsNotDisabled:
            "Blocking was no longer disabled, so the safety interlock was kept."
        case .preferenceEnabled, .preferenceUnconfirmed:
            "The Network Extension preference could not be proven absent. The safety interlock was kept."
        case .providerConfigurationStillPresent:
            "A stale Network Extension provider configuration is still present. Blocking remains disabled; retry the reset."
        case .uncertainPreferenceWorkActive, .uncertainPreferenceWorkUnconfirmed:
            "An uncertain earlier enable is still being cleaned up. Blocking remains disabled; try again shortly."
        case .connectivityUnconfirmed:
            "Internet connectivity could not be proven healthy. Blocking remains disabled; check the connection and retry."
        case .deadlineExceeded, .finalPreferenceProofNotFresh:
            "The safety proof exceeded its deadline. Blocking remains disabled; try the reset again."
        case .invalidConfiguration,
             .invalidAttemptIdentifier,
             .missingBootSessionIdentifier,
             .enforcementGenerationChanged,
             .bootSessionChanged:
            "The safety proof could not be completed. The interlock was kept."
        }
    }

    private func requestActivationBeforeEnablingPreferences(
        trigger: String,
        configurationTrigger: NetworkFilterConfigurationTrigger
    ) {
        guard !isBlockingDisabled,
              !isRemoving,
              !isResettingEnforcement,
              !activationSafetyRequiresRestart else {
            MacEnforcementLog.delivery.notice(
                "System-extension activation suppressed trigger=\(trigger, privacy: .public) reason=blocking-disabled-or-safety-interlock"
            )
            return
        }
        let activationGeneration = desiredStateGeneration
        cancelActivationEvidenceDeadline(reason: "superseded-by-\(trigger)")
        retainedRetryGuardSnapshot = nil
        invalidateVerifiedActivation(reason: "pre-activation-\(trigger)")
        activationAttempt = MacFilterActivationAttempt(
            desiredStateGeneration: activationGeneration,
            expectedBundleIdentifier: DesktopEnforcementConstants.webFilterExtensionIdentifier,
            expectedProviderBuild: Self.providerBuild
        )
        status = .activating
        enforcementPreparationMessage = "Web enforcement is restarting for updated rules. Waiting for extension verification and DNS preparation."
        pendingActivationTrigger = trigger
        activationRequestGeneration = nil
        // Serialize this behind any uncancellable preference operation already
        // in flight. A successful callback proves that an old provider-less
        // enabled preference is off before sysextd activation can begin.
        preferenceGeneration &+= 1
        enqueuePreferenceMutation(
            FilterPreferenceMutation(
                generation: preferenceGeneration,
                goal: .disabledForActivation(
                    trigger: trigger,
                    configurationTrigger: configurationTrigger,
                    activationGeneration: activationGeneration,
                    retry: 0
                )
            )
        )
    }

    private func submitActivation(
        _ identifier: String,
        trigger: String,
        configurationTrigger: NetworkFilterConfigurationTrigger,
        stateGeneration: UInt64
    ) {
        guard !Self.isRunningTests else {
            MacEnforcementLog.lifecycle.debug(
                "Suppressed system-extension activation under XCTest trigger=\(trigger, privacy: .public)"
            )
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: requestQueue
        )
        let context = SystemExtensionLogContext(
            operationID: diagnosticOperationID(),
            action: "activation",
            trigger: trigger,
            configurationTrigger: configurationTrigger,
            startedAt: Date(),
            stateGeneration: stateGeneration
        )
        systemExtensionLogRegistry.register(context, for: request)
        request.delegate = self
        MacEnforcementLog.lifecycle.notice(
            "System-extension request submitted op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) trigger=\(context.trigger, privacy: .public) identifier=\(identifier, privacy: .public)"
        )
        var traceFields = DesktopDiagnosticTrace.runtimeEvidence()
        traceFields["operation_id"] = context.operationID
        traceFields["action"] = context.action
        traceFields["trigger"] = context.trigger
        traceFields["state_generation"] = stateGeneration
        DesktopDiagnosticTrace.record(
            component: "system-extension",
            event: "request_submitted",
            fields: traceFields
        )
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func submitEnabledPropertiesVerification(
        _ identifier: String,
        trigger: String,
        configurationTrigger: NetworkFilterConfigurationTrigger,
        stateGeneration: UInt64
    ) {
        guard !Self.isRunningTests else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: identifier,
            queue: requestQueue
        )
        let context = SystemExtensionLogContext(
            operationID: diagnosticOperationID(),
            action: "activation-properties",
            trigger: trigger,
            configurationTrigger: configurationTrigger,
            startedAt: Date(),
            stateGeneration: stateGeneration
        )
        systemExtensionLogRegistry.register(context, for: request)
        request.delegate = self
        MacEnforcementLog.lifecycle.notice(
            "System-extension request submitted op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) trigger=\(trigger, privacy: .public) identifier=\(identifier, privacy: .public) expectedBuild=\(Self.providerBuild, privacy: .public)"
        )
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func submitFinalEnabledPropertiesVerification(
        for mutation: FilterPreferenceMutation,
        manager: NEFilterManager,
        preferenceOperationID: String,
        preferenceStartedAt: Date
    ) {
        guard let activationGeneration = mutation.goal.activationGeneration,
              currentActivationAttempt(generation: activationGeneration) != nil,
              activePreferenceMutation?.generation == mutation.generation,
              mutation.generation == preferenceGeneration else {
            rejectEnabledPreferenceBeforeSave(
                mutation,
                operationID: preferenceOperationID,
                startedAt: preferenceStartedAt,
                reason: "activation-authority-stale-before-final-verification"
            )
            return
        }

        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: DesktopEnforcementConstants.webFilterExtensionIdentifier,
            queue: requestQueue
        )
        let context = SystemExtensionLogContext(
            operationID: diagnosticOperationID(),
            action: "final-enable-properties",
            trigger: mutation.goal.triggerDescription,
            configurationTrigger: nil,
            startedAt: Date(),
            stateGeneration: activationGeneration,
            preferenceGeneration: mutation.generation
        )
        pendingFinalEnableVerification = PendingFinalEnableVerification(
            requestOperationID: context.operationID,
            mutation: mutation,
            manager: manager,
            preferenceOperationID: preferenceOperationID,
            preferenceStartedAt: preferenceStartedAt
        )
        armPreferenceMutationDeadline(
            mutation, operationID: preferenceOperationID, stage: .verifyingExtension
        )
        systemExtensionLogRegistry.register(context, for: request)
        request.delegate = self
        MacEnforcementLog.lifecycle.notice(
            "System-extension request submitted op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) trigger=\(context.trigger, privacy: .public) preferenceGeneration=\(mutation.generation, privacy: .public) stateGeneration=\(activationGeneration, privacy: .public) expectedBuild=\(Self.providerBuild, privacy: .public)"
        )
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func armActivationEvidenceDeadline(generation: UInt64) {
        activationEvidenceDeadlineTask?.cancel()
        cancelActivationPropertiesRetry(reason: "new-activation-evidence-deadline")
        activationEvidenceDeadlineGeneration = generation
        MacEnforcementLog.lifecycle.notice(
            "System-extension activation evidence deadline armed stateGeneration=\(generation, privacy: .public) deadlineMs=\(Int(Self.activationEvidenceDeadline * 1_000), privacy: .public) preferenceConfirmedDisabled=true"
        )
        activationEvidenceDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.activationEvidenceDeadline * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.activationEvidenceDeadlineGeneration == generation,
                  self.activationRequestGeneration == generation,
                  self.currentActivationAttempt(generation: generation) != nil else {
                return
            }
            self.activationEvidenceDeadlineTask = nil
            self.activationEvidenceDeadlineGeneration = nil
            self.cancelActivationPropertiesRetry(reason: "activation-evidence-timeout")
            MacEnforcementLog.lifecycle.fault(
                "System-extension activation evidence deadline expired stateGeneration=\(generation, privacy: .public) action=remain-disabled"
            )
            self.status = .failed("macOS has not confirmed filter activation.")
            self.reportRecoveryWarning(
                trigger: "system-extension-activation-evidence-timeout",
                message: "Activation is still unconfirmed. Check System Settings and retry, or use the passage to cancel all web blocking."
            )
        }
    }

    private func cancelActivationEvidenceDeadline(reason: String) {
        cancelActivationPropertiesRetry(reason: reason)
        guard let generation = activationEvidenceDeadlineGeneration else { return }
        activationEvidenceDeadlineTask?.cancel()
        activationEvidenceDeadlineTask = nil
        activationEvidenceDeadlineGeneration = nil
        MacEnforcementLog.lifecycle.notice(
            "System-extension activation evidence deadline cleared stateGeneration=\(generation, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func scheduleActivationPropertiesRetry(
        trigger: String,
        configurationTrigger: NetworkFilterConfigurationTrigger,
        stateGeneration: UInt64,
        observedState: MacFilterActivationPropertiesState
    ) {
        guard activationEvidenceDeadlineGeneration == stateGeneration,
              activationRequestGeneration == stateGeneration,
              currentActivationAttempt(generation: stateGeneration) != nil else {
            return
        }

        switch observedState {
        case .awaitingUserApproval, .installedDisabled:
            status = .awaitingApproval
            deliveryError = "macOS installed the current Network Extension but it is turned off. Enable it in System Settings > General > Login Items & Extensions > Network Extensions; this app will continue automatically."
        case .unavailable:
            status = .activating
            deliveryError = "macOS is still registering the current Network Extension. Web blocking remains safely off while this app checks again automatically."
        case .enabled:
            return
        }
        activationPropertiesRetryTask?.cancel()
        activationPropertiesRetryGeneration = stateGeneration
        MacEnforcementLog.lifecycle.notice(
            "System-extension activation evidence pending stateGeneration=\(stateGeneration, privacy: .public) observedState=\(observedState.rawValue, privacy: .public) retryDelayMs=\(Int(Self.activationPropertiesRetryDelay * 1_000), privacy: .public) preferenceConfirmedDisabled=true"
        )

        activationPropertiesRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.activationPropertiesRetryDelay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.activationPropertiesRetryGeneration == stateGeneration,
                  self.activationEvidenceDeadlineGeneration == stateGeneration,
                  self.activationRequestGeneration == stateGeneration,
                  self.currentActivationAttempt(generation: stateGeneration) != nil else {
                return
            }
            self.activationPropertiesRetryTask = nil
            self.activationPropertiesRetryGeneration = nil
            self.submitEnabledPropertiesVerification(
                DesktopEnforcementConstants.webFilterExtensionIdentifier,
                trigger: trigger,
                configurationTrigger: configurationTrigger,
                stateGeneration: stateGeneration
            )
        }
    }

    private func cancelActivationPropertiesRetry(reason: String) {
        guard let generation = activationPropertiesRetryGeneration else { return }
        activationPropertiesRetryTask?.cancel()
        activationPropertiesRetryTask = nil
        activationPropertiesRetryGeneration = nil
        MacEnforcementLog.lifecycle.notice(
            "System-extension activation evidence retry cancelled stateGeneration=\(generation, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    // MARK: - Removal

    /// Removes the installed Network Extension after the user enters the fixed
    /// eighty-word acknowledgement. Unlike a rule-lock delay, this escape hatch
    /// stays available while filtering is already disabled or unhealthy.
    @discardableResult
    func removeNetworkExtension(
        passage: String
    ) -> DesktopNetworkExtensionRemovalGate.Validation {
        guard !isRemoving else {
            MacEnforcementLog.lifecycle.notice(
                "System-extension removal request ignored reason=already-in-progress"
            )
            return .authorized
        }
        let validation = DesktopNetworkExtensionRemovalGate.validate(typedPassage: passage)
        guard validation == .authorized else {
            MacEnforcementLog.lifecycle.error(
                "System-extension removal rejected reason=passage-mismatch expectedWords=\(DesktopNetworkExtensionRemovalGate.requiredWordCount, privacy: .public)"
            )
            return validation
        }

        MacEnforcementLog.lifecycle.notice(
            "System-extension removal authorized method=fixed-passage words=\(DesktopNetworkExtensionRemovalGate.requiredWordCount, privacy: .public) action=disable-then-deactivate"
        )
        beginAuthorizedRemoval()
        return .authorized
    }

    /// Opens the uninstall gate. Nothing is torn down here: the request is
    /// recorded and enforcement continues untouched for the whole delay.
    ///
    /// If a request is already pending, the existing one stands. Re-requesting
    /// must not restart anything, or the wait could be reset to dodge an
    /// expiring window — and it must not re-roll the passage for a shorter one.
    @discardableResult
    func beginRemoval() -> DesktopRemovalGate.State {
        if removalStore.load() == nil {
            let request = DesktopRemovalGate.makeRequest(for: latestPolicy)
            try? removalStore.save(request)
        }
        refreshRemovalState()
        return removalState
    }

    /// Always available, at any point in the wait. The delay exists to slow an
    /// impulse down, not to trap the user, and an easy cancel is what makes the
    /// gate tolerable enough to leave switched on.
    func cancelRemoval() {
        removalStore.clear()
        refreshRemovalState()
    }

    /// Completes an uninstall that has served its delay. macOS may additionally
    /// require administrator approval to deactivate the extension.
    ///
    /// Returns false — changing nothing — unless the gate is open and the
    /// passage matches. Emergency pause is the separate, intentionally
    /// immediate path that disables filtering without uninstalling it.
    @discardableResult
    func completeRemoval(passage: String) -> Bool {
        guard let request = removalStore.load() else { return false }
        guard case .ready = DesktopRemovalGate.state(for: request) else {
            refreshRemovalState()
            return false
        }
        guard DesktopRemovalGate.passageMatches(passage, request: request) else { return false }

        beginAuthorizedRemoval()
        return true
    }

    private func beginAuthorizedRemoval() {
        if isResettingEnforcement,
           let attemptIdentifier = sameBootResetAttemptIdentifier {
            failSameBootReset(
                attemptIdentifier: attemptIdentifier,
                generation: sameBootResetGeneration,
                message: "The reset stopped because Network Extension removal was requested. Blocking remains disabled."
            )
        }
        removalStore.clear()
        refreshRemovalState()
        isRemoving = true
        desiredStateGeneration &+= 1
        cancelStartupWatchdog(reason: "authorized-removal")
        cancelRetryGuardPreparation(reason: "authorized-removal")
        cancelActivationEvidenceDeadline(reason: "authorized-removal")
        invalidateVerifiedActivation(reason: "authorized-removal")
        status = .disabling
        isBlockingDisabled = true
        UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
        pendingActivationTrigger = nil
        activationRequestGeneration = nil
        pendingDeactivationAfterDisable = true
        disableNetworkFilter(trigger: "authorized-removal")
    }

    private func submitPendingDeactivation() {
        guard isRemoving, pendingDeactivationAfterDisable else { return }
        pendingDeactivationAfterDisable = false
        let deactivation = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: DesktopEnforcementConstants.webFilterExtensionIdentifier,
            queue: requestQueue
        )
        let context = SystemExtensionLogContext(
            operationID: diagnosticOperationID(),
            action: "deactivation",
            trigger: "authorized-removal",
            configurationTrigger: nil,
            startedAt: Date(),
            stateGeneration: desiredStateGeneration
        )
        systemExtensionLogRegistry.register(context, for: deactivation)
        deactivation.delegate = self
        MacEnforcementLog.lifecycle.notice(
            "System-extension request submitted op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) trigger=\(context.trigger, privacy: .public) identifier=\(DesktopEnforcementConstants.webFilterExtensionIdentifier, privacy: .public)"
        )
        OSSystemExtensionManager.shared.submitRequest(deactivation)
    }

    func refreshRemovalState() {
        removalState = DesktopRemovalGate.state(for: removalStore.load())
    }

    /// What the current rules would demand of an uninstall, for display before
    /// the user commits to starting the wait.
    var removalTerms: DesktopRemovalGate.Terms {
        DesktopRemovalGate.terms(for: latestPolicy)
    }

    /// True while an XCTest bundle is loaded into this process.
    ///
    /// The desktop suite is hostless precisely so this can never fire, but the
    /// guard stays: hosting the tests in this app once rewrote the live Network
    /// Extension configuration on the developer's own machine and restarted the
    /// content filter mid-run, which surfaced as
    /// `NEFilterErrorDomain Code=3 "configuration is stale"`. A test run must
    /// never be able to change what the machine is enforcing.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Errors that mean "your copy of the configuration is out of date, try
    /// again", not "this will never work".
    ///
    /// Both were observed live. `NEConfigurationErrorDomain` code 10
    /// ("permission denied") was logged at 17:39:34.474 in the same millisecond
    /// that `sysextd` began uninstalling the previous filter build for upgrade;
    /// `NEFilterErrorDomain` code 3 ("configuration is stale") came from a save
    /// racing a filter restart. Neither is a permanent condition — each is this
    /// process holding a snapshot that another process has just invalidated —
    /// and the correct response to both is to re-read the preferences and save
    /// once more.
    ///
    /// Retrying is cheap in the way that matters: a *failed* save does not
    /// restart the provider, so a retry costs nothing until it succeeds, at
    /// which point retrying stops. This is why a bounded retry here is safe
    /// while the old timer-driven `isEnabled` cycle was not.
    private static func isRetryableSaveError(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case "NEConfigurationErrorDomain":
            // 10 = permission denied (racing an extension install/upgrade).
            return error.code == 10
        case "NEFilterErrorDomain":
            // 3 = configuration is stale. 5 = permission denied while sysextd
            // is replacing the installed extension; both were observed live.
            return error.code == 3 || error.code == 5
        default:
            return false
        }
    }

    /// Hard cap. Deliberately small and deliberately not on a timer: this
    /// project has already shipped one repeating self-heal that wrote Network
    /// Extension configuration on a schedule, creating repeated provider
    /// restarts and leaving the extension disabled. Retries happen only in
    /// direct response to a failed save, and only this many times.
    private static let maximumSaveRetries = 2
    private static let saveRetryDelay: TimeInterval = 2
    private static let preferenceOperationDeadline: TimeInterval = 8
    private static let breakGlassPreferenceRemovalDeadline: TimeInterval = 8
    private static let activationEvidenceDeadline: TimeInterval = 60
    private static let activationPropertiesRetryDelay: TimeInterval = 2
    private static let lateEnableQuarantineDuration: TimeInterval = 30
    private static let lateEnableQuarantineProbeInterval: TimeInterval = 2
    private static let lateEnableQuarantineProbeDeadline: TimeInterval = 2
    private static let retryGuardPreparationDeadline: TimeInterval = 4
    private static let retryGuardSnapshotLifetime: TimeInterval = 30 * 60
    private static let retryGuardPreparationRecoveryDelay: TimeInterval = 2
    /// One first orphan claim may outlive the initial cleanup wait. This covers
    /// a complete quarantine, the final sweep's bounded wait for an existing
    /// removal owner, the final removal deadline, and one second of scheduling
    /// slack. Repeated failures cannot renew this budget.
    private static let sameBootResetOrphanedCleanupRemediationBudget: TimeInterval =
        lateEnableQuarantineDuration
        + breakGlassPreferenceRemovalDeadline + 1
        + breakGlassPreferenceRemovalDeadline
        + 1
    private static let sameBootResetCleanupObservationSlack: TimeInterval = 2
    private static let sameBootResetCleanupPollInterval: TimeInterval = 0.25
    private static let sameBootResetCleanupDeadline =
        sameBootResetOrphanedCleanupRemediationBudget
        + sameBootResetCleanupObservationSlack
    private static let sameBootResetPreferenceDeadline: TimeInterval = 8
    private static let sameBootResetDNSDeadline: TimeInterval = 3
    private static let sameBootResetHTTPSDeadline: TimeInterval = 5
    private static let sameBootResetConnectivityDomain = "example.com"

    private func configureNetworkFilter(
        retry: Int = 0,
        preparationRetry: Int = 0,
        trigger: NetworkFilterConfigurationTrigger = .policyUpdate,
        activationGeneration: UInt64,
        filterIsSuspendedForPreparation: Bool = false
    ) {
        guard !isBlockingDisabled, !isRemoving else {
            MacEnforcementLog.delivery.notice(
                "Network Extension configuration suppressed trigger=\(trigger.rawValue, privacy: .public) retry=\(retry, privacy: .public) reason=blocking-disabled"
            )
            return
        }
        guard let attempt = currentActivationAttempt(generation: activationGeneration) else {
            MacEnforcementLog.delivery.notice(
                "Network Extension configuration suppressed trigger=\(trigger.rawValue, privacy: .public) activationGeneration=\(activationGeneration, privacy: .public) currentGeneration=\(self.desiredStateGeneration, privacy: .public) reason=stale-activation-authority"
            )
            return
        }
        guard MacFilterActivationAuthorization.canBeginPreparation(
            for: attempt,
            disabledPreferenceProof: disabledPreferenceProof,
            propertiesProof: initialPropertiesProof,
            runtime: activationRuntimeState
        ) else {
            MacEnforcementLog.delivery.fault(
                "Network Extension configuration refused trigger=\(trigger.rawValue, privacy: .public) activationGeneration=\(activationGeneration, privacy: .public) reason=incomplete-activation-proof action=remove-preference-and-latch"
            )
            disableBlockingForSafety(trigger: "incomplete-activation-proof")
            return
        }
        guard !Self.isRunningTests else {
            deliveryError = "Filter configuration is suppressed under XCTest."
            MacEnforcementLog.delivery.debug(
                "Suppressed Network Extension configuration under XCTest trigger=\(trigger.rawValue, privacy: .public) retry=\(retry, privacy: .public)"
            )
            return
        }
        cancelRetryGuardPreparation(reason: "new-filter-configuration")
        retryGuardPreparationGeneration &+= 1
        let preparationGeneration = retryGuardPreparationGeneration
        let deliveredRevision = latestPolicy.revision
        let plan = MacFilterInterceptionPlan.make(for: latestPolicy, at: Date())

        guard plan.mode == .domainRules else {
            guard let completion = MacFilterActivationAuthorization.preparationCompletion(
                for: attempt,
                disabledPreferenceProof: disabledPreferenceProof,
                initialPropertiesProof: initialPropertiesProof,
                callbackPreparationGeneration: preparationGeneration,
                currentPreparationGeneration: retryGuardPreparationGeneration,
                runtime: activationRuntimeState
            ) else {
                disableBlockingForSafety(trigger: "bypass-preparation-authority-stale")
                return
            }
            enqueuePreparedNetworkFilter(
                policy: latestPolicy,
                preparedRetryGuards: nil,
                retry: retry,
                trigger: trigger,
                activationGeneration: activationGeneration,
                preparationGeneration: preparationGeneration,
                preparationCompletion: completion
            )
            return
        }

        guard filterIsSuspendedForPreparation else {
            lastDeliveryAttempt = Date()
            cancelStartupWatchdog(reason: "retry-guard-preparation-suspension")
            // Supersede an older enable immediately, before the asynchronous
            // DNS preflight begins. If its save is already in flight, this
            // suspension is serialized directly after it and is therefore the
            // last committed state before preparation.
            preferenceGeneration &+= 1
            enqueuePreferenceMutation(
                FilterPreferenceMutation(
                    generation: preferenceGeneration,
                    goal: .suspendedForPreparation(
                        revision: deliveredRevision,
                        trigger: trigger,
                        activationGeneration: activationGeneration,
                        retry: retry
                    )
                )
            )
            return
        }

        lastDeliveryAttempt = Date()
        MacEnforcementLog.delivery.notice(
            "Retry-guard preparation started generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(deliveredRevision, privacy: .public) requiredDomains=\(plan.retryGuardRequiredDomainSuffixes.count, privacy: .public) resolutionDomains=\(plan.retryGuardResolutionDomainSuffixes.count, privacy: .public) deadlineMs=\(Int(Self.retryGuardPreparationDeadline * 1_000), privacy: .public)"
        )
        retryGuardResolutionTask = retryGuardResolver.resolve(
            for: plan,
            timeout: Self.retryGuardPreparationDeadline
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.retryGuardPreparationFinished(
                    result,
                    plan: plan,
                    policyRevision: deliveredRevision,
                    preparationGeneration: preparationGeneration,
                    retry: retry,
                    preparationRetry: preparationRetry,
                    trigger: trigger,
                    activationGeneration: activationGeneration
                )
            }
        }
    }

    private func retryGuardPreparationFinished(
        _ result: MacFilterAsyncDNSResolutionResult,
        plan: MacFilterInterceptionPlan,
        policyRevision: UInt64,
        preparationGeneration: UInt64,
        retry: Int,
        preparationRetry: Int,
        trigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64
    ) {
        guard retryGuardPreparationGeneration == preparationGeneration,
              currentActivationAttempt(generation: activationGeneration) != nil,
              !isBlockingDisabled,
              !isRemoving,
              latestPolicy.revision == policyRevision else {
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation ignored generation=\(preparationGeneration, privacy: .public) currentGeneration=\(self.retryGuardPreparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) reason=state-changed"
            )
            return
        }
        retryGuardResolutionTask = nil

        guard !result.wasCancelled else {
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation ignored generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) reason=resolver-cancelled"
            )
            return
        }

        let currentPlan = MacFilterInterceptionPlan.make(for: latestPolicy, at: Date())
        guard currentPlan == plan else {
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation restarted generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) reason=plan-changed-during-resolution oldMode=\(plan.mode.rawValue, privacy: .public) newMode=\(currentPlan.mode.rawValue, privacy: .public)"
            )
            configureNetworkFilter(
                retry: retry,
                preparationRetry: preparationRetry,
                trigger: trigger,
                activationGeneration: activationGeneration,
                filterIsSuspendedForPreparation: true
            )
            return
        }

        guard let attempt = currentActivationAttempt(generation: activationGeneration),
              let completion = MacFilterActivationAuthorization.preparationCompletion(
                for: attempt,
                disabledPreferenceProof: disabledPreferenceProof,
                initialPropertiesProof: initialPropertiesProof,
                callbackPreparationGeneration: preparationGeneration,
                currentPreparationGeneration: retryGuardPreparationGeneration,
                runtime: activationRuntimeState
              ) else {
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation result discarded trigger=\(trigger.rawValue, privacy: .public) activationGeneration=\(activationGeneration, privacy: .public) preparationGeneration=\(preparationGeneration, privacy: .public) reason=stale-activation-authority"
            )
            return
        }

        let resolution = result.resolution.merging(
            retainedRetryGuardSnapshot?.reusableResolution(for: plan, at: Date()) ?? .init()
        )
        let retryGuards = resolution.retryGuards(for: plan)
        if !retryGuards.hasCompleteRequiredCoverage {
            let missing = retryGuards.missingRequiredDomainSuffixes.joined(separator: ",")
            if let retainedSnapshot = retainedRetryGuardSnapshot?.rebound(
                for: plan,
                policyRevision: policyRevision,
                at: Date()
            ) {
                MacEnforcementLog.delivery.notice(
                    "Retry-guard preparation incomplete generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) deadlineReached=\(result.didReachDeadline, privacy: .public) missingRequired=\(missing, privacy: .private) action=use-retained-validated-update-snapshot"
                )
                enqueuePreparedNetworkFilter(
                    policy: latestPolicy,
                    preparedRetryGuards: retainedSnapshot,
                    retry: retry,
                    trigger: trigger,
                    activationGeneration: activationGeneration,
                    preparationGeneration: preparationGeneration,
                    preparationCompletion: completion
                )
                return
            }
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation incomplete generation=\(preparationGeneration, privacy: .public) revision=\(policyRevision, privacy: .public) missingRequired=\(missing, privacy: .private) action=retry-without-persistent-disable"
            )
            let resuming = MacRetryGuardRecovery.shouldResumeNamedBlocking(after: preparationRetry)
            enforcementPreparationMessage = MacRetryGuardRecovery.preparationMessage(
                missing: retryGuards.missingRequiredDomainSuffixes, resuming: resuming
            )
            reportRecoveryWarning(
                trigger: "retry-guard-preparation-incomplete",
                message: MacRetryGuardRecovery.preparationMessage(
                    missing: retryGuards.missingRequiredDomainSuffixes, resuming: resuming
                )
            )
            if !resuming {
                scheduleRetryGuardPreparationRecovery(
                    retry: retry, preparationRetry: preparationRetry, trigger: trigger,
                    activationGeneration: activationGeneration, policyRevision: policyRevision
                )
                return
            }
            MacEnforcementLog.delivery.notice(
                "Retry-guard recovery degraded revision=\(policyRevision, privacy: .public) missing_count=\(retryGuards.missingRequiredDomainSuffixes.count, privacy: .public) action=resume-named-blocking-and-provider-dns-recovery"
            )
        }

        let preparedAt = Date()
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: policyRevision,
            plan: plan,
            resolution: resolution,
            preparedAt: preparedAt,
            validFor: Self.retryGuardSnapshotLifetime,
            permitsIncompleteCoverage: !retryGuards.hasCompleteRequiredCoverage
        )
        guard case .accepted = snapshot.validate(
            for: plan,
            policyRevision: policyRevision,
            at: preparedAt
        ) else {
            MacEnforcementLog.delivery.fault(
                "Retry-guard preparation validation failed generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) action=report-without-persistent-disable"
            )
            status = .failed("Blocked-site addresses could not be validated.")
            reportRecoveryWarning(trigger: "retry-guard-preparation-invalid", message: "The filter could not validate blocked-site addresses. Retry enforcement, or use the passage to disable all web blocks.")
            return
        }
        retainedRetryGuardSnapshot = snapshot

        MacEnforcementLog.delivery.notice(
            "Retry-guard preparation completed generation=\(preparationGeneration, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) revision=\(policyRevision, privacy: .public) deadlineReached=\(result.didReachDeadline, privacy: .public) requested=\(result.requestedDomainSuffixes.count, privacy: .public) settled=\(result.settledDomainSuffixes.count, privacy: .public) unresolvedHelpers=\(result.unresolvedDomainSuffixes.count, privacy: .public) installedAddresses=\(retryGuards.addresses.count, privacy: .public)"
        )
        enqueuePreparedNetworkFilter(
            policy: latestPolicy,
            preparedRetryGuards: snapshot,
            retry: retry,
            trigger: trigger,
            activationGeneration: activationGeneration,
            preparationGeneration: preparationGeneration,
            preparationCompletion: completion
        )
    }

    private func enqueuePreparedNetworkFilter(
        policy: DesktopEnforcementPolicy,
        preparedRetryGuards: MacFilterPreparedRetryGuardSnapshot?,
        retry: Int,
        trigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64,
        preparationGeneration: UInt64,
        preparationCompletion: MacFilterPreparationCompletion
    ) {
        guard let attempt = currentActivationAttempt(generation: activationGeneration),
              MacFilterActivationAuthorization.canBeginPreparation(
                for: attempt,
                disabledPreferenceProof: disabledPreferenceProof,
                propertiesProof: initialPropertiesProof,
                runtime: activationRuntimeState
              ),
              retryGuardPreparationGeneration == preparationGeneration else {
            MacEnforcementLog.delivery.notice(
                "Enabled Network Extension mutation not queued trigger=\(trigger.rawValue, privacy: .public) activationGeneration=\(activationGeneration, privacy: .public) preparationGeneration=\(preparationGeneration, privacy: .public) reason=stale-activation-or-preparation"
            )
            return
        }
        let deliveredRevision = policy.revision
        let vendorConfiguration: ImmutableVendorConfiguration
        do {
            vendorConfiguration = ImmutableVendorConfiguration(
                value: try DesktopPolicyConfigurationTransport.vendorConfiguration(
                    for: policy,
                    preparedRetryGuards: preparedRetryGuards
                )
            )
        } catch {
            let nsError = error as NSError
            MacEnforcementLog.delivery.error(
                "Policy encoding failed trigger=\(trigger.rawValue, privacy: .public) revision=\(deliveredRevision, privacy: .public) retry=\(retry, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)"
            )
            status = .failed("Could not encode the desktop policy: \(error.localizedDescription)")
            return
        }

        lastDeliveryAttempt = Date()
        cancelStartupWatchdog(reason: "new-enabled-preference-mutation")
        preferenceGeneration &+= 1
        let baselineProviderSessionID = FilterStatusStore.read()?.diagnostics?.sessionID
        enqueuePreferenceMutation(
            FilterPreferenceMutation(
                generation: preferenceGeneration,
                goal: .enabled(
                    revision: deliveredRevision,
                    vendorConfiguration: vendorConfiguration,
                    trigger: trigger,
                    activationGeneration: activationGeneration,
                    preparationGeneration: preparationGeneration,
                    preparationCompletion: preparationCompletion,
                    retry: retry
                ),
                baselineProviderSessionID: baselineProviderSessionID
            )
        )
    }

    private func persistActivationAttemptBeforeEnabledPreference(
        trigger: NetworkFilterConfigurationTrigger
    ) {
        guard !activationSafetyRequiresRestart else { return }
        let record = MacFilterActivationSafetyRecord(
            bootSessionIdentifier: Self.currentBootSessionIdentifier(),
            estimatedBootTime: Self.currentEstimatedBootTime(),
            triggeredAt: Date(),
            reason: "activation-attempt-in-flight:\(trigger.rawValue)"
        )
        Self.persistActivationSafetyRecord(record, defaults: .standard)
        hasPersistedActivationAttempt = true
        MacEnforcementLog.lifecycle.notice(
            "Network Extension in-flight activation record persisted trigger=\(trigger.rawValue, privacy: .public) revision=\(self.latestPolicy.revision, privacy: .public) action=enable-preference"
        )
    }

    private func cancelRetryGuardPreparation(reason: String) {
        retryGuardPreparationRecoveryTask?.cancel()
        retryGuardPreparationRecoveryTask = nil
        guard retryGuardResolutionTask != nil else { return }
        retryGuardResolutionTask?.cancel()
        retryGuardResolutionTask = nil
        MacEnforcementLog.delivery.notice(
            "Retry-guard preparation cancelled generation=\(self.retryGuardPreparationGeneration, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func retainExistingRetryGuardSnapshot(
        from vendorConfiguration: [String: Any]?,
        for plan: MacFilterInterceptionPlan,
        policyRevision: UInt64
    ) {
        guard let storedSnapshot = DesktopPolicyConfigurationTransport.preparedRetryGuards(
            from: vendorConfiguration
        ) else {
            return
        }
        // Keep per-domain evidence even if an added domain prevents exact-plan
        // rebinding. The reusable-resolution helper enforces expiry/scope.
        retainedRetryGuardSnapshot = storedSnapshot
        guard let reboundSnapshot = storedSnapshot.rebound(
            for: plan,
            policyRevision: policyRevision,
            at: Date()
        ) else {
            MacEnforcementLog.delivery.notice(
                "Stored retry-guard snapshot cannot be retained for update revision=\(policyRevision, privacy: .public) action=require-fresh-resolution"
            )
            return
        }
        retainedRetryGuardSnapshot = reboundSnapshot
        MacEnforcementLog.delivery.notice(
            "Stored retry-guard snapshot retained for update revision=\(policyRevision, privacy: .public) expiresAtMs=\(Int(reboundSnapshot.expiresAt.timeIntervalSince1970 * 1_000), privacy: .public)"
        )
    }

    private func scheduleRetryGuardPreparationRecovery(
        retry: Int,
        preparationRetry: Int,
        trigger: NetworkFilterConfigurationTrigger,
        activationGeneration: UInt64,
        policyRevision: UInt64
    ) {
        let nextPreparationRetry = preparationRetry + 1
        retryGuardPreparationRecoveryTask?.cancel()
        retryGuardPreparationRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.retryGuardPreparationRecoveryDelay * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self,
                  self.currentActivationAttempt(generation: activationGeneration) != nil,
                  !self.isBlockingDisabled,
                  !self.isRemoving,
                  self.latestPolicy.revision == policyRevision else {
                return
            }
            self.retryGuardPreparationRecoveryTask = nil
            MacEnforcementLog.delivery.notice(
                "Retry-guard update recovery retrying activationGeneration=\(activationGeneration, privacy: .public) revision=\(policyRevision, privacy: .public) attempt=\(nextPreparationRetry, privacy: .public)"
            )
            self.configureNetworkFilter(
                retry: retry,
                preparationRetry: nextPreparationRetry,
                trigger: trigger,
                activationGeneration: activationGeneration,
                filterIsSuspendedForPreparation: true
            )
        }
    }

    /// Shared entry point for authorized removal and the explicit immediate
    /// recovery switch. Disable is deliberately queued behind a save already
    /// in flight; generation fences and the bounded preference deadline ensure
    /// that a wedged framework callback cannot leave the filter enabled.
    private func disableNetworkFilter(trigger: String, retry: Int = 0) {
        guard isRemoving || isBlockingDisabled else { return }
        guard !Self.isRunningTests else {
            deliveryError = "Filter disable is suppressed under XCTest."
            status = .failed("Could not confirm that web blocking is disabled under XCTest.")
            MacEnforcementLog.delivery.debug(
                "Suppressed Network Extension disable under XCTest trigger=\(trigger, privacy: .public)"
            )
            return
        }
        preferenceGeneration &+= 1
        enqueuePreferenceMutation(
            FilterPreferenceMutation(
                generation: preferenceGeneration,
                goal: .disabled(trigger: trigger, retry: retry)
            )
        )
    }

    private func enqueuePreferenceMutation(_ mutation: FilterPreferenceMutation) {
        let replacedGeneration = preferenceQueue.enqueue(mutation)
        MacEnforcementLog.delivery.notice(
            "Network Extension preference mutation queued generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) retry=\(mutation.goal.retry, privacy: .public) activeGeneration=\(self.activePreferenceMutation?.generation ?? 0, privacy: .public) replacedPendingGeneration=\(replacedGeneration, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "network-extension-preference",
            event: "mutation_queued",
            fields: [
                "generation": mutation.generation,
                "target": mutation.goal.isEnabled ? "enabled" : "disabled",
                "trigger": mutation.goal.triggerDescription,
                "revision": mutation.goal.revision,
                "retry": mutation.goal.retry,
                "active_generation": activePreferenceMutation?.generation ?? 0,
                "replaced_generation": replacedGeneration
            ]
        )
        startNextPreferenceMutationIfNeeded()
    }

    private func startNextPreferenceMutationIfNeeded() {
        guard let mutation = preferenceQueue.startNextIfIdle() else { return }
        performPreferenceMutation(mutation)
    }

    private func performPreferenceMutation(_ mutation: FilterPreferenceMutation) {
        let startedAt = Date()
        let operationID = diagnosticOperationID()
        configurationOperations.insert(operationID)
        let target = mutation.goal.isEnabled ? "enabled" : "disabled"
        MacEnforcementLog.delivery.notice(
            "Network Extension preference mutation started op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) target=\(target, privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) retry=\(mutation.goal.retry, privacy: .public) inFlight=\(self.configurationOperations.count, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "network-extension-preference",
            event: "mutation_started",
            fields: [
                "operation_id": operationID,
                "generation": mutation.generation,
                "target": target,
                "trigger": mutation.goal.triggerDescription,
                "revision": mutation.goal.revision,
                "retry": mutation.goal.retry
            ]
        )
        armPreferenceMutationDeadline(mutation, operationID: operationID, stage: .loading)

        let manager = NEFilterManager.shared()
        MacEnforcementLog.delivery.debug(
            "Loading Network Extension preferences op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) target=\(target, privacy: .public)"
        )
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                self?.preferenceLoadFinished(
                    for: mutation,
                    manager: manager,
                    error: error,
                    operationID: operationID,
                    startedAt: startedAt
                )
            }
        }
    }

    private func preferenceLoadFinished(
        for mutation: FilterPreferenceMutation,
        manager: NEFilterManager,
        error: Error?,
        operationID: String,
        startedAt: Date
    ) {
        guard activePreferenceMutation?.generation == mutation.generation else {
            configurationOperations.remove(operationID)
            MacEnforcementLog.delivery.error(
                "Orphaned Network Extension preference callback ignored op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) activeGeneration=\(self.activePreferenceMutation?.generation ?? 0, privacy: .public)"
            )
            return
        }
        if let error {
            completePreferenceFailure(
                error,
                stage: .loadPreferences,
                mutation: mutation,
                operationID: operationID,
                startedAt: startedAt
            )
            return
        }

        // A newer desired state can arrive while the uncancellable load is in
        // progress. Do not start a write for a superseded snapshot.
        guard mutation.generation == preferenceGeneration else {
            completeSupersededPreferenceMutation(
                mutation,
                operationID: operationID,
                startedAt: startedAt,
                stage: "after-load"
            )
            return
        }

        if mutation.goal.isEnabled {
            submitFinalEnabledPropertiesVerification(
                for: mutation,
                manager: manager,
                preferenceOperationID: operationID,
                preferenceStartedAt: startedAt
            )
            return
        }

        applyLoadedPreferenceMutation(
            mutation,
            manager: manager,
            operationID: operationID,
            startedAt: startedAt,
            finalPropertiesProof: nil
        )
    }

    private func applyLoadedPreferenceMutation(
        _ mutation: FilterPreferenceMutation,
        manager: NEFilterManager,
        operationID: String,
        startedAt: Date,
        finalPropertiesProof: MacFilterExactBuildPropertiesProof?
    ) {
        if case let .enabled(
            _,
            _,
            _,
            activationGeneration,
            preparationGeneration,
            preparationCompletion,
            _
        ) = mutation.goal {
            guard let attempt = currentActivationAttempt(generation: activationGeneration),
                  lateEnableQuarantineAllowsEnabledPreference,
                  MacFilterActivationAuthorization.canSaveEnabledPreference(
                    for: attempt,
                    disabledPreferenceProof: disabledPreferenceProof,
                    finalPropertiesProof: finalPropertiesProof,
                    preparationCompletion: preparationCompletion,
                    currentPreparationGeneration: retryGuardPreparationGeneration,
                    runtime: activationRuntimeState
                  ),
                  preparationGeneration == retryGuardPreparationGeneration,
                  activePreferenceMutation?.generation == mutation.generation,
                  mutation.generation == preferenceGeneration else {
                rejectEnabledPreferenceBeforeSave(
                    mutation,
                    operationID: operationID,
                    startedAt: startedAt,
                    reason: "final-enable-authorization-rejected"
                )
                return
            }
        }

        let previousConfiguration = manager.providerConfiguration
        let storedRevision = DesktopPolicyConfigurationTransport.revision(
            from: previousConfiguration?.vendorConfiguration
        )
        let storedRevisionDescription = storedRevision.map(String.init) ?? "none"
        let wasEnabled = manager.isEnabled
        var configurationChanged = wasEnabled != mutation.goal.isEnabled

        if mutation.goal.isPreparationSuspension {
            retainExistingRetryGuardSnapshot(
                from: previousConfiguration?.vendorConfiguration,
                for: MacFilterInterceptionPlan.make(for: latestPolicy, at: Date()),
                policyRevision: mutation.goal.revision
            )
        }

        switch mutation.goal {
        case let .enabled(deliveredRevision, vendorConfiguration, _, _, _, _, _):
            configurationChanged = configurationChanged
                || previousConfiguration?.filterSockets != true
                || previousConfiguration?.filterPackets != false
                || manager.grade != .inspector
                || !Self.disablesSystemDefaultDrop(previousConfiguration)
                || previousConfiguration?.filterDataProviderBundleIdentifier
                    != DesktopEnforcementConstants.webFilterExtensionIdentifier
                || previousConfiguration?.filterPacketProviderBundleIdentifier != nil
                || storedRevision != deliveredRevision
                || !NSDictionary(
                    dictionary: previousConfiguration?.vendorConfiguration ?? [:]
                ).isEqual(to: vendorConfiguration.value)
                || manager.localizedDescription != "Holdfast Website Blocking"

            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = DesktopEnforcementConstants.webFilterExtensionIdentifier
            configuration.filterPacketProviderBundleIdentifier = nil
            configuration.vendorConfiguration = vendorConfiguration.value
            let disabledSystemDefaultDrop = Self.disableSystemDefaultDrop(on: configuration)
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Holdfast Website Blocking"
            // This provider classifies website destinations; it is not a
            // perimeter firewall. Inspector grade runs after firewall/VPN
            // processing and avoids installing this filter ahead of the Mac's
            // existing tunnel stack at the default firewall grade.
            manager.grade = .inspector
            if #available(macOS 15.0, *) {
                manager.disableEncryptedDNSSettings = false
            }
            guard disabledSystemDefaultDrop else {
                MacEnforcementLog.delivery.fault(
                    "System default-drop override unavailable action=refuse-enable-and-disable-filter"
                )
                disableBlockingImmediately(trigger: "system-default-drop-override-unavailable")
                deliveryError = "This macOS version could not enable the filter's fail-safe traffic bypass, so web blocking was left disabled to protect Internet access."
                completeSupersededPreferenceMutation(
                    mutation,
                    operationID: operationID,
                    startedAt: startedAt,
                    stage: "default-drop-override-unavailable"
                )
                return
            }
            manager.isEnabled = true

        case .disabledForActivation, .suspendedForPreparation, .disabled:
            // Preserve the installed provider configuration so a later enable
            // can restore it. Only the enabled bit changes during emergency
            // pause or the short retry-guard preparation handoff.
            manager.isEnabled = false

            if !wasEnabled {
                MacEnforcementLog.delivery.notice(
                    "Network Extension already disabled op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) storedRevision=\(storedRevisionDescription, privacy: .public) durationMs=\(diagnosticElapsedMilliseconds(since: startedAt), privacy: .public)"
                )
                completePreferenceSuccess(
                    mutation,
                    operationID: operationID,
                    startedAt: startedAt,
                    saveStartedAt: nil,
                    configurationChanged: false
                )
                return
            }
        }

        if !configurationChanged {
            MacEnforcementLog.delivery.notice(
                "Network Extension preferences already current op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) revision=\(mutation.goal.revision, privacy: .public)"
            )
            completePreferenceSuccess(
                mutation,
                operationID: operationID,
                startedAt: startedAt,
                saveStartedAt: nil,
                configurationChanged: false
            )
            return
        }

        MacEnforcementLog.delivery.notice(
            "Saving Network Extension preferences op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) retry=\(mutation.goal.retry, privacy: .public) storedRevision=\(storedRevisionDescription, privacy: .public) wasEnabled=\(wasEnabled, privacy: .public) configurationChanged=\(configurationChanged, privacy: .public)"
        )
        let savedConfigurationChanged = configurationChanged
        let saveStartedAt = Date()
        armPreferenceMutationDeadline(mutation, operationID: operationID, stage: .saving)
        if mutation.goal.isEnabled {
            if case let .enabled(_, _, trigger, _, _, _, _) = mutation.goal {
                persistActivationAttemptBeforeEnabledPreference(trigger: trigger)
            }
            outstandingEnabledPreferenceSaveOperations[operationID] =
                mutation.generation
            MacEnforcementLog.delivery.notice(
                "Enabled Network Extension save marked outstanding op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) outstanding=\(self.outstandingEnabledPreferenceSaveOperations.count, privacy: .public)"
            )
        }
        manager.saveToPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.completePreferenceFailure(
                        error,
                        stage: .savePreferences,
                        mutation: mutation,
                        operationID: operationID,
                        startedAt: startedAt
                    )
                } else {
                    self.completePreferenceSuccess(
                        mutation,
                        operationID: operationID,
                        startedAt: startedAt,
                        saveStartedAt: saveStartedAt,
                        configurationChanged: savedConfigurationChanged
                    )
                }
            }
        }
    }

    private func rejectEnabledPreferenceBeforeSave(
        _ mutation: FilterPreferenceMutation,
        operationID: String,
        startedAt: Date,
        reason: String
    ) {
        if pendingFinalEnableVerification?.mutation.generation == mutation.generation {
            pendingFinalEnableVerification = nil
        }
        MacEnforcementLog.delivery.fault(
            "Enabled Network Extension preference refused before save op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) activationGeneration=\(mutation.goal.activationGeneration ?? 0, privacy: .public) reason=\(reason, privacy: .public) action=refuse-write"
        )
        // No write has been submitted by this operation. In particular, an
        // expired proof after a slow properties reply is not a network outage.
        // Refuse the enable without converting a read failure into a latch.
        if outstandingEnabledPreferenceSaveOperations.isEmpty {
            status = .failed("The extension could not be verified before enabling. Retry Web Enforcement; no safety reset is required.")
            deliveryError = "The filter configuration was not written because its activation checks could not be confirmed."
            reportRecoveryWarning(
                trigger: "preference-read-timeout",
                message: "The extension must be verified again before the latest configuration can be enabled. Existing preferences were left unchanged."
            )
        } else {
            disableBlockingForSafety(trigger: reason)
            deliveryError = "An earlier enabled write is still unresolved. Run the safe enforcement reset before retrying."
        }
        completeSupersededPreferenceMutation(
            mutation,
            operationID: operationID,
            startedAt: startedAt,
            stage: reason
        )
    }

    /// macOS otherwise installs a persistent IP Drop-All layer for a socket
    /// content filter. On this Mac (with a pre-existing tunnel provider) that
    /// layer remained closed even though the data provider returned hundreds
    /// of `.allow()` verdicts. The property is present and KVC-compliant on the
    /// deployed OS but is not in the public SDK header, so capability-check it
    /// before use and keep the app source-compatible with earlier systems.
    private static func disableSystemDefaultDrop(
        on configuration: NEFilterProviderConfiguration
    ) -> Bool {
        let setter = NSSelectorFromString("setDisableDefaultDrop:")
        guard configuration.responds(to: setter) else { return false }
        configuration.setValue(true, forKey: "disableDefaultDrop")
        return disablesSystemDefaultDrop(configuration)
    }

    private static func disablesSystemDefaultDrop(
        _ configuration: NEFilterProviderConfiguration?
    ) -> Bool {
        guard let configuration,
              configuration.responds(to: NSSelectorFromString("disableDefaultDrop")) else {
            return false
        }
        return (configuration.value(forKey: "disableDefaultDrop") as? NSNumber)?.boolValue == true
    }

    private func completePreferenceSuccess(
        _ mutation: FilterPreferenceMutation,
        operationID: String,
        startedAt: Date,
        saveStartedAt: Date?,
        configurationChanged: Bool
    ) {
        let completedOutstandingEnabledSave =
            outstandingEnabledPreferenceSaveOperations.removeValue(
                forKey: operationID
            ) != nil
        configurationOperations.remove(operationID)
        if pendingFinalEnableVerification?.mutation.generation == mutation.generation {
            pendingFinalEnableVerification = nil
        }
        guard activePreferenceMutation?.generation == mutation.generation else {
            MacEnforcementLog.delivery.error(
                "Completed Network Extension preference mutation had no active owner op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public)"
            )
            if isBlockingDisabled, mutation.goal.isEnabled {
                beginBreakGlassPreferenceRemoval(trigger: "late-enable-save-callback")
            }
            return
        }
        cancelPreferenceMutationDeadline(for: mutation.generation)
        activePreferenceMutation = nil
        if completedOutstandingEnabledSave,
           mutation.goal.isEnabled,
           isBlockingDisabled || isRemoving {
            // The enabled write really committed after disabled intent won.
            // Remove it before the reset cleanup lane can call the system idle.
            beginBreakGlassPreferenceRemoval(
                trigger: "enabled-save-completed-while-disabled"
            )
        }
        let isCurrent = mutation.generation == preferenceGeneration
        let saveDuration = saveStartedAt.map(diagnosticElapsedMilliseconds(since:)) ?? 0
        MacEnforcementLog.delivery.notice(
            "Network Extension preferences saved op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) current=\(isCurrent, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) retry=\(mutation.goal.retry, privacy: .public) saveDurationMs=\(saveDuration, privacy: .public) totalDurationMs=\(diagnosticElapsedMilliseconds(since: startedAt), privacy: .public) configurationChanged=\(configurationChanged, privacy: .public)"
        )

        if isCurrent {
            switch mutation.goal {
            case .enabled:
                guard !isBlockingDisabled, !isRemoving else { break }
                guard let activationGeneration = mutation.goal.activationGeneration,
                      currentActivationAttempt(generation: activationGeneration) != nil else {
                    MacEnforcementLog.delivery.fault(
                        "Enabled Network Extension preference completed without current activation authority generation=\(mutation.generation, privacy: .public) activationGeneration=\(mutation.goal.activationGeneration ?? 0, privacy: .public) action=remove-preference-and-latch"
                    )
                    disableBlockingForSafety(trigger: "enabled-preference-without-current-authority")
                    break
                }
                deliveryError = nil
                pendingActivationTrigger = nil
                status = .activating
                let notBefore = saveStartedAt ?? startedAt
                let attempt = MacFilterStartupWatchdogAttempt(
                    preferenceGeneration: mutation.generation,
                    expectedRevision: mutation.goal.revision,
                    expectedProviderBuild: Self.providerBuild,
                    notBefore: notBefore,
                    deadline: Date().addingTimeInterval(
                        MacFilterStartupWatchdog.readinessDeadline
                    ),
                    baselineSessionID: mutation.baselineProviderSessionID,
                    requiresFreshProviderStart: configurationChanged
                )
                // Only a matching ready heartbeat may promote the UI to active.
                // The system-extension activation callback is not readiness
                // evidence; macOS returned `.completed` for a disabled provider
                // during the live provider-less outage.
                armStartupWatchdog(attempt)

            case let .disabledForActivation(
                trigger,
                configurationTrigger,
                activationGeneration,
                _
            ):
                guard let attempt = currentActivationAttempt(
                    generation: activationGeneration
                ) else { break }
                let proof = MacFilterActivationAuthorization.disabledPreferenceProof(
                    for: attempt,
                    runtime: activationRuntimeState,
                    preferenceOperationSucceeded: true,
                    persistedPreferenceIsEnabled: false
                )
                guard MacFilterActivationAuthorization.canRequestSystemExtensionActivation(
                    for: attempt,
                    disabledPreferenceProof: proof,
                    runtime: activationRuntimeState
                ) else {
                    MacEnforcementLog.delivery.fault(
                        "System-extension activation refused after preference disable generation=\(mutation.generation, privacy: .public) activationGeneration=\(activationGeneration, privacy: .public) reason=disabled-preference-proof-rejected action=remove-preference-and-latch"
                    )
                    disableBlockingForSafety(trigger: "disabled-preference-proof-rejected")
                    break
                }
                disabledPreferenceProof = proof
                activationRequestGeneration = activationGeneration
                status = .activating
                armActivationEvidenceDeadline(generation: activationGeneration)
                submitActivation(
                    DesktopEnforcementConstants.webFilterExtensionIdentifier,
                    trigger: trigger,
                    configurationTrigger: configurationTrigger,
                    stateGeneration: activationGeneration
                )

            case .suspendedForPreparation:
                guard !isBlockingDisabled,
                      !isRemoving,
                      let activationGeneration = mutation.goal.activationGeneration,
                      currentActivationAttempt(generation: activationGeneration) != nil else { break }
                status = .activating
                scheduleRetryGuardPreparationAfterSuspension(
                    mutation,
                    waitForManagedHostsRelease: configurationChanged
                )

            case .disabled:
                guard isBlockingDisabled else { break }
                deliveryError = nil
                // Deactivation owns the removal UI. A disable callback arriving
                // after removal completes must never replace `.notInstalled`.
                if !isRemoving {
                    status = .disabled
                } else {
                    submitPendingDeactivation()
                }
            }
        }
        startNextPreferenceMutationIfNeeded()
    }

    private func completeSupersededPreferenceMutation(
        _ mutation: FilterPreferenceMutation,
        operationID: String,
        startedAt: Date,
        stage: String
    ) {
        configurationOperations.remove(operationID)
        if pendingFinalEnableVerification?.mutation.generation == mutation.generation {
            pendingFinalEnableVerification = nil
        }
        guard activePreferenceMutation?.generation == mutation.generation else { return }
        cancelPreferenceMutationDeadline(for: mutation.generation)
        activePreferenceMutation = nil
        MacEnforcementLog.delivery.notice(
            "Superseded Network Extension preference mutation skipped op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) currentGeneration=\(self.preferenceGeneration, privacy: .public) stage=\(stage, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) durationMs=\(diagnosticElapsedMilliseconds(since: startedAt), privacy: .public)"
        )
        startNextPreferenceMutationIfNeeded()
    }

    private func completePreferenceFailure(
        _ error: Error,
        stage: NetworkFilterDeliveryStage,
        mutation: FilterPreferenceMutation,
        operationID: String,
        startedAt: Date
    ) {
        outstandingEnabledPreferenceSaveOperations.removeValue(
            forKey: operationID
        )
        configurationOperations.remove(operationID)
        if pendingFinalEnableVerification?.mutation.generation == mutation.generation {
            pendingFinalEnableVerification = nil
        }
        guard activePreferenceMutation?.generation == mutation.generation else { return }
        cancelPreferenceMutationDeadline(for: mutation.generation)
        activePreferenceMutation = nil
        let nsError = error as NSError
        let isCurrent = mutation.generation == preferenceGeneration
        let retryable = Self.isRetryableSaveError(error)
        let enabledSaveCommitUncertain: Bool
        switch stage {
        case .savePreferences:
            enabledSaveCommitUncertain = mutation.goal.isEnabled
        case .loadPreferences:
            enabledSaveCommitUncertain = false
        }
        let willRetry = isCurrent
            && retryable
            && !enabledSaveCommitUncertain
            && mutation.goal.retry < Self.maximumSaveRetries
            && preferenceGoalIsStillDesired(mutation.goal)
        MacEnforcementLog.delivery.error(
            "Network Extension preference mutation failed op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) current=\(isCurrent, privacy: .public) stage=\(stage.rawValue, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) retry=\(mutation.goal.retry, privacy: .public) willRetry=\(willRetry, privacy: .public) durationMs=\(diagnosticElapsedMilliseconds(since: startedAt), privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)"
        )

        guard isCurrent else {
            startNextPreferenceMutationIfNeeded()
            return
        }

        let nextRetry = mutation.goal.retry + 1
        switch mutation.goal {
        case let .enabled(revision, _, _, _, _, _, _):
            deliveryError = willRetry
                ? "Revision \(revision) was not delivered; retrying \(nextRetry) of \(Self.maximumSaveRetries)."
                : "Revision \(revision) was not delivered: \(error.localizedDescription)"
            if !willRetry, enabledSaveCommitUncertain {
                status = .failed(error.localizedDescription)
                disableBlockingForSafety(trigger: "enabled-preference-operation-failed")
                if enabledSaveCommitUncertain {
                    beginLateEnablePreferenceQuarantine(
                        timedOutPreferenceGeneration: mutation.generation,
                        trigger: "enabled-preference-save-failed"
                    )
                }
                deliveryError = "The enabled filter preference could not be saved safely, so its preference was removed. Run the safe enforcement reset before retrying: \(error.localizedDescription)"
            } else if !willRetry {
                status = .failed("The filter configuration could not be read. Retry enabling; no safety reset is required.")
                reportRecoveryWarning(
                    trigger: "preference-read-timeout",
                    message: "macOS could not read the filter configuration. Existing preferences were left unchanged; retry enabling to deliver the latest changes."
                )
            }

        case .disabledForActivation:
            deliveryError = willRetry
                ? "Preparing a safe Network Extension activation; retrying \(nextRetry) of \(Self.maximumSaveRetries)."
                : "Could not confirm that the existing filter preference was disabled: \(error.localizedDescription)"
            if !willRetry {
                status = .failed(error.localizedDescription)
                disableBlockingForSafety(trigger: "pre-activation-preference-disable-failed")
                deliveryError = "The existing Network Extension preference could not be confirmed off, so its preference was removed. Run the safe enforcement reset before retrying: \(error.localizedDescription)"
            }

        case .suspendedForPreparation:
            deliveryError = willRetry
                ? "Preparing safe blocked-site retry guards; retrying \(nextRetry) of \(Self.maximumSaveRetries)."
                : "Could not pause the old filter safely before preparing retry guards: \(error.localizedDescription)"
            if !willRetry {
                disableBlockingImmediately(trigger: "retry-guard-preparation-suspension-failed")
                deliveryError = "The old filter could not be paused safely, so blocking was disabled to protect Internet access."
            }

        case .disabled:
            deliveryError = willRetry
                ? "Web blocking was not disabled; retrying \(nextRetry) of \(Self.maximumSaveRetries)."
                : "Could not disable web blocking: \(error.localizedDescription)"
            if !willRetry, isRemoving {
                // Deactivation is deliberately sequenced after a confirmed
                // preference disable. If that prerequisite fails, return the
                // UI to a retryable state instead of showing endless progress.
                isRemoving = false
                pendingDeactivationAfterDisable = false
            }
            status = willRetry
                ? .disabling
                : .failed("Could not confirm that web blocking is disabled: \(error.localizedDescription)")
        }

        guard willRetry else {
            if retryable, mutation.goal.retry >= Self.maximumSaveRetries {
                MacEnforcementLog.delivery.error(
                    "Network Extension preference retry limit reached generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) retries=\(mutation.goal.retry, privacy: .public)"
                )
            }
            startNextPreferenceMutationIfNeeded()
            return
        }

        MacEnforcementLog.delivery.notice(
            "Network Extension preference retry scheduled generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) nextRetry=\(nextRetry, privacy: .public) delayMs=\(Int(Self.saveRetryDelay * 1_000), privacy: .public)"
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveRetryDelay * 1_000_000_000))
            guard let self else { return }
            guard self.preferenceGeneration == mutation.generation,
                  self.activePreferenceMutation == nil,
                  self.pendingPreferenceMutation == nil,
                  self.preferenceGoalIsStillDesired(mutation.goal) else {
                MacEnforcementLog.delivery.notice(
                    "Network Extension preference retry cancelled generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) currentGeneration=\(self.preferenceGeneration, privacy: .public)"
                )
                return
            }
            self.enqueuePreferenceMutation(
                FilterPreferenceMutation(
                    generation: mutation.generation,
                    goal: mutation.goal.retrying(nextRetry),
                    baselineProviderSessionID: mutation.baselineProviderSessionID
                )
            )
        }
    }

    private func armPreferenceMutationDeadline(
        _ mutation: FilterPreferenceMutation,
        operationID: String,
        stage: MacFilterPreferenceTimeoutSafety.Stage
    ) {
        let timeoutTarget: MacFilterPreferenceTimeoutTarget
        switch mutation.goal {
        case .enabled:
            timeoutTarget = .enable
        case .disabledForActivation, .suspendedForPreparation:
            timeoutTarget = .preparationSuspension
        case .disabled:
            timeoutTarget = .explicitDisable
        }
        preferenceMutationDeadlineTask?.cancel()
        preferenceMutationDeadlineGeneration = mutation.generation
        let deadline = timeoutTarget == .explicitDisable
            ? Self.preferenceOperationDeadline : stage.deadline
        preferenceMutationDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(deadline * 1_000_000_000)
                )
            } catch {
                return
            }
            // A completed sleep may already be queued on the main actor when
            // the next stage replaces it using the same mutation generation.
            guard !Task.isCancelled, let self else { return }
            let action = MacFilterPreferenceTimeoutSafety.action(
                timedOutGeneration: mutation.generation,
                currentPreferenceGeneration: self.preferenceGeneration,
                armedDeadlineGeneration: self.preferenceMutationDeadlineGeneration,
                activeMutationGeneration: self.activePreferenceMutation?.generation,
                currentlyWantsDisabled: self.isBlockingDisabled || self.isRemoving,
                target: timeoutTarget,
                stage: stage,
                hasOutstandingEnabledSave: !self.outstandingEnabledPreferenceSaveOperations.isEmpty
            )
            guard action != .ignoreStaleOperation else { return }
            self.preferenceMutationDeadlineTask = nil
            self.preferenceMutationDeadlineGeneration = nil
            self.configurationOperations.remove(operationID)
            self.activePreferenceMutation = nil
            if self.pendingFinalEnableVerification?.mutation.generation == mutation.generation {
                self.pendingFinalEnableVerification = nil
            }
            MacEnforcementLog.delivery.fault(
                "Network Extension preference mutation timed out op=\(operationID, privacy: .public) generation=\(mutation.generation, privacy: .public) target=\(mutation.goal.isEnabled ? "enabled" : "disabled", privacy: .public) trigger=\(mutation.goal.triggerDescription, privacy: .public) revision=\(mutation.goal.revision, privacy: .public) stage=\(stage.rawValue, privacy: .public) deadlineMs=\(Int(deadline * 1_000), privacy: .public) action=\(String(describing: action), privacy: .public)"
            )
            DesktopDiagnosticTrace.record(
                component: "network-extension-preference",
                event: "mutation_timeout",
                fields: [
                    "operation_id": operationID, "generation": mutation.generation,
                    "stage": stage.rawValue, "deadline_seconds": deadline,
                    "action": String(describing: action), "retry": mutation.goal.retry,
                    "outstanding_enabled_saves": self.outstandingEnabledPreferenceSaveOperations.count
                ]
            )

            switch action {
            case .retryReadOnlyOperation:
                // Give retries a NEW generation: a late load from this attempt
                // must never be accepted as the retry's callback.
                if self.pendingPreferenceMutation == nil,
                   self.preferenceGeneration == mutation.generation,
                   self.preferenceGoalIsStillDesired(mutation.goal),
                   mutation.goal.retry < Self.maximumSaveRetries {
                    self.preferenceGeneration &+= 1
                    self.pendingPreferenceMutation = FilterPreferenceMutation(
                        generation: self.preferenceGeneration,
                        goal: mutation.goal.retrying(mutation.goal.retry + 1),
                        baselineProviderSessionID: mutation.baselineProviderSessionID
                    )
                }
                self.reportRecoveryWarning(
                    trigger: "preference-read-timeout",
                    message: "macOS is slow to confirm the filter configuration. No emergency reset is required. The latest changes may not yet be enforced; retry enabling if this persists."
                )
                self.deliveryError = "The filter configuration check timed out before any write. Existing preferences were left unchanged."
                if self.pendingPreferenceMutation == nil {
                    self.status = .failed("The filter configuration could not be confirmed. Retry enabling; no safety reset is required.")
                }
                self.startNextPreferenceMutationIfNeeded()
            case .removePreferenceAndRetryDisable:
                self.beginBreakGlassPreferenceRemoval(
                    trigger: "preference-disable-timeout"
                )
                // Keep trying the ordinary reversible disable path as well. Its
                // late callbacks are generation-fenced, while a successful
                // removeFromPreferences reconstructs cleanly on the next enable.
                if MacFilterPreferenceTimeoutSafety.shouldRetryExplicitDisable(
                    completedRetries: mutation.goal.retry,
                    maximumRetries: Self.maximumSaveRetries
                ) {
                    self.preferenceGeneration &+= 1
                    self.pendingPreferenceMutation = FilterPreferenceMutation(
                        generation: self.preferenceGeneration,
                        goal: .disabled(
                            trigger: "preference-disable-timeout-retry",
                            retry: mutation.goal.retry + 1
                        )
                    )
                    self.startNextPreferenceMutationIfNeeded()
                } else {
                    self.deliveryError = "Web blocking preferences stopped responding after \(Self.maximumSaveRetries) retries. Emergency preference removal is still protecting Internet access; use Retry Disable if it does not complete."
                    MacEnforcementLog.delivery.fault(
                        "Network Extension timed-out disable retry cap reached generation=\(mutation.generation, privacy: .public) retries=\(mutation.goal.retry, privacy: .public) breakGlassInFlight=\(self.isBreakGlassRemovalInFlight, privacy: .public)"
                    )
                    if !self.isBreakGlassRemovalInFlight {
                        if self.isRemoving {
                            self.isRemoving = false
                            self.pendingDeactivationAfterDisable = false
                        }
                        self.status = .failed("Could not confirm that web blocking is disabled after bounded recovery attempts.")
                    }
                }
            case .persistEmergencyDisable:
                self.disableBlockingForSafety(trigger: "preference-operation-timeout")
                if mutation.goal.isEnabled {
                    self.beginLateEnablePreferenceQuarantine(
                        timedOutPreferenceGeneration: mutation.generation,
                        trigger: "enabled-preference-operation-timeout"
                    )
                }
                self.deliveryError = "The Network Extension preferences stopped responding, so the preference was removed. Run the safe enforcement reset before retrying."
                self.startNextPreferenceMutationIfNeeded()
            case .ignoreStaleOperation:
                break
            }
        }
    }

    private func cancelPreferenceMutationDeadline(for generation: UInt64) {
        guard preferenceMutationDeadlineGeneration == generation else { return }
        preferenceMutationDeadlineTask?.cancel()
        preferenceMutationDeadlineTask = nil
        preferenceMutationDeadlineGeneration = nil
    }

    @discardableResult
    private func beginLateEnablePreferenceQuarantine(
        timedOutPreferenceGeneration: UInt64,
        trigger: String
    ) -> Bool {
        let now = Date()
        if let existing = lateEnablePreferenceQuarantine,
           !MacFilterLateEnableQuarantineSafety.allowsEnabledPreference(
               during: existing,
               currentGeneration: lateEnableQuarantineGeneration,
               currentBootSessionIdentifier: Self.currentBootSessionIdentifier(),
               now: now
           ) {
            MacEnforcementLog.delivery.notice(
                "Late-enable preference quarantine already active quarantineGeneration=\(existing.generation, privacy: .public) originalPreferenceGeneration=\(self.lateEnableQuarantineTimedOutPreferenceGeneration ?? 0, privacy: .public) additionalPreferenceGeneration=\(timedOutPreferenceGeneration, privacy: .public) trigger=\(trigger, privacy: .public)"
            )
            return false
        }

        lateEnableQuarantineGeneration &+= 1
        guard let quarantine = MacFilterLateEnableQuarantineSafety.start(
            generation: lateEnableQuarantineGeneration,
            bootSessionIdentifier: Self.currentBootSessionIdentifier(),
            now: now,
            gracePeriod: Self.lateEnableQuarantineDuration,
            retryInterval: Self.lateEnableQuarantineProbeInterval
        ) else {
            MacEnforcementLog.delivery.fault(
                "Late-enable preference quarantine could not start quarantineGeneration=\(self.lateEnableQuarantineGeneration, privacy: .public) timedOutPreferenceGeneration=\(timedOutPreferenceGeneration, privacy: .public) trigger=\(trigger, privacy: .public) action=activation-remains-latched"
            )
            return false
        }
        lateEnablePreferenceQuarantine = quarantine
        lateEnableQuarantineTimedOutPreferenceGeneration = timedOutPreferenceGeneration
        lateEnableQuarantineTask?.cancel()
        lateEnableQuarantineProbeDeadlineTask?.cancel()
        lateEnableQuarantineProbeOperationID = nil
        lateEnableQuarantineProbeAttemptSequence = nil
        MacEnforcementLog.delivery.fault(
            "Late-enable preference quarantine started quarantineGeneration=\(quarantine.generation, privacy: .public) timedOutPreferenceGeneration=\(timedOutPreferenceGeneration, privacy: .public) trigger=\(trigger, privacy: .public) durationMs=\(Int(Self.lateEnableQuarantineDuration * 1_000), privacy: .public) intervalMs=\(Int(Self.lateEnableQuarantineProbeInterval * 1_000), privacy: .public) action=verify-and-remove"
        )
        driveLateEnablePreferenceQuarantine()
        return true
    }

    private var lateEnableQuarantineStillWantsDisabled: Bool {
        activationSafetyRequiresRestart && isBlockingDisabled
    }

    private func driveLateEnablePreferenceQuarantine(now: Date = Date()) {
        guard let quarantine = lateEnablePreferenceQuarantine else { return }
        let transition = MacFilterLateEnableQuarantineSafety.advance(
            quarantine,
            currentGeneration: lateEnableQuarantineGeneration,
            currentBootSessionIdentifier: Self.currentBootSessionIdentifier(),
            stillWantsDisabled: lateEnableQuarantineStillWantsDisabled,
            now: now
        )
        applyLateEnableQuarantineTransition(
            transition,
            previousState: quarantine,
            now: now
        )
    }

    private func applyLateEnableQuarantineTransition(
        _ transition: MacFilterLateEnableQuarantineTransition,
        previousState: MacFilterLateEnableQuarantineState,
        now: Date
    ) {
        // The pure policy requires callers to retain the claimed attempt before
        // starting asynchronous work. This assignment is therefore deliberately
        // before the command switch.
        lateEnablePreferenceQuarantine = transition.state
        switch transition.command {
        case let .wait(until):
            scheduleLateEnableQuarantineAdvance(
                generation: previousState.generation,
                at: until
            )

        case let .verifyAndRemove(attemptSequence):
            startLateEnableQuarantineProbe(
                generation: previousState.generation,
                attemptSequence: attemptSequence
            )

        case .ignoreStaleAttempt:
            MacEnforcementLog.delivery.notice(
                "Late-enable preference quarantine ignored stale attempt quarantineGeneration=\(previousState.generation, privacy: .public)"
            )

        case .cancel:
            clearLateEnableQuarantineScheduling()
            MacEnforcementLog.delivery.fault(
                "Late-enable preference quarantine cancelled quarantineGeneration=\(previousState.generation, privacy: .public) activationStillLatched=\(self.activationSafetyRequiresRestart, privacy: .public)"
            )

        case .finished:
            finishLateEnablePreferenceQuarantine(previousState, now: now)
        }
    }

    private func scheduleLateEnableQuarantineAdvance(
        generation: UInt64,
        at date: Date
    ) {
        lateEnableQuarantineTask?.cancel()
        lateEnableQuarantineTask = Task { @MainActor [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            if delay > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.lateEnablePreferenceQuarantine?.generation == generation,
                  self.lateEnableQuarantineGeneration == generation else { return }
            self.lateEnableQuarantineTask = nil
            self.driveLateEnablePreferenceQuarantine()
        }
    }

    private func startLateEnableQuarantineProbe(
        generation: UInt64,
        attemptSequence: UInt64
    ) {
        guard let quarantine = lateEnablePreferenceQuarantine,
              quarantine.generation == generation,
              quarantine.activeAttemptSequence == attemptSequence,
              lateEnableQuarantineGeneration == generation,
              lateEnableQuarantineStillWantsDisabled else { return }
        guard !isBreakGlassRemovalInFlight,
              lateEnableQuarantineProbeOperationID == nil else {
            // An existing removal is already the desired action. Count this
            // scheduler attempt as complete and verify again after the interval.
            completeLateEnableQuarantineAttempt(
                generation: generation,
                attemptSequence: attemptSequence
            )
            return
        }
        let operationID = diagnosticOperationID()
        lateEnableQuarantineProbeOperationID = operationID
        lateEnableQuarantineProbeAttemptSequence = attemptSequence
        let manager = NEFilterManager.shared()
        MacEnforcementLog.delivery.notice(
            "Late-enable preference quarantine probe started quarantineGeneration=\(generation, privacy: .public) attempt=\(attemptSequence, privacy: .public) op=\(operationID, privacy: .public) timedOutPreferenceGeneration=\(self.lateEnableQuarantineTimedOutPreferenceGeneration ?? 0, privacy: .public)"
        )
        lateEnableQuarantineProbeDeadlineTask?.cancel()
        lateEnableQuarantineProbeDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.lateEnableQuarantineProbeDeadline * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self,
                  self.lateEnablePreferenceQuarantine?.generation == generation,
                  self.lateEnableQuarantineProbeOperationID == operationID,
                  self.lateEnableQuarantineProbeAttemptSequence == attemptSequence else {
                return
            }
            self.lateEnableQuarantineProbeOperationID = nil
            self.lateEnableQuarantineProbeAttemptSequence = nil
            self.lateEnableQuarantineProbeDeadlineTask = nil
            MacEnforcementLog.delivery.fault(
                "Late-enable preference quarantine probe timed out quarantineGeneration=\(generation, privacy: .public) attempt=\(attemptSequence, privacy: .public) op=\(operationID, privacy: .public) action=remove-preference"
            )
            self.beginBreakGlassPreferenceRemoval(
                trigger: "late-enable-quarantine-probe-timeout"
            )
            self.completeLateEnableQuarantineAttempt(
                generation: generation,
                attemptSequence: attemptSequence
            )
        }
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.lateEnablePreferenceQuarantine?.generation == generation,
                      self.lateEnableQuarantineProbeOperationID == operationID,
                      self.lateEnableQuarantineProbeAttemptSequence == attemptSequence else {
                    return
                }
                self.lateEnableQuarantineProbeDeadlineTask?.cancel()
                self.lateEnableQuarantineProbeDeadlineTask = nil
                self.lateEnableQuarantineProbeOperationID = nil
                self.lateEnableQuarantineProbeAttemptSequence = nil
                if let error {
                    let nsError = error as NSError
                    MacEnforcementLog.delivery.fault(
                        "Late-enable preference quarantine probe failed quarantineGeneration=\(generation, privacy: .public) attempt=\(attemptSequence, privacy: .public) op=\(operationID, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) action=remove-preference"
                    )
                    self.beginBreakGlassPreferenceRemoval(
                        trigger: "late-enable-quarantine-probe-failed"
                    )
                    self.completeLateEnableQuarantineAttempt(
                        generation: generation,
                        attemptSequence: attemptSequence
                    )
                    return
                }
                let preferencePresent = manager.isEnabled
                    || manager.providerConfiguration != nil
                if preferencePresent {
                    MacEnforcementLog.delivery.fault(
                        "Late-enable preference quarantine detected reappearing preference quarantineGeneration=\(generation, privacy: .public) attempt=\(attemptSequence, privacy: .public) op=\(operationID, privacy: .public) enabled=\(manager.isEnabled, privacy: .public) action=remove-preference"
                    )
                    self.beginBreakGlassPreferenceRemoval(
                        trigger: "late-enable-quarantine-detected-preference"
                    )
                } else {
                    MacEnforcementLog.delivery.notice(
                        "Late-enable preference quarantine probe verified absent quarantineGeneration=\(generation, privacy: .public) attempt=\(attemptSequence, privacy: .public) op=\(operationID, privacy: .public)"
                    )
                }
                self.completeLateEnableQuarantineAttempt(
                    generation: generation,
                    attemptSequence: attemptSequence
                )
            }
        }
    }

    private func completeLateEnableQuarantineAttempt(
        generation: UInt64,
        attemptSequence: UInt64,
        now: Date = Date()
    ) {
        guard let quarantine = lateEnablePreferenceQuarantine else { return }
        let transition = MacFilterLateEnableQuarantineSafety.completeAttempt(
            quarantine,
            attemptSequence: attemptSequence,
            currentGeneration: lateEnableQuarantineGeneration,
            currentBootSessionIdentifier: Self.currentBootSessionIdentifier(),
            stillWantsDisabled: lateEnableQuarantineStillWantsDisabled,
            now: now
        )
        applyLateEnableQuarantineTransition(
            transition,
            previousState: quarantine,
            now: now
        )
    }

    private func finishLateEnablePreferenceQuarantine(
        _ quarantine: MacFilterLateEnableQuarantineState,
        now: Date
    ) {
        let currentBootSessionIdentifier = Self.currentBootSessionIdentifier()
        let definiteBootChange: Bool
        if let recorded = quarantine.bootSessionIdentifier,
           let current = currentBootSessionIdentifier {
            definiteBootChange = recorded != current
        } else {
            definiteBootChange = false
        }
        let shouldSubmitFinalSweep = !definiteBootChange
            && now >= quarantine.deadline
            && lateEnableQuarantineStillWantsDisabled
        let timedOutPreferenceGeneration = lateEnableQuarantineTimedOutPreferenceGeneration ?? 0
        clearLateEnableQuarantineScheduling()

        guard shouldSubmitFinalSweep else {
            MacEnforcementLog.delivery.notice(
                "Late-enable preference quarantine finished without final sweep quarantineGeneration=\(quarantine.generation, privacy: .public) timedOutPreferenceGeneration=\(timedOutPreferenceGeneration, privacy: .public) definiteBootChange=\(definiteBootChange, privacy: .public) activationStillLatched=\(self.activationSafetyRequiresRestart, privacy: .public)"
            )
            return
        }

        let finalSweepGeneration = quarantine.generation
        lateEnableQuarantineTask = Task { @MainActor [weak self] in
            let waitDeadline = Date().addingTimeInterval(
                Self.breakGlassPreferenceRemovalDeadline + 1
            )
            while let self,
                  self.lateEnableQuarantineGeneration == finalSweepGeneration,
                  self.isBreakGlassRemovalInFlight,
                  Date() < waitDeadline,
                  !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.lateEnableQuarantineGeneration == finalSweepGeneration,
                  self.lateEnableQuarantineStillWantsDisabled else { return }
            if self.isBreakGlassRemovalInFlight {
                // The ordinary removal deadline should already have fenced this
                // operation. Fence it here as a last resort so the required
                // post-grace removal is still submitted and becomes the newest
                // preference operation.
                let supersededOperationID = self.breakGlassRemovalOperationID
                self.breakGlassRemovalDeadlineTask?.cancel()
                self.breakGlassRemovalDeadlineTask = nil
                self.breakGlassRemovalOperationID = nil
                self.isBreakGlassRemovalInFlight = false
                MacEnforcementLog.delivery.fault(
                    "Late-enable preference quarantine final sweep superseded stuck removal quarantineGeneration=\(finalSweepGeneration, privacy: .public) oldOp=\(supersededOperationID ?? "unknown", privacy: .public)"
                )
            }
            self.beginBreakGlassPreferenceRemoval(
                trigger: "late-enable-quarantine-final-sweep"
            )
            self.lateEnableQuarantineTask = nil
            MacEnforcementLog.delivery.fault(
                "Late-enable preference quarantine grace completed quarantineGeneration=\(finalSweepGeneration, privacy: .public) timedOutPreferenceGeneration=\(timedOutPreferenceGeneration, privacy: .public) action=final-removal-submitted activationStillLatched=\(self.activationSafetyRequiresRestart, privacy: .public)"
            )
        }
    }

    private func clearLateEnableQuarantineScheduling() {
        lateEnableQuarantineTask?.cancel()
        lateEnableQuarantineTask = nil
        lateEnableQuarantineProbeDeadlineTask?.cancel()
        lateEnableQuarantineProbeDeadlineTask = nil
        lateEnableQuarantineProbeOperationID = nil
        lateEnableQuarantineProbeAttemptSequence = nil
        lateEnablePreferenceQuarantine = nil
        lateEnableQuarantineTimedOutPreferenceGeneration = nil
    }

    /// `saveToPreferences` is normally the least destructive emergency switch,
    /// but its callback is not guaranteed. Removing only the NE preference is a
    /// final availability escape hatch; the signed system extension and all app
    /// rules remain installed, and the next explicit enable reconstructs it.
    private func beginBreakGlassPreferenceRemoval(trigger: String) {
        guard isBlockingDisabled || isRemoving,
              !isBreakGlassRemovalInFlight else { return }
        isBreakGlassRemovalInFlight = true
        let operationID = diagnosticOperationID()
        breakGlassRemovalOperationID = operationID
        armBreakGlassPreferenceRemovalDeadline(
            operationID: operationID,
            trigger: trigger
        )
        let manager = NEFilterManager.shared()
        MacEnforcementLog.delivery.fault(
            "Network Extension break-glass removal started op=\(operationID, privacy: .public) trigger=\(trigger, privacy: .public)"
        )
        manager.removeFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard MacFilterPreferenceTimeoutSafety.acceptsBreakGlassCompletion(
                    operationID: operationID,
                    activeOperationID: self.breakGlassRemovalOperationID,
                    stillWantsDisabled: self.isBlockingDisabled || self.isRemoving
                ) else {
                    MacEnforcementLog.delivery.error(
                        "Late Network Extension break-glass callback ignored op=\(operationID, privacy: .public) activeOp=\(self.breakGlassRemovalOperationID ?? "none", privacy: .public) blockingDisabled=\(self.isBlockingDisabled, privacy: .public) removing=\(self.isRemoving, privacy: .public)"
                    )
                    if error == nil, !self.isBlockingDisabled, !self.isRemoving {
                        MacEnforcementLog.delivery.fault(
                            "Late Network Extension break-glass success observed while enabled op=\(operationID, privacy: .public) action=reconstruct-enabled-preference"
                        )
                        self.requestActivationBeforeEnablingPreferences(
                            trigger: "late-break-glass-recovery",
                            configurationTrigger: .activationCompleted
                        )
                    }
                    return
                }
                self.breakGlassRemovalDeadlineTask?.cancel()
                self.breakGlassRemovalDeadlineTask = nil
                self.breakGlassRemovalOperationID = nil
                self.isBreakGlassRemovalInFlight = false
                if let error,
                   !Self.isAlreadyAbsentPreferenceRemovalError(error) {
                    let nsError = error as NSError
                    self.deliveryError = "Emergency filter removal did not complete: \(error.localizedDescription)"
                    MacEnforcementLog.delivery.fault(
                        "Network Extension break-glass removal failed op=\(operationID, privacy: .public) trigger=\(trigger, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)"
                    )
                    if self.isRemoving {
                        self.isRemoving = false
                        self.pendingDeactivationAfterDisable = false
                    }
                    self.status = .failed("Emergency filter preference removal failed: \(error.localizedDescription)")
                    return
                }
                if error != nil {
                    MacEnforcementLog.delivery.notice(
                        "Network Extension break-glass removal found preference already absent op=\(operationID, privacy: .public) trigger=\(trigger, privacy: .public) action=treat-as-success"
                    )
                }

                self.preferenceGeneration &+= 1
                self.cancelPreferenceMutationDeadline(
                    for: self.activePreferenceMutation?.generation ?? 0
                )
                self.activePreferenceMutation = nil
                self.pendingPreferenceMutation = nil
                self.pendingFinalEnableVerification = nil
                self.configurationOperations.removeAll()
                if trigger == "late-enable-quarantine-final-sweep" {
                    let resolvedCount =
                        self.outstandingEnabledPreferenceSaveOperations.count
                    self.outstandingEnabledPreferenceSaveOperations.removeAll()
                    MacEnforcementLog.delivery.notice(
                        "Outstanding enabled saves resolved by quarantine final sweep count=\(resolvedCount, privacy: .public) op=\(operationID, privacy: .public)"
                    )
                } else if let outstandingGeneration =
                    self.outstandingEnabledPreferenceSaveOperations.values.max(),
                    self.activationSafetyRequiresRestart,
                    self.isBlockingDisabled {
                    self.beginLateEnablePreferenceQuarantine(
                        timedOutPreferenceGeneration: outstandingGeneration,
                        trigger: "break-glass-superseded-enabled-save"
                    )
                }
                self.deliveryError = nil
                if self.isRemoving {
                    self.submitPendingDeactivation()
                } else {
                    self.status = .disabled
                }
                MacEnforcementLog.delivery.notice(
                    "Network Extension break-glass removal completed op=\(operationID, privacy: .public) trigger=\(trigger, privacy: .public) action=filter-preference-absent"
                )
            }
        }
    }

    private func armBreakGlassPreferenceRemovalDeadline(
        operationID: String,
        trigger: String
    ) {
        breakGlassRemovalDeadlineTask?.cancel()
        breakGlassRemovalDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        Self.breakGlassPreferenceRemovalDeadline * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self,
                  self.breakGlassRemovalOperationID == operationID else { return }
            self.breakGlassRemovalDeadlineTask = nil
            self.breakGlassRemovalOperationID = nil
            self.isBreakGlassRemovalInFlight = false
            if self.isRemoving {
                self.isRemoving = false
                self.pendingDeactivationAfterDisable = false
            }
            self.deliveryError = "Emergency filter cleanup stopped responding. Blocking remains disabled; use Retry Disable to try again."
            self.status = .failed("Emergency filter cleanup exceeded its eight-second safety deadline.")
            MacEnforcementLog.delivery.fault(
                "Network Extension break-glass removal timed out op=\(operationID, privacy: .public) trigger=\(trigger, privacy: .public) deadlineMs=\(Int(Self.breakGlassPreferenceRemovalDeadline * 1_000), privacy: .public) action=remain-disabled-and-offer-retry"
            )
        }
    }

    private static func isAlreadyAbsentPreferenceRemovalError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "NEFilterErrorDomain" && error.code == 1
    }

    private func preferenceGoalIsStillDesired(_ goal: FilterPreferenceGoal) -> Bool {
        switch goal {
        case let .enabled(revision, _, _, activationGeneration, preparationGeneration, _, _):
            return currentActivationAttempt(generation: activationGeneration) != nil
                && latestPolicy.revision == revision
                && retryGuardPreparationGeneration == preparationGeneration
        case let .disabledForActivation(_, _, activationGeneration, _):
            return currentActivationAttempt(generation: activationGeneration) != nil
        case let .suspendedForPreparation(revision, _, activationGeneration, _):
            return currentActivationAttempt(generation: activationGeneration) != nil
                && latestPolicy.revision == revision
        case .disabled:
            return isBlockingDisabled
        }
    }

    private func scheduleRetryGuardPreparationAfterSuspension(
        _ mutation: FilterPreferenceMutation,
        waitForManagedHostsRelease: Bool
    ) {
        guard case let .suspendedForPreparation(
            revision,
            trigger,
            activationGeneration,
            retry
        ) = mutation.goal else {
            return
        }
        let startedAt = Date()
        enforcementPreparationMessage = "Web enforcement is temporarily stopped while blocked-site DNS is prepared. Recovery is automatic."
        MacEnforcementLog.delivery.notice(
            "Retry-guard preparation suspension complete generation=\(mutation.generation, privacy: .public) revision=\(revision, privacy: .public) managerChanged=\(waitForManagedHostsRelease, privacy: .public) action=wait-for-inactive-host-mapping-status"
        )
        Task { @MainActor [weak self] in
            // The root block-page daemon polls status once per second. Wait for
            // the stopped provider's inactive record (or for an orphaned active
            // record to age out), then give the daemon one full poll to remove
            // its loopback `/etc/hosts` block. This uses only read-only status
            // and works from the sandboxed containing app.
            let deadline = startedAt.addingTimeInterval(
                BlockPageHostPolicy.statusFreshness + 3
            )
            while Date() < deadline {
                guard let self,
                      self.preferenceGeneration == mutation.generation,
                      self.currentActivationAttempt(generation: activationGeneration) != nil,
                      !self.isBlockingDisabled,
                      !self.isRemoving,
                      self.latestPolicy.revision == revision else {
                    return
                }
                if !MacFilterBlockPageHostMappingSafety.mayStillBePresent(
                    status: FilterStatusStore.read(),
                    now: Date(),
                    freshness: BlockPageHostPolicy.statusFreshness
                ) {
                    do {
                        try await Task.sleep(nanoseconds: 1_250_000_000)
                    } catch {
                        return
                    }
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
            }
            guard let self,
                  self.preferenceGeneration == mutation.generation,
                  self.currentActivationAttempt(generation: activationGeneration) != nil,
                  !self.isBlockingDisabled,
                  !self.isRemoving,
                  self.latestPolicy.revision == revision else {
                return
            }
            MacEnforcementLog.delivery.notice(
                "Retry-guard preparation host-mapping wait finished generation=\(mutation.generation, privacy: .public) revision=\(revision, privacy: .public) durationMs=\(diagnosticElapsedMilliseconds(since: startedAt), privacy: .public)"
            )
            self.configureNetworkFilter(
                retry: retry,
                trigger: trigger,
                activationGeneration: activationGeneration,
                filterIsSuspendedForPreparation: true
            )
        }
    }

    private static var providerBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private var lateEnableQuarantineAllowsEnabledPreference: Bool {
        MacFilterLateEnableQuarantineSafety.allowsEnabledPreference(
            during: lateEnablePreferenceQuarantine,
            currentGeneration: lateEnableQuarantineGeneration,
            currentBootSessionIdentifier: Self.currentBootSessionIdentifier()
        )
    }

    private var activationRuntimeState: MacFilterActivationRuntimeState {
        MacFilterActivationRuntimeState(
            desiredStateGeneration: desiredStateGeneration,
            wantsBlockingEnabled: !isBlockingDisabled
                && lateEnableQuarantineAllowsEnabledPreference,
            isRemoving: isRemoving
        )
    }

    private func invalidateVerifiedActivation(reason: String) {
        let invalidatedGeneration = activationAttempt?.desiredStateGeneration
        activationAttempt = nil
        disabledPreferenceProof = nil
        initialPropertiesProof = nil
        if let invalidatedGeneration {
            MacEnforcementLog.lifecycle.notice(
                "Network Extension activation authority invalidated generation=\(invalidatedGeneration, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    private func currentActivationAttempt(
        generation: UInt64
    ) -> MacFilterActivationAttempt? {
        guard let attempt = activationAttempt,
              attempt.desiredStateGeneration == generation,
              desiredStateGeneration == generation,
              !isBlockingDisabled,
              !isRemoving,
              !isResettingEnforcement,
              !activationSafetyRequiresRestart,
              lateEnableQuarantineAllowsEnabledPreference else {
            return nil
        }
        return attempt
    }

    private static func readActivationSafetyRecord(
        defaults: UserDefaults
    ) -> MacFilterActivationSafetyRecord? {
        guard defaults.object(forKey: activationSafetyTriggeredAtKey) != nil,
              defaults.object(forKey: activationSafetyBootTimeKey) != nil else {
            return nil
        }
        return MacFilterActivationSafetyRecord(
            bootSessionIdentifier: defaults.string(forKey: activationSafetyBootSessionKey),
            estimatedBootTime: Date(
                timeIntervalSince1970: defaults.double(forKey: activationSafetyBootTimeKey)
            ),
            triggeredAt: Date(
                timeIntervalSince1970: defaults.double(forKey: activationSafetyTriggeredAtKey)
            ),
            reason: defaults.string(forKey: activationSafetyReasonKey) ?? "unknown"
        )
    }

    private static func persistActivationSafetyRecord(
        _ record: MacFilterActivationSafetyRecord,
        defaults: UserDefaults
    ) {
        if let bootSessionIdentifier = record.bootSessionIdentifier,
           !bootSessionIdentifier.isEmpty {
            defaults.set(bootSessionIdentifier, forKey: activationSafetyBootSessionKey)
        } else {
            defaults.removeObject(forKey: activationSafetyBootSessionKey)
        }
        defaults.set(
            record.estimatedBootTime.timeIntervalSince1970,
            forKey: activationSafetyBootTimeKey
        )
        defaults.set(
            record.triggeredAt.timeIntervalSince1970,
            forKey: activationSafetyTriggeredAtKey
        )
        defaults.set(record.reason, forKey: activationSafetyReasonKey)
    }

    private static func clearActivationSafetyRecord(defaults: UserDefaults) {
        defaults.removeObject(forKey: activationSafetyBootSessionKey)
        defaults.removeObject(forKey: activationSafetyBootTimeKey)
        defaults.removeObject(forKey: activationSafetyTriggeredAtKey)
        defaults.removeObject(forKey: activationSafetyReasonKey)
    }

    private static func persistSameBootResetReceipt(
        attemptIdentifier: String,
        bootSessionIdentifier: String?,
        completedAt: Date,
        defaults: UserDefaults
    ) -> Bool {
        guard let bootSessionIdentifier, !bootSessionIdentifier.isEmpty else {
            return false
        }
        do {
            try MacEnforcementSafetyPersistence.persist(
                MacEnforcementSameBootResetReceipt(
                    attemptIdentifier: attemptIdentifier,
                    bootSessionIdentifier: bootSessionIdentifier,
                    completedAt: completedAt
                ),
                defaults: defaults
            )
        } catch {
            MacEnforcementLog.sameBootReset.error(
                "Same-boot reset receipt encoding failed error=\(error.localizedDescription, privacy: .public) action=keep-application-latch"
            )
            return false
        }
        guard defaults.synchronize() else {
            MacEnforcementLog.sameBootReset.error(
                "Same-boot reset receipt durability barrier failed action=keep-application-latch"
            )
            return false
        }
        return true
    }

    private static func currentEstimatedBootTime(now: Date = Date()) -> Date {
        now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
    }

    private static func currentBootSessionIdentifier() -> String? {
        var byteCount: size_t = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &byteCount, nil, 0) == 0,
              byteCount > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname(
                "kern.bootsessionuuid",
                buffer.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0, let first = bytes.first, first != 0 else { return nil }
        let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<terminator].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func armDeferredStartupWatchdog() {
        guard var attempt = deferredStartupWatchdogAttempt else { return }
        deferredStartupWatchdogAttempt = nil
        attempt.deadline = Date().addingTimeInterval(
            MacFilterStartupWatchdog.readinessDeadline
        )
        armStartupWatchdog(attempt)
    }

    private func armStartupWatchdog(_ attempt: MacFilterStartupWatchdogAttempt) {
        startupWatchdogTask?.cancel()
        startupWatchdogAttempt = attempt
        MacEnforcementLog.delivery.notice(
            "Provider startup watchdog armed generation=\(attempt.preferenceGeneration, privacy: .public) revision=\(attempt.expectedRevision, privacy: .public) expectedBuild=\(attempt.expectedProviderBuild, privacy: .public) deadlineMs=\(Int(attempt.deadline.timeIntervalSince1970 * 1_000), privacy: .public)"
        )
        startupWatchdogTask = Task { @MainActor [weak self] in
            var reportedFailure = false
            while !Task.isCancelled {
                guard let self,
                      let current = self.startupWatchdogAttempt,
                      current == attempt else { return }
                let action = MacFilterStartupWatchdog.action(
                    for: current,
                    currentPreferenceGeneration: self.preferenceGeneration,
                    wantsEnabled: !self.isBlockingDisabled && !self.isRemoving,
                    status: FilterStatusStore.read(),
                    now: Date()
                )
                switch action {
                case .wait:
                    try? await Task.sleep(nanoseconds: 1_000_000_000)

                case .satisfied:
                    self.startupWatchdogAttempt = nil
                    self.startupWatchdogTask = nil
                    if self.hasPersistedActivationAttempt,
                       !self.activationSafetyRequiresRestart {
                        Self.clearActivationSafetyRecord(defaults: .standard)
                        self.hasPersistedActivationAttempt = false
                        MacEnforcementLog.lifecycle.notice(
                            "Network Extension in-flight activation record cleared reason=provider-ready generation=\(current.preferenceGeneration, privacy: .public)"
                        )
                    }
                    self.status = .active
                    self.enforcementPreparationMessage = nil
                    for trigger in ["provider-startup-watchdog", "retry-guard-preparation-incomplete", "retry-guard-preparation-invalid", "system-extension-activation-evidence-timeout", "preference-read-timeout"] {
                        self.clearRecoveryWarning(trigger: trigger)
                    }
                    MacEnforcementLog.delivery.notice(
                        "Provider startup watchdog satisfied generation=\(current.preferenceGeneration, privacy: .public) revision=\(current.expectedRevision, privacy: .public)"
                    )
                    return

                case .cancel:
                    self.startupWatchdogAttempt = nil
                    self.startupWatchdogTask = nil
                    MacEnforcementLog.delivery.notice(
                        "Provider startup watchdog cancelled generation=\(current.preferenceGeneration, privacy: .public) revision=\(current.expectedRevision, privacy: .public) reason=state-changed"
                    )
                    return

                case .reportFailure:
                    if !reportedFailure {
                        reportedFailure = true
                        // The save has completed; missing readiness is not an
                        // uncertain preference write. Do not turn this warning
                        // into a safety lock on the next app launch.
                        if self.hasPersistedActivationAttempt,
                           !self.activationSafetyRequiresRestart {
                            Self.clearActivationSafetyRecord(defaults: .standard)
                            self.hasPersistedActivationAttempt = false
                        }
                        self.reportRecoveryWarning(
                            trigger: "provider-startup-watchdog",
                            message: "The filter is taking longer to report readiness. If browsing is affected, you can disable all web blocks with the confirmation passage."
                        )
                    }
                    // Keep observing so delayed readiness clears the warning
                    // without rewriting or restarting the installed filter.
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func cancelStartupWatchdog(reason: String) {
        let generation = startupWatchdogAttempt?.preferenceGeneration
            ?? deferredStartupWatchdogAttempt?.preferenceGeneration
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        startupWatchdogAttempt = nil
        deferredStartupWatchdogAttempt = nil
        if let generation {
            MacEnforcementLog.delivery.notice(
                "Provider startup watchdog cleared generation=\(generation, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }
}

extension MacEnforcementController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let context = systemExtensionLogRegistry.context(for: request)
        MacEnforcementLog.lifecycle.notice(
            "System-extension replacement requested op=\(context?.operationID ?? "unknown", privacy: .public) trigger=\(context?.trigger ?? "unknown", privacy: .public) existingShortVersion=\(existing.bundleShortVersion, privacy: .public) existingBuild=\(existing.bundleVersion, privacy: .public) proposedShortVersion=\(ext.bundleShortVersion, privacy: .public) proposedBuild=\(ext.bundleVersion, privacy: .public) decision=replace"
        )
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let context = systemExtensionLogRegistry.context(for: request)
        MacEnforcementLog.lifecycle.notice(
            "System-extension request needs approval op=\(context?.operationID ?? "unknown", privacy: .public) action=\(context?.action ?? "unknown", privacy: .public) trigger=\(context?.trigger ?? "unknown", privacy: .public) elapsedMs=\(context.map { diagnosticElapsedMilliseconds(since: $0.startedAt) } ?? 0, privacy: .public)"
        )
        guard let context else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard context.stateGeneration == self.desiredStateGeneration else {
                MacEnforcementLog.lifecycle.notice(
                    "Stale system-extension approval callback ignored op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) requestGeneration=\(context.stateGeneration, privacy: .public) currentGeneration=\(self.desiredStateGeneration, privacy: .public)"
                )
                return
            }
            switch context.action {
            case "activation":
                guard !self.isBlockingDisabled,
                      !self.isRemoving,
                      self.activationRequestGeneration == context.stateGeneration else { return }
                self.status = .awaitingApproval
            case "deactivation":
                guard self.isRemoving else { return }
                self.status = .awaitingApproval
            default:
                break
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let registeredContext = systemExtensionLogRegistry.context(for: request)
        let context = registeredContext?.action.hasSuffix("-properties") == true
            ? registeredContext
            : systemExtensionLogRegistry.remove(for: request)
        let resultDescription: String
        switch result {
        case .completed: resultDescription = "completed"
        case .willCompleteAfterReboot: resultDescription = "will-complete-after-reboot"
        @unknown default: resultDescription = "unknown"
        }
        MacEnforcementLog.lifecycle.notice(
            "System-extension request finished op=\(context?.operationID ?? "unknown", privacy: .public) action=\(context?.action ?? "unknown", privacy: .public) trigger=\(context?.trigger ?? "unknown", privacy: .public) result=\(resultDescription, privacy: .public) durationMs=\(context.map { diagnosticElapsedMilliseconds(since: $0.startedAt) } ?? 0, privacy: .public)"
        )
        DesktopDiagnosticTrace.record(
            component: "system-extension",
            event: "request_finished",
            fields: [
                "operation_id": context?.operationID ?? "unknown",
                "action": context?.action ?? "unknown",
                "trigger": context?.trigger ?? "unknown",
                "result": resultDescription,
                "duration_ms": context.map { diagnosticElapsedMilliseconds(since: $0.startedAt) } ?? 0
            ]
        )
        guard let context else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard context.stateGeneration == self.desiredStateGeneration else {
                MacEnforcementLog.lifecycle.notice(
                    "Stale system-extension completion ignored op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) requestGeneration=\(context.stateGeneration, privacy: .public) currentGeneration=\(self.desiredStateGeneration, privacy: .public)"
                )
                return
            }

            switch context.action {
            case "activation":
                guard !self.isBlockingDisabled,
                      !self.isRemoving,
                      self.activationRequestGeneration == context.stateGeneration else { return }
                switch result {
                case .willCompleteAfterReboot:
                    self.cancelActivationEvidenceDeadline(
                        reason: "activation-requires-reboot"
                    )
                    self.activationRequestGeneration = nil
                    self.pendingActivationTrigger = nil
                    self.invalidateVerifiedActivation(reason: "activation-requires-reboot")
                    self.isBlockingDisabled = true
                    UserDefaults.standard.set(true, forKey: Self.blockingDisabledKey)
                    self.status = .rebootRequired
                case .completed:
                    // `.completed` is not evidence that macOS enabled the
                    // extension. It returned this result during the live outage
                    // while properties and sysextd still said disabled.
                    self.submitEnabledPropertiesVerification(
                        DesktopEnforcementConstants.webFilterExtensionIdentifier,
                        trigger: context.trigger,
                        configurationTrigger: context.configurationTrigger ?? .activationCompleted,
                        stateGeneration: context.stateGeneration
                    )
                @unknown default:
                    self.activationRequestGeneration = nil
                    self.pendingActivationTrigger = nil
                    self.invalidateVerifiedActivation(reason: "unknown-activation-result")
                    self.disableBlockingForSafety(trigger: "unknown-system-extension-activation-result")
                }

            case "deactivation":
                guard self.isRemoving else { return }
                self.invalidateVerifiedActivation(reason: "deactivation-completed")
                if result == .willCompleteAfterReboot {
                    self.status = .rebootRequired
                } else {
                    self.isRemoving = false
                    self.status = .notInstalled
                }

            default:
                break
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let context = systemExtensionLogRegistry.remove(for: request)
        let observations = properties.map {
            SystemExtensionPropertyObservation(
                bundleIdentifier: $0.bundleIdentifier,
                bundleVersion: $0.bundleVersion,
                isEnabled: $0.isEnabled,
                isAwaitingUserApproval: $0.isAwaitingUserApproval,
                isUninstalling: $0.isUninstalling
            )
        }
        let stateDescription = observations.map {
            "bundle=\($0.bundleIdentifier),build=\($0.bundleVersion),enabled=\($0.isEnabled),awaiting=\($0.isAwaitingUserApproval),uninstalling=\($0.isUninstalling)"
        }.joined(separator: ";")
        MacEnforcementLog.lifecycle.notice(
            "System-extension properties returned op=\(context?.operationID ?? "unknown", privacy: .public) trigger=\(context?.trigger ?? "unknown", privacy: .public) count=\(observations.count, privacy: .public) states=\(stateDescription, privacy: .public)"
        )
        guard let context else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let properties = observations.map {
                MacFilterExtensionProperty(
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleVersion: $0.bundleVersion,
                    isEnabled: $0.isEnabled,
                    isAwaitingUserApproval: $0.isAwaitingUserApproval,
                    isUninstalling: $0.isUninstalling
                )
            }

            switch context.action {
            case "activation-properties":
                guard context.stateGeneration == self.desiredStateGeneration,
                      self.activationRequestGeneration == context.stateGeneration,
                      let attempt = self.currentActivationAttempt(
                        generation: context.stateGeneration
                      ) else {
                    MacEnforcementLog.lifecycle.notice(
                        "Stale initial system-extension properties ignored op=\(context.operationID, privacy: .public) requestGeneration=\(context.stateGeneration, privacy: .public) currentGeneration=\(self.desiredStateGeneration, privacy: .public)"
                    )
                    return
                }
                let proof = MacFilterActivationAuthorization.exactBuildPropertiesProof(
                    for: attempt,
                    disabledPreferenceProof: self.disabledPreferenceProof,
                    requestStateGeneration: context.stateGeneration,
                    phase: .beforePreparation,
                    properties: properties,
                    runtime: self.activationRuntimeState
                )
                guard let proof,
                      MacFilterActivationAuthorization.canBeginPreparation(
                        for: attempt,
                        disabledPreferenceProof: self.disabledPreferenceProof,
                        propertiesProof: proof,
                        runtime: self.activationRuntimeState
                      ) else {
                    let observedState = MacFilterActivationAuthorization.propertiesState(
                        for: attempt,
                        properties: properties
                    )
                    self.scheduleActivationPropertiesRetry(
                        trigger: context.trigger,
                        configurationTrigger: context.configurationTrigger ?? .activationCompleted,
                        stateGeneration: context.stateGeneration,
                        observedState: observedState
                    )
                    return
                }

                self.cancelActivationEvidenceDeadline(
                    reason: "exact-build-enabled"
                )
                self.activationRequestGeneration = nil
                self.initialPropertiesProof = proof
                self.status = .activating
                self.deliveryError = nil
                MacEnforcementLog.lifecycle.notice(
                    "System-extension activation verified op=\(context.operationID, privacy: .public) build=\(Self.providerBuild, privacy: .public) enabled=true stateGeneration=\(context.stateGeneration, privacy: .public) action=configure-network-filter"
                )
                self.configureNetworkFilter(
                    trigger: context.configurationTrigger ?? .activationCompleted,
                    activationGeneration: context.stateGeneration
                )

            case "final-enable-properties":
                guard let pending = self.pendingFinalEnableVerification,
                      pending.requestOperationID == context.operationID,
                      pending.mutation.generation == context.preferenceGeneration else {
                    MacEnforcementLog.lifecycle.notice(
                        "Orphaned final system-extension properties ignored op=\(context.operationID, privacy: .public) preferenceGeneration=\(context.preferenceGeneration ?? 0, privacy: .public)"
                    )
                    return
                }
                self.pendingFinalEnableVerification = nil
                guard self.activePreferenceMutation?.generation == pending.mutation.generation,
                      pending.mutation.generation == self.preferenceGeneration,
                      context.stateGeneration == self.desiredStateGeneration,
                      let preparationGeneration = pending.mutation.goal.preparationGeneration,
                      let attempt = self.currentActivationAttempt(
                        generation: context.stateGeneration
                      ) else {
                    self.completeSupersededPreferenceMutation(
                        pending.mutation,
                        operationID: pending.preferenceOperationID,
                        startedAt: pending.preferenceStartedAt,
                        stage: "stale-final-properties-callback"
                    )
                    return
                }
                let finalProof = MacFilterActivationAuthorization.exactBuildPropertiesProof(
                    for: attempt,
                    disabledPreferenceProof: self.disabledPreferenceProof,
                    requestStateGeneration: context.stateGeneration,
                    phase: .preparedForEnable(
                        preparationGeneration: preparationGeneration
                    ),
                    properties: properties,
                    runtime: self.activationRuntimeState
                )
                guard let finalProof else {
                    self.rejectEnabledPreferenceBeforeSave(
                        pending.mutation,
                        operationID: pending.preferenceOperationID,
                        startedAt: pending.preferenceStartedAt,
                        reason: "final-system-extension-verification-failed"
                    )
                    return
                }
                MacEnforcementLog.lifecycle.notice(
                    "Final system-extension activation verified op=\(context.operationID, privacy: .public) build=\(Self.providerBuild, privacy: .public) stateGeneration=\(context.stateGeneration, privacy: .public) preferenceGeneration=\(pending.mutation.generation, privacy: .public) action=save-enabled-preference"
                )
                self.applyLoadedPreferenceMutation(
                    pending.mutation,
                    manager: pending.manager,
                    operationID: pending.preferenceOperationID,
                    startedAt: pending.preferenceStartedAt,
                    finalPropertiesProof: finalProof
                )

            default:
                MacEnforcementLog.lifecycle.error(
                    "Unexpected system-extension properties callback op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public)"
                )
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let context = systemExtensionLogRegistry.remove(for: request)
        let nsError = error as NSError
        MacEnforcementLog.lifecycle.error(
            "System-extension request failed op=\(context?.operationID ?? "unknown", privacy: .public) action=\(context?.action ?? "unknown", privacy: .public) trigger=\(context?.trigger ?? "unknown", privacy: .public) durationMs=\(context.map { diagnosticElapsedMilliseconds(since: $0.startedAt) } ?? 0, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .private)"
        )
        var traceFields = DesktopDiagnosticTrace.runtimeEvidence()
        traceFields["operation_id"] = context?.operationID ?? "unknown"
        traceFields["action"] = context?.action ?? "unknown"
        traceFields["trigger"] = context?.trigger ?? "unknown"
        traceFields["duration_ms"] = context.map { diagnosticElapsedMilliseconds(since: $0.startedAt) } ?? 0
        traceFields["error_domain"] = nsError.domain
        traceFields["error_code"] = nsError.code
        DesktopDiagnosticTrace.record(
            component: "system-extension",
            event: "request_failed",
            fields: traceFields
        )
        guard let context else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if context.action == "final-enable-properties" {
                guard let pending = self.pendingFinalEnableVerification,
                      pending.requestOperationID == context.operationID,
                      context.preferenceGeneration == pending.mutation.generation else {
                    return
                }
                self.pendingFinalEnableVerification = nil
                if context.stateGeneration == self.desiredStateGeneration,
                   pending.mutation.generation == self.preferenceGeneration,
                   self.activePreferenceMutation?.generation == pending.mutation.generation,
                   self.currentActivationAttempt(generation: context.stateGeneration) != nil {
                    self.rejectEnabledPreferenceBeforeSave(
                        pending.mutation,
                        operationID: pending.preferenceOperationID,
                        startedAt: pending.preferenceStartedAt,
                        reason: "final-system-extension-properties-request-failed"
                    )
                } else {
                    self.completeSupersededPreferenceMutation(
                        pending.mutation,
                        operationID: pending.preferenceOperationID,
                        startedAt: pending.preferenceStartedAt,
                        stage: "stale-final-properties-failure"
                    )
                }
                return
            }
            guard context.stateGeneration == self.desiredStateGeneration else {
                MacEnforcementLog.lifecycle.notice(
                    "Stale system-extension failure ignored op=\(context.operationID, privacy: .public) action=\(context.action, privacy: .public) requestGeneration=\(context.stateGeneration, privacy: .public) currentGeneration=\(self.desiredStateGeneration, privacy: .public)"
                )
                return
            }
            switch context.action {
            case "activation":
                guard !self.isBlockingDisabled, !self.isRemoving else { return }
                self.activationRequestGeneration = nil
                self.invalidateVerifiedActivation(reason: "system-extension-activation-failed")
                self.status = .failed(error.localizedDescription)
                self.disableBlockingForSafety(trigger: "system-extension-activation-failed")
            case "activation-properties":
                guard !self.isBlockingDisabled,
                      !self.isRemoving,
                      self.activationRequestGeneration == context.stateGeneration,
                      self.currentActivationAttempt(generation: context.stateGeneration) != nil else {
                    return
                }
                MacEnforcementLog.lifecycle.error(
                    "System-extension properties check will retry op=\(context.operationID, privacy: .public) stateGeneration=\(context.stateGeneration, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) preferenceConfirmedDisabled=true"
                )
                self.scheduleActivationPropertiesRetry(
                    trigger: context.trigger,
                    configurationTrigger: context.configurationTrigger ?? .activationCompleted,
                    stateGeneration: context.stateGeneration,
                    observedState: .unavailable
                )
            case "deactivation":
                guard self.isRemoving else { return }
                self.isRemoving = false
                self.status = .failed(error.localizedDescription)
            default:
                break
            }
        }
    }
}

// MARK: - Filter switched off outside Holdfast

extension MacEnforcementController {
    /// Watches for the content-filter preference being changed by anything,
    /// including System Settings. Our own saves also post this notification;
    /// the gate ignores them because a mutation is in flight or the app no
    /// longer intends to enforce.
    func startExternalToggleMonitoring() {
        guard externalToggleObserver == nil else { return }
        externalToggleObserver = NotificationCenter.default.addObserver(
            forName: .NEFilterConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForExternalFilterToggle()
            }
        }
    }

    private var appIntendsEnforcement: Bool {
        !isBlockingDisabled && !isRemoving && !isResettingEnforcement
            && !activationSafetyRequiresRestart
            && (status == .active || status == .rebootRequired)
    }

    func checkForExternalFilterToggle() {
        // Only read the shared manager while no mutation of ours is running:
        // a load that lands between another operation's property change and
        // its save would silently overwrite that change.
        guard appIntendsEnforcement, !preferenceQueue.isBusy else { return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                // An unreadable preference is not evidence of tampering.
                let enabled = error == nil ? manager.isEnabled : true
                self?.applyExternalToggleObservation(preferenceEnabled: enabled, now: Date())
            }
        }
    }

    private func applyExternalToggleObservation(preferenceEnabled: Bool, now: Date) {
        let action = ExternalFilterToggleGate.decide(
            .init(
                appIntendsEnforcement: appIntendsEnforcement,
                mutationInFlight: preferenceQueue.isBusy,
                preferenceEnabled: preferenceEnabled,
                firstObservedOffAt: externalToggleObservedOffAt
            ),
            at: now
        )
        switch action {
        case .none:
            break
        case .clear:
            externalToggleObservedOffAt = nil
            externalToggleRecheckTask?.cancel()
            externalToggleRecheckTask = nil
        case let .recordAndSchedule(reenableAt):
            externalToggleObservedOffAt = now
            TamperJournal.shared.record(
                .filterDisabledOutsideApp,
                detail: "re-arming in \(Int(ExternalFilterToggleGate.reenableGrace / 60)) min",
                at: now
            )
            reportRecoveryWarning(
                trigger: "external-filter-toggle",
                message: "The web filter was switched off outside Holdfast. It will turn back on automatically in 15 minutes. Use Disable Blocking With Passage to keep it off."
            )
            DesktopDiagnosticTrace.record(component: "enforcement", event: "external_filter_disable_observed", fields: [:])
            externalToggleRecheckTask?.cancel()
            externalToggleRecheckTask = Task { @MainActor [weak self] in
                let delay = max(0, reenableAt.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.checkForExternalFilterToggle()
            }
        case .reenable:
            externalToggleObservedOffAt = nil
            externalToggleRecheckTask = nil
            recoveryWarnings["external-filter-toggle"] = nil
            recoveryWarning = recoveryWarnings.isEmpty ? nil
                : recoveryWarnings.keys.sorted().compactMap { recoveryWarnings[$0] }.joined(separator: "\n")
            TamperJournal.shared.record(.filterReenabledAutomatically, at: now)
            DesktopDiagnosticTrace.record(component: "enforcement", event: "external_filter_disable_rearmed", fields: [:])
            reassert()
        }
    }
}

