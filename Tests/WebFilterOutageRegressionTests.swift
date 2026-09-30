import XCTest

/// Regressions for the fault that took this Mac's whole network down
/// intermittently, and for the guards added so that a filter bug can never do
/// it again.
///
/// Build 32 made the remaining outage conclusive: 21 unnamed web flows entered
/// inspection, Network Extension delivered zero outbound callbacks, and 12
/// remained held when the watchdog disabled the provider. For BSD sockets even
/// a one-byte new-flow peek can deadlock connect against the first ClientHello.
/// The regressions below also preserve earlier completion and fail-open fixes.
final class WebFilterOutageRegressionTests: XCTestCase {
    // MARK: - Domain-only rules bypass the provider verdict path

    func testPartialRecoveryKeepsNamedBlocksAndConvergesWithoutBypassWarmup() {
        let policy = makePolicy(domains: ["known.example", "missing.example"])
        let plan = MacFilterInterceptionPlan.make(for: policy, at: activeDate)
        var resolution = MacFilterDomainAddressResolution(addressesByDomainSuffix: ["known.example": ["203.0.113.10"]])
        let partial = resolution.retryGuards(for: plan)
        XCTAssertEqual(plan.recoveryDNSDomains(for: partial), ["missing.example"])
        XCTAssertEqual(MacFilterInterceptionPlan.recoveryDNSPort, 53)
        XCTAssertEqual(MacFilterStartupResolutionCoordinator.action(plan: plan, retryGuards: partial,
            hasManagedHostMappings: false, state: .initial, permitsIncompleteCoverage: true), .applyFinalSettings)
        XCTAssertEqual(WebFilterFlowDecider.decision(for: .init(hostname: "missing.example", remotePort: 443), policy: policy, at: activeDate), .drop)
        XCTAssertEqual(WebFilterFlowDecider.outcome(for: .init(remoteAddress: "203.0.113.10", remotePort: 443),
            policy: policy, at: activeDate, matchesRecentlyBlockedEndpoint: true).decision, .drop)
        XCTAssertEqual(WebFilterFlowDecider.decision(for: .init(hostname: "allowed.example", remotePort: 443), policy: policy, at: activeDate), .allow)
        resolution.record(["203.0.113.20"], forDomainSuffix: "missing.example")
        let complete = resolution.retryGuards(for: plan)
        XCTAssertTrue(complete.hasCompleteRequiredCoverage)
        XCTAssertTrue(plan.recoveryDNSDomains(for: complete).isEmpty, "DNS recovery exceptions disappear when coverage completes")
        XCTAssertEqual(complete.addresses, ["203.0.113.10", "203.0.113.20"])
        XCTAssertEqual(MacFilterStartupResolutionCoordinator.action(plan: plan, retryGuards: complete,
            hasManagedHostMappings: false, state: .initial, permitsIncompleteCoverage: true), .applyFinalSettings)
    }

    func testRecoveryExceptionsAreScopedAndIncludedInSystemRuleBudget() {
        let plan = MacFilterInterceptionPlan.make(for: makePolicy(domains: ["blocked.example"]), at: activeDate)
        let guards = MacFilterRetryGuardSet(addresses: [], missingRequiredDomainSuffixes: ["blocked.example", "unrelated.example"])
        XCTAssertEqual(plan.recoveryDNSDomains(for: guards), ["blocked.example"])
        let maximumRules = plan.blockedDomainSuffixes.count + plan.blockedDestinationPorts.count * 2
            + plan.retryGuardRequiredDomainSuffixes.count + plan.maximumCorrelatedAddresses * MacFilterInterceptionPlan.correlatedWebPorts.count
        XCTAssertLessThanOrEqual(maximumRules, MacFilterInterceptionPlan.maximumSystemRules)
    }

    func testDomainBlockListUsesSystemDropsAndAllowsEverythingElse() {
        let policy = makePolicy(domains: ["www.blocked.example", "blocked.example"])
        let plan = MacFilterInterceptionPlan.make(for: policy, at: activeDate)

        XCTAssertEqual(plan.mode, .domainRules)
        XCTAssertEqual(plan.defaultAction, .allow)
        XCTAssertEqual(
            plan.blockedDomainSuffixes.filter { $0.hasSuffix("blocked.example") },
            ["blocked.example"],
            "The parent system rule must cover named retries and every subdomain"
        )
        XCTAssertEqual(plan.blockedDestinationPorts, [784, 853, 8_853])
        XCTAssertEqual(plan.retryGuardRequiredDomainSuffixes, ["blocked.example"])
        XCTAssertTrue(plan.retryGuardResolutionDomainSuffixes.contains("blocked.example"))
        XCTAssertTrue(plan.retryGuardResolutionDomainSuffixes.contains("dns.google"))
        XCTAssertEqual(MacFilterInterceptionPlan.correlatedWebPorts, [80, 443, 8_443])
        XCTAssertGreaterThan(plan.maximumCorrelatedAddresses, 0)
    }

