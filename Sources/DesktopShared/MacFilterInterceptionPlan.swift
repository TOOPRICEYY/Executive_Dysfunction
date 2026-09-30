import Foundation

/// A platform-neutral description of how the macOS data provider should ask
/// Network Extension to route flows.
///
/// A domain-only block list does not need to put every socket on the provider's
/// verdict path. `NEFilterSettings` can drop named destinations in the system
/// rule layer and let everything else bypass the provider. Besides being less
/// work, that distinction matters on Macs with a full-tunnel VPN: live testing
/// showed that the implicit `filterData` default stopped every new TCP connect
/// even while `handleNewFlow` returned `.allow()` for each one.
struct MacFilterInterceptionPlan: Equatable, Sendable {
    enum DefaultAction: String, Equatable, Sendable {
        case allow
        case filterData
    }

    enum Mode: String, Equatable, Sendable {
        case bypass
        case domainRules
        case providerInspection
    }

    static let maximumSystemRules = 1_000
    static let dedicatedEncryptedDNSPorts = [784, 853, 8_853]
    /// Only endpoints used for ordinary web retries are correlated. Applying
    /// an address rule to every port would turn a shared CDN address into a
    /// broad IP block instead of a narrow retry guard.
    static let correlatedWebPorts = [80, 443, 8_443]
    static let recoveryDNSPort = 53

    /// Only the unresolved policy suffixes get a DNS exception, never a
    /// wildcard resolver/IP exemption or an exception on a web port.
    func recoveryDNSDomains(for guards: MacFilterRetryGuardSet) -> [String] {
        guard mode == .domainRules else { return [] }
        return Set(guards.missingRequiredDomainSuffixes)
            .intersection(retryGuardRequiredDomainSuffixes).sorted()
    }

    /// The optional block page maps policy domains to loopback while the
    /// provider is active. Never let that presentation mapping replace the
    /// real endpoint correlation set used to stop cached-IP browser retries.
    static func normalizedCorrelatedAddress(_ rawAddress: String) -> String? {
        var address = rawAddress.lowercased()
        if address.hasPrefix("[") { address.removeFirst() }
        if address.hasSuffix("]") { address.removeLast() }
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        // Captive DNS commonly maps every name to the local gateway. Those
        // answers are not public blocked-site evidence and must never enter a
        // persisted/prepared retry guard. This also keeps LAN login out of the
        // provider verdict path, consistent with its local-scope exemption.
        guard !address.isEmpty, !WebFilterFlowDecider.isLocalScope(address) else {
            return nil
        }
        return address
    }

    static func shouldCorrelateResolvedAddress(_ rawAddress: String) -> Bool {
        normalizedCorrelatedAddress(rawAddress) != nil
    }

    var mode: Mode
    var defaultAction: DefaultAction
    /// Canonical domain suffixes that the system rule layer drops without
    /// consulting the provider. Parent suffixes subsume their subdomains.
    var blockedDomainSuffixes: [String]
    var blockedDestinationPorts: [Int]
    /// Explicit active block-list suffixes whose public endpoints must be
    /// represented by cached-IP retry guards before this plan is ready. The
    /// encrypted-DNS helper domains remain system drops, but resolving one of
    /// them must never mask a missing address for the site the user selected.
    var retryGuardRequiredDomainSuffixes: [String]

    init(
        mode: Mode,
        defaultAction: DefaultAction,
        blockedDomainSuffixes: [String],
        blockedDestinationPorts: [Int],
        retryGuardRequiredDomainSuffixes: [String] = []
    ) {
        self.mode = mode
        self.defaultAction = defaultAction
        self.blockedDomainSuffixes = blockedDomainSuffixes
        self.blockedDestinationPorts = blockedDestinationPorts
        self.retryGuardRequiredDomainSuffixes = retryGuardRequiredDomainSuffixes
    }

    /// Resolve helper domains for their own unnamed retries as before, while
    /// also resolving every explicit suffix even when a broader helper suffix
    /// subsumes it in the system hostname-rule list.
    var retryGuardResolutionDomainSuffixes: [String] {
        Array(Set(blockedDomainSuffixes + retryGuardRequiredDomainSuffixes)).sorted()
    }

    var maximumCorrelatedAddresses: Int {
        // Reserve a DNS-only recovery rule per required suffix. Missing DNS
        // must be allowed to recover without clearing all active block rules.
        let fixedRules = blockedDomainSuffixes.count + blockedDestinationPorts.count * 2
            + retryGuardRequiredDomainSuffixes.count
        return max(0, (Self.maximumSystemRules - fixedRules) / Self.correlatedWebPorts.count)
    }

