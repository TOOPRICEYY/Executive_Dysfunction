import XCTest
// The desktop decision layer is compiled directly into this hostless test
// bundle; see project.yml. Importing the app module would drag in
// NetworkExtension and a live filter configuration.

final class DesktopEnforcementPolicyTests: XCTestCase {
    func testContainingMacAppCanResolveRetryGuardsWhileSandboxed() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let configDirectory = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Config")

        for name in ["MacDevelopment.entitlements", "Mac.entitlements"] {
            let data = try Data(contentsOf: configDirectory.appendingPathComponent(name))
            let entitlements = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
            )
            XCTAssertEqual(
                entitlements["com.apple.security.network.client"] as? Bool,
                true,
                "The containing app prepares retry guards with DNS-SD before enabling the filter"
            )
        }
    }

    func testSystemExtensionInfoPlistDeclaresNetworkExtensionCategory() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let plistURL = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Config/MacWebFilterExtension-Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "SYSX")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "$(CURRENT_PROJECT_VERSION)")
        let networkExtension = try XCTUnwrap(plist["NetworkExtension"] as? [String: Any])
        let providerClasses = try XCTUnwrap(networkExtension["NEProviderClasses"] as? [String: String])
        let machServiceName = try XCTUnwrap(networkExtension["NEMachServiceName"] as? String)
        XCTAssertTrue(machServiceName.hasPrefix("group.com.GabrielPrice.ExecutiveDysfunction"))
        XCTAssertNotNil(providerClasses["com.apple.networkextension.filter-data"])
        // The packet provider is deliberately absent. Every recorded crash of
        // this extension was a SIGSEGV inside NEFilterPacketInterpose's
        // createChannel, so hosting it turned one website rule into an unstable
        // network path. DNS questions and dedicated encrypted-DNS ports are
        // handled by the data provider instead.
        XCTAssertNil(
            providerClasses["com.apple.networkextension.filter-packet"],
            "Re-adding the packet provider reintroduces a machine-wide outage"
        )
    }

    func testBlockListMatchesDomainAndSubdomains() {
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        XCTAssertTrue(policy.blocksDomain("example.com", at: activeDate))
        XCTAssertTrue(policy.blocksDomain("media.example.com", at: activeDate))
        XCTAssertFalse(policy.blocksDomain("notexample.com", at: activeDate))
    }

    func testInactiveWindowDoesNotBlock() {
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        XCTAssertFalse(policy.blocksDomain("example.com", at: inactiveDate))
    }

    func testFortressAllowsOnlyConfiguredDomain() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        XCTAssertFalse(policy.blocksDomain("allowed.example", at: activeDate))
        XCTAssertFalse(policy.blocksDomain("cdn.allowed.example", at: activeDate))
        XCTAssertTrue(policy.blocksDomain("distraction.example", at: activeDate))
    }

    func testTemporaryPauseExcludesOnlyTheAuthorizedRuleWithoutChangingRevision() {
        var policy = makePolicy(mode: .blockList, domains: ["one.example"])
        var second = policy.rules[0]
        second.id = UUID()
        second.domains = ["two.example"]
        policy.rules.append(second)

        let effective = policy.excludingTemporarilyPausedRules([policy.rules[0].id])

        XCTAssertEqual(effective.revision, policy.revision)
        XCTAssertFalse(effective.blocksDomain("one.example", at: activeDate))
        XCTAssertTrue(effective.blocksDomain("two.example", at: activeDate))
        XCTAssertEqual(effective.rules.map(\.id), [second.id])
    }

    func testTemporaryPauseFingerprintIsBoundToRuleAndPolicyRevision() {
        let policy = makePolicy(mode: .blockList, domains: ["one.example"])
        let ruleID = policy.rules[0].id
        let fingerprint = policy.temporaryPauseFingerprint(for: ruleID)
        var newer = policy
        newer.revision += 1

        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertNotEqual(fingerprint, newer.temporaryPauseFingerprint(for: ruleID))
        XCTAssertNotEqual(fingerprint, policy.temporaryPauseFingerprint(for: UUID()))
    }

    func testTemporaryPauseValidationRequiresExactRevisionFingerprintAndOptIn() {
        var policy = makePolicy(mode: .blockList, domains: ["one.example"])
        policy.rules[0].lockdown.allowsTimeExtensions = true
        let ruleID = policy.rules[0].id
        let pause = BlockPageTemporaryPause(
            ruleID: ruleID,
            policyRevision: policy.revision,
            policyFingerprint: policy.temporaryPauseFingerprint(for: ruleID),
            grantedAt: activeDate,
            expiresAt: activeDate.addingTimeInterval(600),
            durationSeconds: 600,
            requestID: UUID()
        )

        XCTAssertEqual(
            policy.validatedTemporaryPauseExpirations(
                from: [pause],
                at: activeDate.addingTimeInterval(1)
            )[ruleID],
            pause.expiresAt
        )

        var wrongRevision = pause
        wrongRevision.policyRevision += 1
        XCTAssertTrue(policy.validatedTemporaryPauseExpirations(
            from: [wrongRevision],
            at: activeDate.addingTimeInterval(1)
        ).isEmpty)

        policy.rules[0].lockdown.allowsTimeExtensions = false
        XCTAssertTrue(policy.validatedTemporaryPauseExpirations(
            from: [pause],
            at: activeDate.addingTimeInterval(1)
        ).isEmpty)
    }

    func testBackoffPolicyRequiresNativePassageAndProtectsResetChanges() throws {
        var cloud = CloudRulePreference(name: "Backoff")
        cloud.isEnabled = true
        cloud.domains = [.init(domain: "one.example", category: "social", source: "user")]
        cloud.lockdown = .init(severity: "passageOnly", allowsTimeExtensions: true, temporaryAllowanceResetDays: 7)
        let published = DesktopEnforcementPolicy(cloudRules: [cloud], revision: 1)
        XCTAssertFalse(published.rules[0].lockdown.allowsTimeExtensions, "Legacy browser opt-in must be off even for old providers")
        XCTAssertEqual(published.rules[0].lockdown.requiresNativeTemporaryAccess, true)
        XCTAssertTrue(DesktopBlockProfile(cloudRules: [cloud]).rules[0].lockdown.allowsTimeExtensions, "Native grants remain available")
        var policy = makePolicy(mode: .blockList, domains: ["one.example"])
        policy.rules[0].lockdown.allowsTimeExtensions = true
        policy.rules[0].lockdown.temporaryAllowanceResetDays = 7
        policy.rules[0].lockdown.severity = "passageOnly"
        policy.revision = max(1, policy.revision)
        let ruleID = policy.rules[0].id
        let status = FilterEnforcementStatus(policy: policy, at: activeDate)
        let descriptor = try XCTUnwrap(status.blockPageRules?.first)
        XCTAssertFalse(descriptor.allowsTimeExtensions)
        XCTAssertEqual(descriptor.requiresAppForTemporaryAccess, true)
        let pause = BlockPageTemporaryPause(ruleID: ruleID, policyRevision: policy.revision,
            policyFingerprint: policy.temporaryPauseFingerprint(for: ruleID), grantedAt: activeDate,
            expiresAt: activeDate.addingTimeInterval(600), durationSeconds: 600, requestID: UUID())
        XCTAssertTrue(policy.validatedTemporaryPauseExpirations(from: [pause], at: activeDate).isEmpty)
        var weaker = policy
        weaker.rules[0].lockdown.temporaryAllowanceResetDays = nil
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: policy, with: weaker, at: activeDate))
        weaker.rules[0].lockdown.temporaryAllowanceResetDays = 3
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: policy, with: weaker, at: activeDate))
        weaker.rules[0].lockdown.temporaryAllowanceResetDays = 14
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: policy, with: weaker, at: activeDate))
        policy.rules[0].pausedUntil = activeDate.addingTimeInterval(600)
        let paused = FilterEnforcementStatus(policy: policy, at: activeDate)
        XCTAssertEqual(paused.temporaryAllowanceExpirations?[ruleID], policy.rules[0].pausedUntil)
        XCTAssertEqual(try JSONDecoder().decode(FilterEnforcementStatus.self, from: JSONEncoder().encode(paused)), paused)
    }

    func testSystemAndControllerExecutablesAreAlwaysRecoverable() {
        let policy = makePolicy(mode: .fortressAllowList, domains: [])
        XCTAssertFalse(policy.blocksApplication(signingIdentifier: "com.apple.TextEdit", executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", at: activeDate))
        XCTAssertFalse(policy.blocksApplication(signingIdentifier: "com.GabrielPrice.ExecutiveDysfunction", executablePath: "/Applications/Holdfast.app/Contents/MacOS/Holdfast", at: activeDate))
        XCTAssertTrue(policy.blocksApplication(signingIdentifier: "com.vendor.game", executablePath: "/Applications/Game.app/Contents/MacOS/Game", at: activeDate))
    }

    func testAuthenticatedPolicyRejectsTampering() throws {
        let key = Data(repeating: 0xA5, count: 32)
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        let code = try DesktopPolicyAuthenticator.authenticationCode(for: policy, key: key)
        var envelope = AuthenticatedDesktopPolicy(policy: policy, authenticationCode: code)
        XCTAssertEqual(try DesktopPolicyAuthenticator.authenticate(envelope, key: key), policy)
        envelope.policy.rules[0].domains = []
        XCTAssertThrowsError(try DesktopPolicyAuthenticator.authenticate(envelope, key: key))
    }

    func testMonotonicFallbackCannotAuthorizeWeakening() {
        let now = activeDate
        let existing = makePolicy(mode: .blockList, domains: ["one.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains = []
        proposed.weakeningAuthorizationExpiresAt = now.addingTimeInterval(60)

        // The file-store fallback clears this field before evaluation. Model
        // that boundary here so a forged shared file cannot relax a baseline.
        proposed.weakeningAuthorizationExpiresAt = nil
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(
            existing: existing,
            with: proposed,
            at: now
        ))
    }

    func testNetworkExtensionVendorConfigurationRoundTrip() throws {
        let policy = makePolicy(mode: .blockList, domains: ["coinbase.com"])
        let configuration = try DesktopPolicyConfigurationTransport.vendorConfiguration(for: policy)

        XCTAssertEqual(DesktopPolicyConfigurationTransport.revision(from: configuration), policy.revision)
        XCTAssertEqual(DesktopPolicyConfigurationTransport.policy(from: configuration), policy)
    }

    func testHTTPHostInspection() {
        let request = Data("GET / HTTP/1.1\r\nHost: media.example.com:443\r\n\r\n".utf8)
        XCTAssertEqual(NetworkHostnameInspector.hostname(in: request), "media.example.com")
    }

    func testDNSQueryInspection() {
        XCTAssertEqual(
            NetworkHostnameInspector.dnsQueryName(in: dnsQuery("media.example.com")),
            "media.example.com"
        )
    }

    func testKnownEncryptedDNSProviderIsBlockedDuringWebRule() {
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        XCTAssertTrue(policy.blocksNetworkHostname("dns.google", at: activeDate))
        XCTAssertFalse(policy.blocksNetworkHostname("dns.google", at: inactiveDate))
    }

    func testUnidentifiedHTTPSAndQUICAreNeverGloballyBlocked() {
        let policy = makePolicy(mode: .blockList, domains: ["coinbase.com"])
        XCTAssertFalse(policy.blocksUnidentifiedNetworkPort(80, at: activeDate))
        XCTAssertFalse(policy.blocksUnidentifiedNetworkPort(443, at: activeDate))
        XCTAssertFalse(policy.blocksUnidentifiedNetworkPort(nil, at: activeDate))
    }

    func testDedicatedEncryptedDNSPortsRemainBlockedDuringWebRule() {
        let policy = makePolicy(mode: .blockList, domains: ["coinbase.com"])
        XCTAssertTrue(policy.blocksUnidentifiedNetworkPort(784, at: activeDate))
        XCTAssertTrue(policy.blocksUnidentifiedNetworkPort(853, at: activeDate))
        XCTAssertTrue(policy.blocksUnidentifiedNetworkPort(8853, at: activeDate))
        XCTAssertFalse(policy.blocksUnidentifiedNetworkPort(853, at: inactiveDate))
    }

    func testPacketLayerAllowsOrdinaryQUICDuringActiveWebRule() {
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        XCTAssertFalse(NetworkPacketInspector.shouldDropOutboundPacket(
            ipv4UDPPacket(destinationPort: 443, payload: Data()),
            policy: policy,
            at: activeDate
        ))
    }

    func testPacketLayerDropsBlockedDNSAndAllowsUnblockedDNS() {
        let policy = makePolicy(mode: .blockList, domains: ["example.com"])
        XCTAssertTrue(NetworkPacketInspector.shouldDropOutboundPacket(
            ipv4UDPPacket(destinationPort: 53, payload: dnsQuery("media.example.com")),
            policy: policy,
            at: activeDate
        ))
        XCTAssertFalse(NetworkPacketInspector.shouldDropOutboundPacket(
            ipv4UDPPacket(destinationPort: 53, payload: dnsQuery("allowed.example")),
            policy: policy,
            at: activeDate
        ))
    }

    func testLockedRuleRejectsRemovedDomain() {
        let existing = makePolicy(mode: .blockList, domains: ["one.example", "two.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains.remove("two.example")
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed))
    }

    func testAddingBackoffAndIndependentStricterAccessPassageNeedsNoUnlock() {
        var old = makePolicy(mode: .blockList, domains: ["one.example"])
        old.rules[0].lockdown.severity = "passageOnly"
        old.rules[0].lockdown.allowsTimeExtensions = true
        old.rules[0].lockdown.passageWordCount = 40
        var new = old
        new.rules[0].lockdown.temporaryAllowanceResetDays = 1
        new.rules[0].lockdown.temporaryAccessPassageWordCount = 40
        new.rules[0].lockdown.unlockDelayDays = 0 // Inactive field for passage-only.
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: old, with: new))
        new.rules[0].lockdown.temporaryAccessPassageWordCount = 80
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: old, with: new))
        new.rules[0].lockdown.temporaryAccessPassageWordCount = 20
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: old, with: new))
        new = old
        new.rules[0].name = "Renamed"
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: old, with: new))
    }

    func testIndependentTemporaryPassageCannotUseLegacyBrowserGrant() {
        var cloud = CloudRulePreference(name: "Independent passages")
        cloud.lockdown = .init(severity: "passageOnly", passageWordCount: 40,
            allowsTimeExtensions: true, temporaryAccessPassageWordCount: 80)
        let published = DesktopEnforcementPolicy(cloudRules: [cloud], revision: 1)
        XCTAssertFalse(published.rules[0].lockdown.allowsTimeExtensions)
        XCTAssertEqual(published.rules[0].lockdown.requiresNativeTemporaryAccess, true)
        XCTAssertEqual(published.rules[0].lockdown.passageWordCount, 40)
        XCTAssertEqual(published.rules[0].lockdown.effectiveTemporaryAccessPassageWordCount, 80)
    }

    func testLockedRuleAcceptsAddedDomainAndCoverage() {
        let existing = makePolicy(mode: .blockList, domains: ["one.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains.insert("two.example")
        proposed.rules[0].windows[0].startMinutes -= 60
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed))
    }

    func testLockedPolicyAcceptsPurelyAdditiveRetreatRule() {
        let existing = makePolicy(mode: .blockList, domains: ["baseline.example"])
        var proposed = existing
        proposed.revision += 1
        var retreatRule = existing.rules[0]
        retreatRule.id = UUID()
        retreatRule.name = "Retreat addition"
        retreatRule.domains = ["retreat.example"]
        proposed.rules.append(retreatRule)

        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed))
    }

    func testDuplicateRuleIdentifiersAreRejectedInsteadOfCrashingOrWeakening() {
        let existing = makePolicy(mode: .blockList, domains: ["baseline.example"])
        var proposed = existing
        proposed.revision += 1
        var duplicate = proposed.rules[0]
        duplicate.domains = []
        proposed.rules.append(duplicate)

        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed))
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: .empty, with: proposed))
    }

    func testBlockProfileAccumulatesAllRulesBeforePolicyConstruction() {
        let first = CloudRulePreference(name: "Baseline", domains: [
            CloudDomainPreference(domain: "BASELINE.EXAMPLE", category: "other", source: "user")
        ])
        let second = CloudRulePreference(name: "Retreat", domains: [
            CloudDomainPreference(domain: "RETREAT.EXAMPLE", category: "other", source: "user")
        ])

        let profile = DesktopBlockProfile(cloudRules: [first, second])
        let policy = DesktopEnforcementPolicy(blockProfile: profile, revision: 1)

        XCTAssertEqual(policy.rules.count, 2)
        XCTAssertEqual(policy.rules[0].domains, ["baseline.example"])
        XCTAssertEqual(policy.rules[1].domains, ["retreat.example"])
    }

    func testAuthenticatedEditWindowAllowsWeakerCandidate() {
        let now = activeDate
        let existing = makePolicy(mode: .blockList, domains: ["one.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains = []
        proposed.weakeningAuthorizationExpiresAt = now.addingTimeInterval(60)
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed, at: now))
    }

    func testExpiredEditWindowDoesNotAllowWeakerCandidate() {
        let now = activeDate
        let existing = makePolicy(mode: .blockList, domains: ["one.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains = []
        proposed.weakeningAuthorizationExpiresAt = now.addingTimeInterval(-1)
        XCTAssertFalse(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed, at: now))
    }

    private var activeDate: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 12))!
    }

    private var inactiveDate: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 2))!
    }

    private func makePolicy(mode: DesktopEnforcementRule.Mode, domains: Set<String>) -> DesktopEnforcementPolicy {
        let weekday = Calendar.current.component(.weekday, from: activeDate)
        return DesktopEnforcementPolicy(
            revision: 1,
            issuedAt: activeDate,
            rules: [DesktopEnforcementRule(
                id: UUID(),
                name: "Test",
                isEnabled: true,
                enforcementMode: mode,
                windows: [.init(weekdays: [weekday], startMinutes: 9 * 60, endMinutes: 17 * 60)],
                domains: domains,
                macApplicationIdentifiers: mode == .fortressAllowList ? ["com.vendor.allowed"] : ["com.vendor.game"],
                windowsExecutablePaths: [],
                windowsPublisherRules: [],
                lockdown: DesktopLockdownPolicy(
                    severity: "delayed",
                    unlockDelayDays: 3,
                    passageWordCount: 40,
                    confirmationWindowHours: 24,
                    editWindowHours: 24,
                    allowsTimeExtensions: false,
                    maximumTimeExtensionHours: 3
                )
            )],
            weakeningAuthorizationExpiresAt: nil
        )
    }

    private func dnsQuery(_ hostname: String) -> Data {
        var bytes: [UInt8] = [
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        for label in hostname.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return Data(bytes)
    }

    private func ipv4UDPPacket(destinationPort: Int, payload: Data) -> Data {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 0x45
        bytes[9] = 17
        bytes[22] = UInt8((destinationPort >> 8) & 0xFF)
        bytes[23] = UInt8(destinationPort & 0xFF)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    // MARK: - Policy delivery must not wedge

    /// A baseline naming a rule the user has since deleted must not stop every
    /// later policy from applying. This wedged a live filter: it kept enforcing
    /// one stale snapshot, so domains added afterwards silently never blocked.
    func testVendorConfigurationAppliesEvenWhenBaselineNamesADeletedRule() throws {
        let loader = ResilientDesktopPolicyLoader(acceptedStore: InMemoryAcceptedPolicyStore())
        let stale = DesktopEnforcementPolicy(
            revision: 10,
            issuedAt: Date(),
            rules: [makeDesktopRule(name: "Deleted", domains: ["old.example"])]
        )
        let fresh = DesktopEnforcementPolicy(
            revision: 11,
            issuedAt: Date(),
            rules: [makeDesktopRule(name: "Current", domains: ["blocked.example"])]
        )
        // The stale baseline's rule id is absent from the fresh policy.
        XCTAssertFalse(
            DesktopPolicyRestrictionEvaluator.canReplace(existing: stale, with: fresh),
            "precondition: the strict evaluator rejects this pairing"
        )

        let applied = loader.current(
            vendorConfiguration: try DesktopPolicyConfigurationTransport.vendorConfiguration(for: fresh)
        )
        XCTAssertEqual(applied.revision, 11)
        XCTAssertTrue(applied.blocksDomain("blocked.example", at: alwaysActiveDate))
    }

    /// Rollback is still refused, so the authoritative channel cannot be
    /// replayed with an older policy.
    func testVendorConfigurationStillRefusesRollback() throws {
        let loader = ResilientDesktopPolicyLoader(acceptedStore: InMemoryAcceptedPolicyStore())
        let newer = DesktopEnforcementPolicy(
            revision: 20,
            issuedAt: Date(),
            rules: [makeDesktopRule(name: "Current", domains: ["blocked.example"])]
        )
        _ = loader.current(
            vendorConfiguration: try DesktopPolicyConfigurationTransport.vendorConfiguration(for: newer)
        )
        let older = DesktopEnforcementPolicy(
            revision: 5,
            issuedAt: Date(),
            rules: [makeDesktopRule(name: "Current", domains: [])]
        )
        let applied = loader.current(
            vendorConfiguration: try DesktopPolicyConfigurationTransport.vendorConfiguration(for: older)
        )
        XCTAssertEqual(applied.revision, 20, "an older revision must not replace a newer one")
    }

    private var alwaysActiveDate: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 12).date!
    }

    private func makeDesktopRule(name: String, domains: Set<String>) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(),
            name: name,
            isEnabled: true,
            enforcementMode: .blockList,
            windows: [DesktopTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_439)],
            domains: domains,
            macApplicationIdentifiers: [],
            windowsExecutablePaths: [],
            windowsPublisherRules: [],
            lockdown: DesktopLockdownPolicy(
                severity: "appDefault",
                unlockDelayDays: 3,
                passageWordCount: 40,
                confirmationWindowHours: 24,
                editWindowHours: 24,
                allowsTimeExtensions: false,
                maximumTimeExtensionHours: 3
            )
        )
    }
}