    func testMalformedDomainLabelsAreIgnoredAndParentSuffixesSubsumeChildren() {
        let policy = makePolicy(domains: [
            ".leading.example",
            "double..example",
            "-invalid.example",
            "valid.example",
            "www.sub.valid.example"
        ])
        let plan = MacFilterInterceptionPlan.make(for: policy, at: activeDate)

        XCTAssertTrue(plan.blockedDomainSuffixes.contains("valid.example"))
        XCTAssertFalse(plan.blockedDomainSuffixes.contains("sub.valid.example"))
        XCTAssertFalse(plan.blockedDomainSuffixes.contains(".leading.example"))
        XCTAssertFalse(plan.blockedDomainSuffixes.contains("double..example"))
        XCTAssertFalse(plan.blockedDomainSuffixes.contains("-invalid.example"))
    }

    func testBlockPageLoopbackNeverReplacesRealRetryCorrelation() {
        XCTAssertFalse(MacFilterInterceptionPlan.shouldCorrelateResolvedAddress("127.0.0.1"))
        XCTAssertFalse(MacFilterInterceptionPlan.shouldCorrelateResolvedAddress("::1"))
        XCTAssertFalse(MacFilterInterceptionPlan.shouldCorrelateResolvedAddress("[::1]"))
        XCTAssertTrue(MacFilterInterceptionPlan.shouldCorrelateResolvedAddress("104.18.18.18"))
        XCTAssertTrue(MacFilterInterceptionPlan.shouldCorrelateResolvedAddress("2606:4700::6812:1212"))
    }

    func testCaptiveGatewayDNSAnswersNeverBecomeBlockedSiteRetryGuards() {
        let addresses = ["10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.1.1",
                         "100.64.0.1", "fe80::1%en0", "[fd00::1]", "::ffff:192.168.1.1"]
        for address in addresses {
            XCTAssertNil(MacFilterInterceptionPlan.normalizedCorrelatedAddress(address), address)
        }
        let plan = MacFilterInterceptionPlan.make(for: makePolicy(domains: ["blocked.example"]), at: activeDate)
        let captiveResolution = MacFilterDomainAddressResolution(addressesByDomainSuffix: ["blocked.example": Set(addresses)])
        XCTAssertTrue(captiveResolution.retryGuards(for: plan).addresses.isEmpty)
        XCTAssertEqual(captiveResolution.retryGuards(for: plan).missingRequiredDomainSuffixes, ["blocked.example"],
                       "A gateway is not proof that public retry guards were prepared")
        let prior = MacFilterDomainAddressResolution(addressesByDomainSuffix: ["blocked.example": ["198.51.100.42"]])
        let merged = prior.merging(captiveResolution).retryGuards(for: plan)
        XCTAssertEqual(merged.addresses, ["198.51.100.42"])
        XCTAssertTrue(merged.hasCompleteRequiredCoverage)
    }