    static func make(
        for policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> MacFilterInterceptionPlan {
        let active = policy.activeRules(at: date)
        let needsProviderInspection = active.contains {
            $0.enforcementMode == .fortressAllowList
                || !$0.macApplicationIdentifiers.isEmpty
        }
        if needsProviderInspection {
            return MacFilterInterceptionPlan(
                mode: .providerInspection,
                defaultAction: .filterData,
                blockedDomainSuffixes: [],
                blockedDestinationPorts: []
            )
        }

        let explicitDomains = active
            .filter { $0.enforcementMode == .blockList }
            .flatMap(\.domains)
        let requiredDomains = canonicalDomainSuffixes(explicitDomains)
        guard !requiredDomains.isEmpty else {
            return MacFilterInterceptionPlan(
                mode: .bypass,
                defaultAction: .allow,
                blockedDomainSuffixes: [],
                blockedDestinationPorts: []
            )
        }

        let domains = canonicalDomainSuffixes(
            requiredDomains + Array(DesktopEnforcementConstants.encryptedDNSProviderDomains)
        )
        // Each dedicated port needs one IPv4 and one IPv6 rule. The framework
        // accepts at most 1,000 rules total. If a policy cannot be represented
        // completely, retain the existing provider decision path instead of
        // silently omitting a blocked destination.
        let portRuleCount = dedicatedEncryptedDNSPorts.count * 2
        guard domains.count + portRuleCount + requiredDomains.count <= maximumSystemRules else {
            return MacFilterInterceptionPlan(
                mode: .providerInspection,
                defaultAction: .filterData,
                blockedDomainSuffixes: [],
                blockedDestinationPorts: []
            )
        }

        return MacFilterInterceptionPlan(
            mode: .domainRules,
            defaultAction: .allow,
            blockedDomainSuffixes: domains,
            blockedDestinationPorts: dedicatedEncryptedDNSPorts,
            retryGuardRequiredDomainSuffixes: requiredDomains
        )
    }

    fileprivate static func canonicalDomainSuffixes<S: Sequence>(
        _ rawDomains: S
    ) -> [String] where S.Element == String {
        let normalized = Set(rawDomains.compactMap { raw -> String? in
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while domain.hasSuffix(".") { domain.removeLast() }
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard !domain.isEmpty, domain.utf8.count <= 253, !labels.isEmpty,
                  labels.allSatisfy({ label in
                      !label.isEmpty
                          && label.utf8.count <= 63
                          && label.first != "-"
                          && label.last != "-"
                          && label.utf8.allSatisfy({ byte in
                              (byte >= 0x61 && byte <= 0x7a)
                                  || (byte >= 0x30 && byte <= 0x39)
                                  || byte == 0x2d
                          })
                  }) else { return nil }
            return domain
        })

        return normalized
            .filter { candidate in
                var suffixStart = candidate.startIndex
                while let separator = candidate[suffixStart...].firstIndex(of: ".") {
                    suffixStart = candidate.index(after: separator)
                    if normalized.contains(String(candidate[suffixStart...])) {
                        return false
                    }
                }
                return true
            }
            .sorted()
    }
}

/// Public endpoint answers remain associated with the suffix that produced
/// them. Keeping that association prevents a successful helper-domain lookup
/// from being mistaken for coverage of an unresolved explicit blocked site.
struct MacFilterDomainAddressResolution: Equatable, Sendable {
    private(set) var addressesByDomainSuffix: [String: Set<String>] = [:]

    init(addressesByDomainSuffix: [String: Set<String>] = [:]) {
        for (domain, addresses) in addressesByDomainSuffix {
            record(addresses, forDomainSuffix: domain)
        }
    }

    mutating func record<S: Sequence>(
        _ addresses: S,
        forDomainSuffix rawDomain: String
    ) where S.Element == String {
        let canonical = MacFilterInterceptionPlan.canonicalDomainSuffixes([rawDomain])
        guard let domain = canonical.first else { return }
        let eligible = Set(addresses.compactMap {
            MacFilterInterceptionPlan.normalizedCorrelatedAddress($0)
        })
        guard !eligible.isEmpty else { return }
        addressesByDomainSuffix[domain, default: []].formUnion(eligible)
    }

