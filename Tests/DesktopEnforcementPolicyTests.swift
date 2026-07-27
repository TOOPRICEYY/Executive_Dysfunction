import XCTest
@testable import ExecutiveDysfunctionMac

final class DesktopEnforcementPolicyTests: XCTestCase {
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
        // createChannel, and macOS drops all traffic while a content filter is
        // not answering, so hosting it turned one website rule into a total
        // loss of network. DNS questions and dedicated encrypted-DNS ports are
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

    func testSystemAndControllerExecutablesAreAlwaysRecoverable() {
        let policy = makePolicy(mode: .fortressAllowList, domains: [])
        XCTAssertFalse(policy.blocksApplication(signingIdentifier: "com.apple.TextEdit", executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", at: activeDate))
        XCTAssertFalse(policy.blocksApplication(signingIdentifier: "com.GabrielPrice.ExecutiveDysfunction", executablePath: "/Applications/ExecutiveDysfunctionMac.app/Contents/MacOS/ExecutiveDysfunctionMac", at: activeDate))
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

    func testLockedRuleAcceptsAddedDomainAndCoverage() {
        let existing = makePolicy(mode: .blockList, domains: ["one.example"])
        var proposed = existing
        proposed.revision += 1
        proposed.rules[0].domains.insert("two.example")
        proposed.rules[0].windows[0].startMinutes -= 60
        XCTAssertTrue(DesktopPolicyRestrictionEvaluator.canReplace(existing: existing, with: proposed))
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