    func testExtensionReplacementWaitsForManagedHostsToReleasePublicResolution() {
        let plan = MacFilterInterceptionPlan.make(
            for: makePolicy(domains: ["reddit.com"]),
            at: activeDate
        )
        let emptyRetryGuards = MacFilterDomainAddressResolution().retryGuards(for: plan)

        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: emptyRetryGuards,
                hasManagedHostMappings: true,
                state: .initial
            ),
            .publishInactiveStatus,
            "A replacement must first tell the block-page daemon to release /etc/hosts"
        )
        var inactive = MacFilterStartupResolutionState.initial
        inactive.didPublishInactiveStatus = true
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: emptyRetryGuards,
                hasManagedHostMappings: true,
                state: inactive
            ),
            .waitForManagedHostsRelease
        )
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: emptyRetryGuards,
                hasManagedHostMappings: false,
                state: inactive
            ),
            .applyWarmupSettings,
            "Inherited Network Extension hostname rules must be cleared even without a hosts marker"
        )

        var warmed = inactive
        warmed.didApplyWarmupSettings = true
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: emptyRetryGuards,
                hasManagedHostMappings: false,
                state: warmed
            ),
            .waitForPublicResolution,
            "Warm-up settings are applied once, then only resolution is retried"
        )
        var completeResolution = MacFilterDomainAddressResolution()
        completeResolution.record(["151.101.1.140"], forDomainSuffix: "reddit.com")
        let completeRetryGuards = completeResolution.retryGuards(for: plan)
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: completeRetryGuards,
                hasManagedHostMappings: false,
                state: warmed
            ),
            .applyFinalSettings
        )

        warmed.attempt = MacFilterStartupResolutionCoordinator.maximumAttempts
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: emptyRetryGuards,
                hasManagedHostMappings: false,
                state: warmed
            ),
            .applyLimitedSettings,
            "A recovered replacement must never report ready with zero retry guards"
        )

        let bypass = MacFilterInterceptionPlan.make(
            for: makePolicy(domains: []),
            at: activeDate
        )
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: bypass,
                retryGuards: MacFilterDomainAddressResolution().retryGuards(for: bypass),
                hasManagedHostMappings: true,
                state: .initial
            ),
            .applyFinalSettings,
            "An idle policy must never delay ordinary browsing"
        )
    }

    func testHelperResolutionCannotMaskMissingExplicitBlockedDomain() {
        let plan = MacFilterInterceptionPlan.make(
            for: makePolicy(domains: ["coinbase.com"]),
            at: activeDate
        )
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["8.8.8.8", "8.8.4.4"], forDomainSuffix: "dns.google")

        let helperOnly = resolution.retryGuards(for: plan)
        XCTAssertEqual(helperOnly.addresses, ["8.8.4.4", "8.8.8.8"])
        XCTAssertEqual(helperOnly.missingRequiredDomainSuffixes, ["coinbase.com"])
        XCTAssertFalse(helperOnly.hasCompleteRequiredCoverage)
        XCTAssertEqual(
            MacFilterStartupResolutionCoordinator.action(
                plan: plan,
                retryGuards: helperOnly,
                hasManagedHostMappings: false,
                state: .initial
            ),
            .publishInactiveStatus,
            "A helper answer is not evidence that Coinbase cached-IP retries are guarded"
        )

        resolution.record(["104.18.18.18"], forDomainSuffix: "coinbase.com")
        let complete = resolution.retryGuards(for: plan)
        XCTAssertTrue(complete.hasCompleteRequiredCoverage)
        XCTAssertEqual(
            complete.addresses,
            ["8.8.4.4", "8.8.8.8", "104.18.18.18"],
            "The exact installation set preserves the complete helper + explicit union"
        )
    }

    func testPartialRefreshMergesWithoutDiscardingPriorBlockedDomainCoverage() {
        let plan = MacFilterInterceptionPlan.make(
            for: makePolicy(domains: ["coinbase.com", "reddit.com"]),
            at: activeDate
        )
        var previous = MacFilterDomainAddressResolution()
        previous.record(["104.18.18.18"], forDomainSuffix: "coinbase.com")
        previous.record(["151.101.1.140"], forDomainSuffix: "reddit.com")

        var partialRefresh = MacFilterDomainAddressResolution()
        partialRefresh.record(["104.18.19.18"], forDomainSuffix: "coinbase.com")
        let merged = partialRefresh.merging(previous).retryGuards(for: plan)

        XCTAssertTrue(merged.hasCompleteRequiredCoverage)
        XCTAssertTrue(merged.addresses.contains("104.18.18.18"))
        XCTAssertTrue(merged.addresses.contains("104.18.19.18"))
        XCTAssertTrue(merged.addresses.contains("151.101.1.140"))
    }

    func testSettingsLifecycleRejectsRetriesAndCallbacksAfterStop() {
        var lifecycle = MacFilterSettingsLifecycle()
        let starting = lifecycle.startProvider()
        XCTAssertTrue(lifecycle.accepts(starting))

        lifecycle.stopProvider()
        XCTAssertFalse(lifecycle.accepts(starting))
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertFalse(lifecycle.hasOperationInFlight)

        let replacement = lifecycle.startProvider()
        XCTAssertTrue(lifecycle.accepts(replacement))
        XCTAssertFalse(
            lifecycle.accepts(starting),
            "A late settings callback from the replaced provider lifetime must stay inert"
        )
    }

    func testSettingsLifecycleSerializesPolicyApplications() {
        var lifecycle = MacFilterSettingsLifecycle()
        let first = lifecycle.startProvider()
        XCTAssertNil(
            lifecycle.beginOperation(),
            "A second OS settings apply cannot race the first one"
        )

        XCTAssertTrue(lifecycle.finish(first))
        let second = try! XCTUnwrap(lifecycle.beginOperation())
        XCTAssertTrue(lifecycle.accepts(second))
        XCTAssertFalse(lifecycle.accepts(first))
        XCTAssertFalse(lifecycle.finish(first))
        XCTAssertTrue(lifecycle.finish(second))
    }

    func testStopDrainsPhysicalApplyThenOrdersFinalBypass() {
        var physical = MacFilterPhysicalApplyState()
        XCTAssertTrue(physical.beginLogicalApply(isCurrent: true))
        XCTAssertEqual(physical.requestStop(), .none)
        XCTAssertTrue(physical.isStopRequested)
        XCTAssertFalse(
            physical.beginLogicalApply(isCurrent: true),
            "No new settings apply may cross the stop linearization point"
        )

        XCTAssertEqual(physical.logicalApplyFinished(), .applyFinalBypass)
        XCTAssertTrue(physical.isFinalBypassInFlight)
        XCTAssertEqual(physical.finalBypassFinished(), .finishStop)
        XCTAssertEqual(physical.logicalAppliesInFlight, 0)
    }

    func testStopWithoutOutstandingApplyStillRequiresFinalBypass() {
        var physical = MacFilterPhysicalApplyState()
        XCTAssertEqual(physical.requestStop(), .applyFinalBypass)
        XCTAssertEqual(physical.finalBypassFinished(), .finishStop)
    }

    func testSystemDomainDropDoesNotDependOnRecognizingTLSBytes() {
        let policy = makePolicy(domains: ["coinbase.com"])
        let plan = MacFilterInterceptionPlan.make(for: policy, at: activeDate)

        XCTAssertEqual(plan.defaultAction, .allow)
        XCTAssertTrue(plan.blockedDomainSuffixes.contains("coinbase.com"))
        // No payload-inspection rule is installed for the domain-only mode.
        // Fragmented ClientHello, ECH, and a retry without visible SNI cannot
        // turn the blocked hostname rule into the ordinary default action.
        XCTAssertEqual(plan.mode, .domainRules)
    }

    func testInactiveDomainRuleBypassesProviderEntirely() {
        let policy = makePolicy(domains: ["blocked.example"])
        let plan = MacFilterInterceptionPlan.make(
            for: policy,
            at: activeDate.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(plan.mode, .bypass)
        XCTAssertEqual(plan.defaultAction, .allow)
        XCTAssertTrue(plan.blockedDomainSuffixes.isEmpty)
    }

    func testFortressAndApplicationRulesRetainProviderInspection() {
        let fortress = MacFilterInterceptionPlan.make(
            for: makePolicy(mode: .fortressAllowList, domains: ["allowed.example"]),
            at: activeDate
        )
        XCTAssertEqual(fortress.mode, .providerInspection)
        XCTAssertEqual(fortress.defaultAction, .filterData)

        let applicationPolicy = DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: activeDate,
            rules: [
                rule(
                    name: "App",
                    mode: .blockList,
                    domains: [],
                    macApplicationIdentifiers: ["com.example.app"]
                )
            ]
        )
        let application = MacFilterInterceptionPlan.make(for: applicationPolicy, at: activeDate)
        XCTAssertEqual(application.mode, .providerInspection)
        XCTAssertEqual(application.defaultAction, .filterData)
    }

    // MARK: - A flow that cannot write before connect must be released

    func testUnclassifiedFlowIsReleasedWhenItsOutboundStreamEnds() {
        let policy = makePolicy(domains: ["blocked.example"])
        // Exactly what the provider sees before a BSD socket reports connect.
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443)

        XCTAssertEqual(
            WebFilterFlowDecider.decision(for: flow, policy: policy, at: activeDate),
            .allow,
            "New-flow payload inspection can prevent the client from ever producing payload"
        )
        XCTAssertEqual(
            WebFilterFlowDecider.decisionAtOutboundCompletion(
                for: flow,
                policy: policy,
                at: activeDate
            ).decision,
            .allow,
            "An unclassified flow must never be converted into a drop at completion"
        )
    }

    /// The name is authoritative, so holding a blocked flow back for fast
    /// failure still cannot be escaped by simply writing nothing.
    func testNamedBlockedFlowIsStillDroppedWhenItsOutboundStreamEnds() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(hostname: "www.blocked.example", remotePort: 443)
        let outcome = WebFilterFlowDecider.decisionAtOutboundCompletion(
            for: flow,
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(outcome.decision, .drop)
        XCTAssertEqual(outcome.dropKind, .named)
    }

    func testFortressStillFailsClosedWhenAnUnclassifiedStreamEnds() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443)
        XCTAssertEqual(
            WebFilterFlowDecider.decisionAtOutboundCompletion(
                for: flow,
                policy: policy,
                at: activeDate
            ).decision,
            .drop
        )
    }

    func testCompletionIsAPassThroughWhenNothingIsActuallyBlocked() {
        let policy = makePolicy(domains: [])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443)
        XCTAssertEqual(
            WebFilterFlowDecider.decisionAtOutboundCompletion(
                for: flow,
                policy: policy,
                at: activeDate
            ).decision,
            .allow
        )
    }

    // MARK: - A rule that blocks nothing must not change anything

    /// Three of the six rules on the live machine name zero domains, and their
    /// windows cover nearly the whole day. If an empty rule switched on
    /// fail-closed handling it would impose the entire regime while blocking
    /// nothing at all.
    func testZeroDomainBlockListRuleEnablesNoEnforcementAtAll() {
        let policy = makePolicy(domains: [])
        XCTAssertFalse(policy.activeRules(at: activeDate).isEmpty, "Precondition: the rule's window is open")
        XCTAssertFalse(policy.hasActiveWebRestrictions(at: activeDate))

        let cases: [(String, WebFilterFlowDescriptor)] = [
            ("unnamed TCP 443", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443)),
            ("unnamed QUIC 443", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443, isTCP: false)),
            ("DoT 853", WebFilterFlowDescriptor(remoteAddress: "9.9.9.9", remotePort: 853)),
            ("named host", WebFilterFlowDescriptor(hostname: "anything.example", remotePort: 443)),
            ("unnamed TCP 80", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 80))
        ]
        for (label, flow) in cases {
            XCTAssertEqual(
                WebFilterFlowDecider.decision(for: flow, policy: policy, at: activeDate),
                .allow,
                "A rule naming no domains must not touch \(label)"
            )
        }
    }

    /// A zero-domain rule sitting alongside a real one must not widen the real
    /// one's reach either.
    func testZeroDomainRuleAlongsideARealRuleAddsNoDrops() {
        let policy = makePolicy(domains: ["blocked.example"], extraEmptyRule: true)
        XCTAssertTrue(policy.hasActiveWebRestrictions(at: activeDate))
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                for: WebFilterFlowDescriptor(hostname: "unrelated.example", remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .allow
        )
    }

    // MARK: - Domain-only policies never enter synchronous Security APIs

    func testDomainOnlyPolicyDoesNotRequestSourceIdentityResolution() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertTrue(policy.hasActiveWebRestrictions(at: activeDate))
        XCTAssertFalse(policy.hasActiveMacApplicationRestrictions(at: activeDate))
    }

    func testActiveApplicationRuleRequestsSourceIdentityResolution() {
        let policy = DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: activeDate,
            rules: [
                rule(
                    name: "App",
                    mode: .blockList,
                    domains: [],
                    macApplicationIdentifiers: ["com.example.app"]
                )
            ]
        )
        XCTAssertTrue(policy.hasActiveMacApplicationRestrictions(at: activeDate))
    }

    // MARK: - Ordinary unidentified traffic survives

    func testOrdinaryUnidentifiedTrafficIsAllowedWhileABlockListRuleRuns() {
        let policy = makePolicy(domains: ["blocked.example"])
        let cases: [(String, WebFilterFlowDescriptor)] = [
            ("SSH", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 22)),
            ("IMAPS", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 993)),
            ("STUN", WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 3478, isTCP: false))
        ]
        for (label, flow) in cases {
            XCTAssertEqual(
                WebFilterFlowDecider.decision(for: flow, policy: policy, at: activeDate),
                .allow,
                "\(label) has nothing to do with the block list"
            )
        }
    }

    /// The machine's only DNS resolver is at 100.64.0.2, inside the VPN's
    /// carrier-grade NAT range and reachable only through the tunnel. Refusing
    /// anything there costs the system name resolution, which presents as a
    /// total outage rather than as a blocked site.
    func testSharedAddressSpaceIsTreatedAsLocalScope() {
        XCTAssertTrue(WebFilterFlowDecider.isLocalScope("100.64.0.2"))
        XCTAssertTrue(WebFilterFlowDecider.isLocalScope("100.100.100.100"))
        XCTAssertTrue(WebFilterFlowDecider.isLocalScope("100.127.255.255"))
        // The rest of 100/8 is ordinary public space and must stay filtered.
        XCTAssertFalse(WebFilterFlowDecider.isLocalScope("100.63.255.255"))
        XCTAssertFalse(WebFilterFlowDecider.isLocalScope("100.128.0.1"))
    }

    func testSharedAddressSpaceStaysReachableEvenUnderFortress() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "100.64.0.2", remotePort: 53, isTCP: false)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(for: flow, policy: policy, at: activeDate),
            .allow
        )
    }

    // MARK: - Drop kinds feed the safety valve

    func testDropsTheUserAskedForAreClassifiedAsNamed() {
        let policy = makePolicy(domains: ["blocked.example"])
        let outcome = WebFilterFlowDecider.outcome(
            for: WebFilterFlowDescriptor(hostname: "blocked.example", remotePort: 8080),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(outcome.decision, .drop)
        XCTAssertEqual(outcome.dropKind, .named)

        let refused = WebFilterFlowDecider.outcome(
            for: WebFilterFlowDescriptor(hostname: "blocked.example", remotePort: 9999),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(refused.decision, .drop)
        XCTAssertEqual(refused.dropKind, .named, "A named drop must never count toward the fail-open valve")
    }

    func testFortressGuessesAreClassifiedAsUnidentified() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        let outcome = WebFilterFlowDecider.outcome(
            for: WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 9999),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(outcome.decision, .drop)
        XCTAssertEqual(outcome.dropKind, .unidentified)
    }

    // MARK: - Diagnostic reasons stay pinned to the outage branches

    func testDecisionReasonsIdentifyIncompleteAndTerminalTLS() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(
            remoteAddress: "93.184.216.34",
            remotePort: 443
        )
        let newFlow = WebFilterFlowDecider.outcome(
            for: flow,
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(newFlow.reason, .unnamedPreconnectAllowed)

        // TLS record header declaring 64 bytes while only the header is here.
        let incomplete = WebFilterFlowDecider.outcome(
            forOutboundBytes: Data([0x16, 0x03, 0x03, 0x00, 0x40]),
            flow: flow,
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(incomplete.reason, .tlsIncomplete)

        let completion = WebFilterFlowDecider.decisionAtOutboundCompletion(
            for: flow,
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(completion.reason, .completionUnclassifiedAllowed)
    }

    func testUnnamedQUICUsesTheSafetyValveInEveryPolicyMode() {
        let flow = WebFilterFlowDescriptor(
            remoteAddress: "93.184.216.34",
            remotePort: 443,
            isTCP: false
        )
        XCTAssertEqual(
            WebFilterFlowDecider.outcome(
                for: flow,
                policy: makePolicy(domains: ["blocked.example"]),
                at: activeDate
            ).reason,
            .unnamedQUICBlocked
        )
        XCTAssertEqual(
            WebFilterFlowDecider.outcome(
                for: flow,
                policy: makePolicy(mode: .fortressAllowList, domains: ["allowed.example"]),
                at: activeDate
            ).reason,
            .unnamedQUICBlocked
        )
    }

    func testRecentlyBlockedEndpointRefusesAnUnclassifiedRetryWithoutHoldingIt() {
        let policy = makePolicy(domains: ["blocked.example"])
        let retry = WebFilterFlowDescriptor(
            remoteAddress: "93.184.216.34",
            remotePort: 443
        )
        let outcome = WebFilterFlowDecider.outcome(
            for: retry,
            policy: policy,
            at: activeDate,
            matchesRecentlyBlockedEndpoint: true
        )
        XCTAssertEqual(outcome.decision, .drop)
        XCTAssertEqual(outcome.reason, .correlatedBlockedEndpoint)
        XCTAssertEqual(outcome.dropKind, .named)
    }

    func testRepeatedCorrelatedRetriesCannotTripFailOpen() {
        let policy = makePolicy(domains: ["coinbase.com"])
        let retry = WebFilterFlowDescriptor(
            remoteAddress: "104.18.18.18",
            remotePort: 443
        )
        let governor = WebFilterFailOpenGovernor(
            threshold: 5,
            window: 60,
            cooldown: 300,
            now: activeDate
        )

        for index in 0..<500 {
            let at = activeDate.addingTimeInterval(Double(index) * 0.01)
            let outcome = WebFilterFlowDecider.outcome(
                for: retry,
                policy: policy,
                at: at,
                matchesRecentlyBlockedEndpoint: true
            )
            XCTAssertEqual(outcome.reason, .correlatedBlockedEndpoint)
            guard let dropKind = outcome.dropKind else {
                XCTFail("A correlated retry must produce a drop kind")
                return
            }
            governor.record(dropKind, at: at)
        }

        XCTAssertFalse(governor.isFailedOpen(at: activeDate.addingTimeInterval(5)))
        XCTAssertEqual(governor.trips, 0)
    }

    // MARK: - Helpers

    private var activeDate: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 12).date!
    }

    private func makePolicy(
        mode: DesktopEnforcementRule.Mode = .blockList,
        domains: Set<String>,
        extraEmptyRule: Bool = false
    ) -> DesktopEnforcementPolicy {
        var rules = [rule(name: "Test", mode: mode, domains: domains)]
        if extraEmptyRule {
            rules.append(rule(name: "Empty", mode: .blockList, domains: []))
        }
        return DesktopEnforcementPolicy(revision: 1, issuedAt: Date(), rules: rules)
    }

    private func rule(
        name: String,
        mode: DesktopEnforcementRule.Mode,
        domains: Set<String>,
        macApplicationIdentifiers: Set<String> = []
    ) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(),
            name: name,
            isEnabled: true,
            enforcementMode: mode,
            windows: [DesktopTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)],
            domains: domains,
            macApplicationIdentifiers: macApplicationIdentifiers,
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(
                severity: "passageOnly",
                unlockDelayDays: 0,
                passageWordCount: 10,
                confirmationWindowHours: 1,
                editWindowHours: 1,
                allowsTimeExtensions: false,
                maximumTimeExtensionHours: 0
            )
        )
    }
}

final class BlockedEndpointCorrelationCacheTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testCorrelationIsPortAndRevisionScoped() {
        let cache = BlockedEndpointCorrelationCache(timeToLive: 30)
        cache.record(address: "[2001:DB8::1]", port: 443, policyRevision: 7, at: start)

        XCTAssertTrue(cache.contains(
            address: "2001:db8::1",
            port: 443,
            policyRevision: 7,
            at: start.addingTimeInterval(1)
        ))
        XCTAssertFalse(cache.contains(
            address: "2001:db8::1",
            port: 80,
            policyRevision: 7,
            at: start.addingTimeInterval(1)
        ))
        XCTAssertFalse(cache.contains(
            address: "2001:db8::1",
            port: 443,
            policyRevision: 8,
            at: start.addingTimeInterval(1)
        ))
    }

    func testCorrelationExpiresRatherThanBecomingAnIPBlock() {
        let cache = BlockedEndpointCorrelationCache(timeToLive: 5)
        cache.record(address: "93.184.216.34", port: 443, policyRevision: 7, at: start)
        XCTAssertTrue(cache.contains(
            address: "93.184.216.34",
            port: 443,
            policyRevision: 7,
            at: start.addingTimeInterval(4.9)
        ))
        XCTAssertFalse(cache.contains(
            address: "93.184.216.34",
            port: 443,
            policyRevision: 7,
            at: start.addingTimeInterval(5)
        ))
    }

    func testRuntimeRuleSetChangeClearsSameRevisionCorrelation() {
        let cache = BlockedEndpointCorrelationCache(timeToLive: 30)
        cache.record(address: "93.184.216.34", port: 443, policyRevision: 7, at: start)
        cache.removeAll()
        XCTAssertFalse(cache.contains(
            address: "93.184.216.34",
            port: 443,
            policyRevision: 7,
            at: start.addingTimeInterval(1)
        ))
    }
}