    /// Merging a refresh with the last successfully installed resolution keeps
    /// one partial DNS response from deleting another domain's still-cached
    /// retry guard. The installation cap below remains the system-rule bound.
    func merging(_ other: MacFilterDomainAddressResolution) -> Self {
        var merged = self
        for (domain, addresses) in other.addressesByDomainSuffix {
            merged.addressesByDomainSuffix[domain, default: []].formUnion(addresses)
        }
        return merged
    }

    func retryGuards(for plan: MacFilterInterceptionPlan) -> MacFilterRetryGuardSet {
        guard plan.mode == .domainRules else {
            return MacFilterRetryGuardSet(addresses: [], missingRequiredDomainSuffixes: [])
        }

        let required = Set(plan.retryGuardRequiredDomainSuffixes)
        let maximum = plan.maximumCorrelatedAddresses
        var selected = Set<String>()
        var uncovered = required

        // Prefer an address shared by the most uncovered suffixes. In ordinary
        // policies the cap is hundreds of addresses, but this also preserves
        // complete coverage when several CDN-backed suffixes share a small cap.
        while !uncovered.isEmpty, selected.count < maximum {
            var coverageByAddress: [String: Int] = [:]
            for domain in uncovered {
                for address in addressesByDomainSuffix[domain] ?? [] {
                    coverageByAddress[address, default: 0] += 1
                }
            }
            guard let best = coverageByAddress.keys.sorted(by: { left, right in
                let leftCoverage = coverageByAddress[left, default: 0]
                let rightCoverage = coverageByAddress[right, default: 0]
                return leftCoverage == rightCoverage ? left < right : leftCoverage > rightCoverage
            }).first else { break }
            selected.insert(best)
            uncovered = Set(uncovered.filter {
                !(addressesByDomainSuffix[$0] ?? []).contains(best)
            })
        }

        let allEligible = Set(addressesByDomainSuffix.values.flatMap { $0 })
        if selected.count < maximum {
            selected.formUnion(
                allEligible.subtracting(selected).sorted().prefix(maximum - selected.count)
            )
        }

        let missing = required.filter { domain in
            (addressesByDomainSuffix[domain] ?? []).isDisjoint(with: selected)
        }.sorted()
        return MacFilterRetryGuardSet(
            addresses: selected,
            missingRequiredDomainSuffixes: missing
        )
    }
}

/// The exact bounded address union to install in Network Extension settings,
/// together with coverage computed against that same union.
struct MacFilterRetryGuardSet: Equatable, Sendable {
    var addresses: Set<String>
    var missingRequiredDomainSuffixes: [String]

    var hasCompleteRequiredCoverage: Bool {
        missingRequiredDomainSuffixes.isEmpty
    }
}

/// During a system-extension upgrade macOS can briefly restart the old
/// provider before replacing it. Its active heartbeat makes the optional block
/// page install loopback host mappings; if the new provider resolves at that
/// instant it sees only 127.0.0.1 and installs no cached-IP retry guards.
///
/// This small state machine keeps that replacement-only wait explicit and
/// testable. Readiness is bound to per-domain coverage so a successful helper
/// lookup cannot hide a blocked site still masked by local startup rules.
struct MacFilterStartupResolutionState: Equatable, Sendable {
    var attempt = 0
    var didPublishInactiveStatus = false
    var didApplyWarmupSettings = false

    static let initial = MacFilterStartupResolutionState()
}

enum MacFilterStartupResolutionAction: String, Equatable, Sendable {
    case applyFinalSettings
    case publishInactiveStatus
    case waitForManagedHostsRelease
    case applyWarmupSettings
    case waitForPublicResolution
    case applyLimitedSettings
}

enum MacFilterStartupResolutionCoordinator {
    static let retryDelay: TimeInterval = 0.5
    static let maximumAttempts = 6

    static func action(
        plan: MacFilterInterceptionPlan,
        retryGuards: MacFilterRetryGuardSet,
        hasManagedHostMappings: Bool,
        state: MacFilterStartupResolutionState,
        permitsIncompleteCoverage: Bool = false
    ) -> MacFilterStartupResolutionAction {
        if permitsIncompleteCoverage { return .applyFinalSettings }
        guard plan.mode == .domainRules, !retryGuards.hasCompleteRequiredCoverage else {
            return .applyFinalSettings
        }
        guard state.attempt >= 0, state.attempt < maximumAttempts else {
            return .applyLimitedSettings
        }
        guard state.didPublishInactiveStatus else {
            return .publishInactiveStatus
        }
        if hasManagedHostMappings {
            return .waitForManagedHostsRelease
        }
        guard state.didApplyWarmupSettings else {
            return .applyWarmupSettings
        }
        return .waitForPublicResolution
    }
}