extension DesktopEnforcementPolicyTests {
    private func pausableRule(
        id: UUID = UUID(),
        allowsTimeExtensions: Bool = true
    ) -> CloudRulePreference {
        var rule = CloudRulePreference()
        rule.id = id
        rule.name = "Feeds"
        rule.isEnabled = true
        rule.enforcementMode = "blockList"
        rule.windows = [CloudTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_440)]
        rule.domains = [CloudDomainPreference(domain: "news.example", category: "news", source: "manual")]
        rule.lockdown.allowsTimeExtensions = allowsTimeExtensions
        rule.lockdown.maximumTimeExtensionHours = 2
        return rule
    }

    /// A pause is what "disable temporarily" writes. While it is in force the
    /// rule must stop matching, and it must resume by itself at expiry with no
    /// further action from the app.
    func testPausedRuleStopsBlockingUntilItExpires() {
        let now = Date()
        let rule = pausableRule()
        let policy = DesktopEnforcementPolicy(
            cloudRules: [rule],
            revision: 1,
            issuedAt: now,
            temporaryPauses: [rule.id: now.addingTimeInterval(600)]
        )

        XCTAssertFalse(policy.blocksDomain("news.example", at: now))
        XCTAssertFalse(policy.blocksDomain("news.example", at: now.addingTimeInterval(599)))
        XCTAssertTrue(policy.blocksDomain("news.example", at: now.addingTimeInterval(601)))
    }

    func testUnpausedRuleStillBlocks() {
        let now = Date()
        let policy = DesktopEnforcementPolicy(cloudRules: [pausableRule()], revision: 1, issuedAt: now)

        XCTAssertTrue(policy.blocksDomain("news.example", at: now))
    }

    /// A pause may only exist for a rule that opted into temporary access, so a
    /// stale or hand-edited record cannot weaken a rule that never allowed one.
    func testPauseIsIgnoredForARuleThatDisallowsTemporaryAccess() {
        let now = Date()
        let rule = pausableRule(allowsTimeExtensions: false)
        let policy = DesktopEnforcementPolicy(
            cloudRules: [rule],
            revision: 1,
            issuedAt: now,
            temporaryPauses: [rule.id: now.addingTimeInterval(600)]
        )

        XCTAssertTrue(policy.blocksDomain("news.example", at: now))
    }

    /// A missing field means "not paused". A policy written before pauses
    /// existed must decode and keep enforcing.
    func testPolicyWithoutAPauseFieldDecodesAsUnpaused() throws {
        let now = Date()
        let policy = DesktopEnforcementPolicy(cloudRules: [pausableRule()], revision: 1, issuedAt: now)
        let encoded = try JSONEncoder().encode(policy)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var rules = try XCTUnwrap(object["rules"] as? [[String: Any]])
        rules[0].removeValue(forKey: "pausedUntil")
        object["rules"] = rules

        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DesktopEnforcementPolicy.self, from: stripped)

        XCTAssertFalse(decoded.rules[0].isPaused(at: now))
        XCTAssertTrue(decoded.blocksDomain("news.example", at: now))
    }
}