/// Drop pressure is diagnostic evidence, never authorization for a bypass.
final class WebFilterFailOpenGovernorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartsClosed() {
        let governor = WebFilterFailOpenGovernor(now: start)
        XCTAssertFalse(governor.isFailedOpen(at: start))
        XCTAssertEqual(governor.trips, 0)
    }

    /// The valve's whole value depends on this. If drops the user asked for
    /// counted, reloading a blocked page enough times would switch enforcement
    /// off — the valve would be the easiest bypass in the product.
    func testNamedDropsNeverTripTheValve() {
        let governor = WebFilterFailOpenGovernor(threshold: 5, window: 60, cooldown: 300, now: start)
        for index in 0..<500 {
            governor.record(.named, at: start.addingTimeInterval(Double(index) * 0.01))
        }
        XCTAssertFalse(governor.isFailedOpen(at: start.addingTimeInterval(5)))
        XCTAssertEqual(governor.trips, 0)
    }

    func testUnidentifiedDropStormWarnsWithoutAllowingTraffic() {
        let governor = WebFilterFailOpenGovernor(threshold: 5, window: 60, cooldown: 300, now: start)
        var tripped = false
        for index in 0..<5 {
            tripped = governor.record(.unidentified, at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertTrue(tripped, "The call that crosses the threshold reports the transition")
        XCTAssertFalse(governor.isFailedOpen(at: start.addingTimeInterval(5)))
        XCTAssertTrue(governor.state(at: start.addingTimeInterval(5)).warningActive)
        XCTAssertEqual(governor.trips, 1)
    }

    func testTheTransitionIsReportedOnlyOnce() {
        let governor = WebFilterFailOpenGovernor(threshold: 2, window: 60, cooldown: 300, now: start)
        XCTAssertFalse(governor.record(.unidentified, at: start))
        XCTAssertTrue(governor.record(.unidentified, at: start.addingTimeInterval(1)))
        XCTAssertFalse(
            governor.record(.unidentified, at: start.addingTimeInterval(2)),
            "Logging the trip repeatedly would bury the one line that matters"
        )
    }

    /// Drops spread thinly are ordinary enforcement, not a fault.
    func testDropsSpreadBeyondTheWindowDoNotTrip() {
        let governor = WebFilterFailOpenGovernor(threshold: 5, window: 60, cooldown: 300, now: start)
        for index in 0..<40 {
            let at = start.addingTimeInterval(Double(index) * 61)
            XCTAssertFalse(governor.record(.unidentified, at: at))
        }
        XCTAssertFalse(governor.isFailedOpen(at: start.addingTimeInterval(40 * 61)))
    }

    func testWarningExpiresButEnforcementNeverPauses() {
        let governor = WebFilterFailOpenGovernor(threshold: 2, window: 60, cooldown: 300, now: start)
        governor.record(.unidentified, at: start)
        governor.record(.unidentified, at: start)
        XCTAssertFalse(governor.isFailedOpen(at: start.addingTimeInterval(299)))
        XCTAssertTrue(governor.state(at: start.addingTimeInterval(299)).warningActive)
        XCTAssertFalse(governor.isFailedOpen(at: start.addingTimeInterval(301)))
        XCTAssertFalse(governor.state(at: start.addingTimeInterval(301)).warningActive)
    }

    func testStateReportsTripWindowAndRearm() {
        let governor = WebFilterFailOpenGovernor(threshold: 2, window: 60, cooldown: 300, now: start)
        governor.record(.unidentified, at: start)
        governor.record(.unidentified, at: start.addingTimeInterval(1))

        let open = governor.state(at: start.addingTimeInterval(2))
        XCTAssertFalse(open.isOpen)
        XCTAssertTrue(open.warningActive)
        XCTAssertEqual(open.trips, 0, "No actual fail-open occurred")
        XCTAssertNil(open.openUntil)

        let rearmed = governor.state(at: start.addingTimeInterval(302))
        XCTAssertFalse(rearmed.isOpen)
        XCTAssertNil(rearmed.openUntil)
        XCTAssertEqual(rearmed.trips, 0)
        XCTAssertFalse(rearmed.warningActive)
        XCTAssertEqual(rearmed.unidentifiedDropsInWindow, 0)
    }

    /// Sustained pressure must be reported again after the deduplication window.
    func testAPersistentFaultTripsAgain() {
        let governor = WebFilterFailOpenGovernor(threshold: 2, window: 60, cooldown: 300, now: start)
        governor.record(.unidentified, at: start)
        governor.record(.unidentified, at: start)
        let later = start.addingTimeInterval(400)
        XCTAssertFalse(governor.isFailedOpen(at: later))
        governor.record(.unidentified, at: later)
        XCTAssertTrue(governor.record(.unidentified, at: later.addingTimeInterval(1)))
        XCTAssertEqual(governor.trips, 2)
        XCTAssertFalse(governor.isFailedOpen(at: later.addingTimeInterval(2)))
    }

    /// The production numbers must sit far above ordinary enforcement, or the
    /// valve fires on a working filter.
    func testProductionThresholdIsWellAboveNormalTraffic() {
        XCTAssertGreaterThanOrEqual(WebFilterFailOpenGovernor.defaultThreshold, 100)
        XCTAssertEqual(WebFilterFailOpenGovernor.defaultWindow, 60)
        XCTAssertGreaterThan(WebFilterFailOpenGovernor.defaultCooldown, 0)
    }
}

final class MacFilterSmokeTestRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testOrdinaryLaunchHasNoSmokeTestRequest() throws {
        XCTAssertNil(try MacFilterSmokeTestRequest.parse(arguments: ["app"], now: now))
    }

    func testValidBoundedRequestParses() throws {
        let deadline = now.addingTimeInterval(15)
        let request = try XCTUnwrap(MacFilterSmokeTestRequest.parse(
            arguments: [
                "app",
                MacFilterSmokeTestRequest.enableFlag,
                "\(MacFilterSmokeTestRequest.identifierPrefix)\(identifier.uuidString)",
                "\(MacFilterSmokeTestRequest.deadlinePrefix)\(deadline.timeIntervalSince1970 * 1_000)"
            ],
            now: now
        ))
        XCTAssertEqual(request.identifier, identifier)
        XCTAssertEqual(request.deadline, deadline)
    }

    func testMissingIdentifierIsRefused() {
        XCTAssertThrowsError(try MacFilterSmokeTestRequest.parse(
            arguments: [
                "app",
                MacFilterSmokeTestRequest.enableFlag,
                "\(MacFilterSmokeTestRequest.deadlinePrefix)\(now.addingTimeInterval(15).timeIntervalSince1970 * 1_000)"
            ],
            now: now
        )) { XCTAssertEqual($0 as? MacFilterSmokeTestRequest.ParseError, .missingIdentifier) }
    }

    func testExpiredDeadlineIsRefused() {
        XCTAssertThrowsError(try MacFilterSmokeTestRequest.parse(
            arguments: arguments(deadline: now.addingTimeInterval(-1)),
            now: now
        )) { XCTAssertEqual($0 as? MacFilterSmokeTestRequest.ParseError, .deadlineNotInFuture) }
    }

    func testDeadlineBeyondHardMaximumIsRefused() {
        XCTAssertThrowsError(try MacFilterSmokeTestRequest.parse(
            arguments: arguments(deadline: now.addingTimeInterval(31)),
            now: now
        )) { XCTAssertEqual($0 as? MacFilterSmokeTestRequest.ParseError, .durationTooLong) }
    }

    private func arguments(deadline: Date) -> [String] {
        [
            "app",
            MacFilterSmokeTestRequest.enableFlag,
            "\(MacFilterSmokeTestRequest.identifierPrefix)\(identifier.uuidString)",
            "\(MacFilterSmokeTestRequest.deadlinePrefix)\(deadline.timeIntervalSince1970 * 1_000)"
        ]
    }
}

final class MacFilterSmokeTestRecoveryDispositionTests: XCTestCase {
    func testCooperativeDeadlineDisableDoesNotBecomeAbandonedRun() {
        XCTAssertEqual(
            MacFilterSmokeTestRecoveryDisposition.resolve(
                arguments: ["app", "--disable-web-filter-now"],
                hasActiveMarker: true
            ),
            .forcedHealthyDisable
        )
    }

    func testOutageDisableRetainsUnsafeClassification() {
        XCTAssertEqual(
            MacFilterSmokeTestRecoveryDisposition.resolve(
                arguments: ["app", "--disable-web-filter-now", "--mark-filter-startup-unsafe"],
                hasActiveMarker: true
            ),
            .forcedUnsafeDisable
        )
    }

    func testUnexplainedMarkerIsStillAnAbandonedRun() {
        XCTAssertEqual(
            MacFilterSmokeTestRecoveryDisposition.resolve(arguments: ["app"], hasActiveMarker: true),
            .abandonedRun
        )
    }
}
