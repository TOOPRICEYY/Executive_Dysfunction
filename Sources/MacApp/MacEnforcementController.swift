import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions

@MainActor
final class MacEnforcementController: NSObject, ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case activating
        case awaitingApproval
        case active
        case rebootRequired
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled: "Not installed"
            case .activating: "Installing system enforcement…"
            case .awaitingApproval: "Approval required in System Settings"
            case .active: "Local enforcement active"
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
    private let requestQueue = DispatchQueue(label: "com.GabrielPrice.ExecutiveDysfunction.system-extension-requests")
    private var isRemoving = false
    private var latestPolicy = DesktopEnforcementPolicy.empty
    private var lastDeliveryAttempt = Date.distantPast
    private var lastReassert = Date.distantPast
    private var consecutiveBehindPolls = 0
    private let removalStore: DesktopRemovalRequestPersisting

    init(removalStore: DesktopRemovalRequestPersisting = KeychainRemovalRequestStore()) {
        self.removalStore = removalStore
        super.init()
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
    func updatePolicy(_ policy: DesktopEnforcementPolicy) {
        latestPolicy = policy
        guard !isRemoving else { return }
        configureNetworkFilter()
    }

    /// Re-sends the newest policy when the filter reports a revision behind the
    /// app's, and restarts the provider if that alone does not take.
    ///
    /// Saving the configuration is not sufficient on its own. A running
    /// `NEFilterDataProvider` reads `filterConfiguration.vendorConfiguration`
    /// as it stood when `startFilter` ran; a later `saveToPreferences` does not
    /// restart it and does not reach it. Measured directly: the filter sat on
    /// revision 199 through sixteen minutes of publishing, then jumped to the
    /// current revision the instant the app relaunched — and what a launch does
    /// differently is `reassert()`, whose activation request restarts the
    /// extension.
    ///
    /// So delivery escalates: save first, and if the filter is still behind
    /// several polls later, re-activate to restart the provider. The restart is
    /// the part that actually works, but it is heavier, so it is not the first
    /// resort.
    func redeliverPolicy() {
        guard !isRemoving, latestPolicy.revision > 0 else { return }
        consecutiveBehindPolls += 1

        if consecutiveBehindPolls >= 3, Date().timeIntervalSince(lastReassert) >= 60 {
            lastReassert = Date()
            consecutiveBehindPolls = 0
            restartFilterSession()
            return
        }
        guard Date().timeIntervalSince(lastDeliveryAttempt) >= 10 else { return }
        configureNetworkFilter()
    }

    /// Called when the filter is level with the app, so a later lag starts its
    /// escalation from zero rather than restarting the provider immediately.
    func noteDeliveryUpToDate() {
        consecutiveBehindPolls = 0
    }

    /// Cycles the filter session so the provider restarts and reads the current
    /// vendor configuration.
    ///
    /// `reassert()` is not enough: an activation request for a version that is
    /// already installed is a no-op and leaves the provider running on its
    /// original configuration. That is why every fix appeared to work — each
    /// deploy bumped the build number, and it was the version change, not the
    /// activation, doing the work.
    ///
    /// This is deliberately the last resort. Between the two saves the content
    /// filter is not installed, so traffic is briefly unfiltered. That gap is
    /// the lesser evil against a filter enforcing a stale policy indefinitely,
    /// but it is why this is throttled to once a minute and only runs after
    /// cheaper delivery has already failed three polls running.
    ///
    /// Disabling is also the *safe* direction: the machine-wide outage risk
    /// comes from a filter that is configured but not answering, not from one
    /// that is cleanly absent.
    private func restartFilterSession() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            if let error {
                Task { @MainActor in self?.deliveryError = "Filter restart failed: \(error.localizedDescription)" }
                return
            }
            manager.isEnabled = false
            manager.saveToPreferences { _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Re-enabling re-publishes the newest policy on the way up.
                    self.configureNetworkFilter()
                }
            }
        }
    }

    func install() {
        status = .activating
        isRemoving = false
        submitActivation(DesktopEnforcementConstants.webFilterExtensionIdentifier)
    }

    /// Re-submits the activation request every time the app launches.
    ///
    /// Enforcement that waits for a button is enforcement the user can end by
    /// simply not pressing it. macOS treats a repeat activation from the same
    /// team as a silent upgrade, so this also repairs the two states that
    /// otherwise persist unnoticed: an extension left behind at an older
    /// version, and a content filter switched off in System Settings.
    func reassert() {
        guard !isRemoving else { return }
        install()
    }

    // MARK: - Removal

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
    /// passage matches. This is the only path that may disable the filter.
    @discardableResult
    func completeRemoval(passage: String) -> Bool {
        guard let request = removalStore.load() else { return false }
        guard case .ready = DesktopRemovalGate.state(for: request) else {
            refreshRemovalState()
            return false
        }
        guard DesktopRemovalGate.passageMatches(passage, request: request) else { return false }

        removalStore.clear()
        refreshRemovalState()
        isRemoving = true
        status = .activating
        disableNetworkFilter()
        let deactivation = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: DesktopEnforcementConstants.webFilterExtensionIdentifier,
            queue: requestQueue
        )
        deactivation.delegate = self
        OSSystemExtensionManager.shared.submitRequest(deactivation)
        return true
    }

    func refreshRemovalState() {
        removalState = DesktopRemovalGate.state(for: removalStore.load())
    }

    /// What the current rules would demand of an uninstall, for display before
    /// the user commits to starting the wait.
    var removalTerms: DesktopRemovalGate.Terms {
        DesktopRemovalGate.terms(for: latestPolicy)
    }

    private func submitActivation(_ identifier: String) {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: requestQueue
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func configureNetworkFilter() {
        lastDeliveryAttempt = Date()
        let deliveredRevision = latestPolicy.revision
        let vendorConfiguration: [String: Any]
        do {
            vendorConfiguration = try DesktopPolicyConfigurationTransport.vendorConfiguration(
                for: latestPolicy
            )
        } catch {
            status = .failed("Could not encode the desktop policy: \(error.localizedDescription)")
            return
        }

        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            if let error {
                Task { @MainActor in self?.noteDeliveryFailure(error, revision: deliveredRevision) }
                return
            }
            let configuration = NEFilterProviderConfiguration()
            configuration.filterBrowsers = true
            configuration.filterSockets = true
            // Packet filtering stays off permanently. The extension no longer
            // ships an NEFilterPacketProvider at all: every crash it recorded
            // was a SIGSEGV inside the framework's packet interpose channel,
            // and macOS drops all traffic while a content filter is not
            // answering, so that crash presented as a total network outage.
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = DesktopEnforcementConstants.webFilterExtensionIdentifier
            configuration.filterPacketProviderBundleIdentifier = nil
            configuration.vendorConfiguration = vendorConfiguration
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Executive Dysfunction Website Blocking"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.noteDeliveryFailure(error, revision: deliveredRevision)
                    } else {
                        self.deliveryError = nil
                        self.status = .active
                    }
                }
            }
        }
    }

    /// A failed save is not the same thing as a broken installation.
    ///
    /// Delivery is now attempted on every policy change, including before the
    /// extension is approved, so a failure here must not overwrite
    /// `.awaitingApproval` or `.activating` with `.failed` — that would report
    /// a healthy pending install as broken. Only a filter that *was* active and
    /// then stopped accepting policy is a regression worth surfacing as such.
    private func noteDeliveryFailure(_ error: Error, revision: UInt64) {
        deliveryError = "Revision \(revision) was not delivered: \(error.localizedDescription)"
        if status == .active {
            status = .failed(error.localizedDescription)
        }
    }

    /// The only switch that turns enforcement off, so it is deliberately hard
    /// to reach by accident. `completeRemoval(passage:)` sets `isRemoving` only
    /// after the delay has elapsed and the passage has matched; any other
    /// caller, present or future, gets a no-op rather than an open filter.
    private func disableNetworkFilter() {
        guard isRemoving else {
            assertionFailure("disableNetworkFilter() reached outside an authorized removal")
            return
        }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { _ in
            manager.isEnabled = false
            manager.saveToPreferences { _ in }
        }
    }
}

extension MacEnforcementController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleShortVersion > existing.bundleShortVersion ? .replace : .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in status = .awaitingApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            if isRemoving {
                if result == .willCompleteAfterReboot {
                    status = .rebootRequired
                } else {
                    status = .notInstalled
                }
                return
            }
            switch result {
            case .willCompleteAfterReboot:
                status = .rebootRequired
            case .completed:
                configureNetworkFilter()
            default:
                break
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in status = .failed(error.localizedDescription) }
    }
}
