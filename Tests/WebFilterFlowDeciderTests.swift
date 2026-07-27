import XCTest
@testable import ExecutiveDysfunctionMac

/// These tests pin down the two failure modes that matter for a self-restraint
/// filter: it must not be trivially bypassable, and it must never become the
/// reason the machine has no network.
final class WebFilterFlowDeciderTests: XCTestCase {
    // MARK: - Never take the machine offline

    func testIdlePolicyAllowsEveryFlowWithoutInspection() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443)
        XCTAssertEqual(decide(flow, policy, at: inactiveDate), .allow)
    }

    func testUnidentifiedFlowOnNonWebPortIsAllowedUnderBlockList() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 22)
        XCTAssertEqual(decide(flow, policy), .allow)
    }

    /// QUIC to an unnamed destination is the one path that reaches a site with
    /// no inspectable name, so it is refused to force the inspectable TCP retry.
    func testUnnamedQUICIsRefusedToForceInspectableTCP() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443, isTCP: false)
        XCTAssertEqual(decide(flow, policy), .drop)
    }

    func testNamedQUICToAnAllowedSiteIsUntouched() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(hostname: "allowed.example", remotePort: 443, isTCP: false)
        XCTAssertEqual(decide(flow, policy), .allow)
    }

    func testQUICIsUntouchedWhenNoRuleIsActive() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 443, isTCP: false)
        XCTAssertEqual(decide(flow, policy, at: inactiveDate), .allow)
    }

    func testUnnamedUDPOnNonWebPortIsUntouched() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 3478, isTCP: false)
        XCTAssertEqual(decide(flow, policy), .allow)
    }

    /// Chrome sends the ECH extension on every connection as GREASE, beside a
    /// readable SNI. Measured on this machine: a 250-byte 0xFE0D extension in
    /// an ordinary hello carrying a plaintext name. Treating that as
    /// concealment blocks all Chrome browsing, so the visible name must win.
    func testGreaseECHAlongsideAReadableNameIsDecidedOnThatName() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(remotePort: 443)

        let allowed = clientHello(serverName: "www.allowed.example", extraExtensionType: 0xFE0D)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: allowed, flow: flow, policy: policy, at: activeDate
            ),
            .allow,
            "GREASE ECH must not block ordinary browsing"
        )

        let blocked = clientHello(serverName: "www.blocked.example", extraExtensionType: 0xFE0D)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: blocked, flow: flow, policy: policy, at: activeDate
            ),
            .drop,
            "A visible blocked name is still enforced when ECH is present"
        )
    }

    /// Concealment is a hello with no readable name at all.
    func testECHWithNoReadableNameIsRefused() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertEqual(
            NetworkHostnameInspector.tlsClientHello(in: clientHelloWithECHOnly()),
            .encryptedClientHello
        )
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: clientHelloWithECHOnly(),
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .drop
        )
    }

    func testOrdinaryClientHelloIsNotMistakenForECH() {
        XCTAssertFalse(
            NetworkHostnameInspector.usesEncryptedClientHello(in: clientHello(serverName: "allowed.example"))
        )
    }

    func testNonTLSFirstWriteReleasesTheFlowUnderBlockList() {
        let policy = makePolicy(domains: ["blocked.example"])
        let decision = WebFilterFlowDecider.decision(
            forOutboundBytes: Data([0x17, 0x03, 0x03, 0x00, 0x2a]),
            flow: WebFilterFlowDescriptor(remotePort: 443),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(decision, .allow, "An unparsed payload must resolve, never hang")
    }

    func testOffsetChunksAreAccumulatedBeforeTLSClassification() {
        let hello = clientHello(serverName: "www.blocked.example")
        var accumulated = Data()

        XCTAssertTrue(
            WebFilterOutboundByteAccumulator.append(Data(hello.prefix(20)), at: 0, to: &accumulated)
        )
        XCTAssertEqual(
            NetworkHostnameInspector.tlsClientHello(in: accumulated),
            .incomplete(requiredBytes: hello.count)
        )
        XCTAssertTrue(
            WebFilterOutboundByteAccumulator.append(Data(hello.dropFirst(20)), at: 20, to: &accumulated)
        )
        XCTAssertEqual(accumulated, hello)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: accumulated,
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: makePolicy(domains: ["blocked.example"]),
                at: activeDate
            ),
            .drop
        )
    }

    func testAccumulatorRejectsGapsAndConflictingOverlaps() {
        var gapPrefix = Data([0x16, 0x03])
        XCTAssertFalse(WebFilterOutboundByteAccumulator.append(Data([0x01]), at: 3, to: &gapPrefix))

        var conflictingPrefix = Data([0x16, 0x03, 0x01])
        XCTAssertFalse(
            WebFilterOutboundByteAccumulator.append(Data([0xFF, 0x00]), at: 1, to: &conflictingPrefix)
        )
    }

    func testFragmentedBlockedClientHelloIsInspectedUntilSNIIsAvailable() {
        let policy = makePolicy(domains: ["blocked.example"])
        let hello = clientHello(serverName: "www.blocked.example")
        let firstFragment = hello.prefix(20)

        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: firstFragment,
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .inspect(peekBytes: hello.count),
            "A partial ClientHello must not be permanently allowed"
        )
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: hello,
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .drop
        )
    }

    func testFragmentedAllowedClientHelloIsReleasedAfterClassification() {
        let policy = makePolicy(domains: ["blocked.example"])
        let hello = clientHello(serverName: "www.allowed.example")
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: hello.prefix(5),
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .inspect(peekBytes: hello.count)
        )
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: hello,
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .allow
        )
    }

    func testClientHelloSplitAcrossTLSRecordsStillMatchesBlockedSNI() {
        let policy = makePolicy(domains: ["blocked.example"])
        let hello = clientHello(serverName: "www.blocked.example")
        let splitHello = splitClientHelloAcrossRecords(hello, firstPayloadBytes: 12)

        XCTAssertEqual(
            NetworkHostnameInspector.tlsClientHello(in: splitHello.prefix(17)),
            .incomplete(requiredBytes: 22)
        )
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: splitHello,
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .drop
        )
    }

    func testTLSClientHelloWithoutSNIIsRefusedDuringDomainEnforcement() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: clientHelloWithoutExtensions(),
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .drop,
            "A valid but unnamed TLS retry must not bypass a hostname rule"
        )
    }

    func testAddressLiteralSNIIsNotAcceptedAsAClassifiedWebsite() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: clientHello(serverName: "93.184.216.34"),
                flow: WebFilterFlowDescriptor(remotePort: 443),
                policy: policy,
                at: activeDate
            ),
            .drop
        )
    }

    func testLocalScopeDestinationsStayReachableUnderFortress() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        for address in ["127.0.0.1", "::1", "192.168.1.10", "10.0.0.5", "172.20.3.4", "169.254.1.1", "fe80::1", "fd00::7"] {
            XCTAssertEqual(
                decide(WebFilterFlowDescriptor(remoteAddress: address, remotePort: 443), policy),
                .allow,
                "\(address) should remain reachable"
            )
        }
    }

    func testPublicAddressesAreNotTreatedAsLocalScope() {
        for address in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "1.1.1.1", "2606:4700::1111"] {
            XCTAssertFalse(WebFilterFlowDecider.isLocalScope(address), "\(address) is public")
        }
    }

    func testEnforcementStackIsNeverBlocked() {
        let policy = makePolicy(mode: .fortressAllowList, domains: [])
        let flow = WebFilterFlowDescriptor(
            hostname: "blocked.example",
            remoteAddress: "93.184.216.34",
            remotePort: 443,
            sourceSigningIdentifier: "com.GabrielPrice.ExecutiveDysfunction.WebFilter"
        )
        XCTAssertEqual(decide(flow, policy), .allow)
    }

    func testFortressKeepsPolicyDeliveryInfrastructureReachable() {
        let policy = makePolicy(mode: .fortressAllowList, domains: [])
        let flow = WebFilterFlowDescriptor(
            hostname: "p01-content.icloud-content.com",
            remoteAddress: "17.248.1.1",
            remotePort: 443
        )
        XCTAssertEqual(decide(flow, policy), .allow, "Fortress must not strand the Mac without policy updates")
    }

    func testExplicitRuleStillBeatsTheRecoveryExemption() {
        let policy = makePolicy(mode: .fortressAllowList, domains: [], blockedOverride: ["icloud-content.com"])
        let flow = WebFilterFlowDescriptor(hostname: "p01-content.icloud-content.com", remotePort: 443)
        // Held for fast failure, then refused on the strength of the name.
        XCTAssertEqual(decide(flow, policy), .inspect(peekBytes: WebFilterFlowDecider.plaintextPeekBytes))
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: Data(),
                flow: flow,
                policy: policy,
                at: activeDate
            ),
            .drop
        )
    }

    // MARK: - Actually enforce

    func testKnownHostnameOnNonWebPortIsDroppedImmediately() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(hostname: "cdn.blocked.example", remotePort: 4711)
        XCTAssertEqual(decide(flow, policy), .drop)
    }

    /// A blocked web flow is held for one write so it can be refused instantly
    /// instead of hanging until the client's own connect timeout.
    func testKnownBlockedWebHostFailsFastRatherThanHanging() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(hostname: "cdn.blocked.example", remotePort: 443)
        XCTAssertEqual(decide(flow, policy), .inspect(peekBytes: WebFilterFlowDecider.plaintextPeekBytes))

        // ...and the name still decides it, even if the payload is opaque.
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: Data([0x17, 0x03, 0x03, 0x00, 0x2a]),
                flow: flow,
                policy: policy,
                at: activeDate
            ),
            .drop,
            "A held blocked flow must never escape through an unparsable payload"
        )
    }

    func testAllowedHostWithOpaquePayloadIsStillReleased() {
        let policy = makePolicy(domains: ["blocked.example"])
        let flow = WebFilterFlowDescriptor(hostname: "allowed.example", remotePort: 443)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: Data([0x17, 0x03, 0x03, 0x00, 0x2a]),
                flow: flow,
                policy: policy,
                at: activeDate
            ),
            .allow
        )
    }

    func testDNSInspectionCanBeStagedOff() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                for: WebFilterFlowDescriptor(remoteAddress: "75.75.75.75", remotePort: 53, isTCP: false),
                policy: policy,
                at: activeDate,
                inspectsDNS: false
            ),
            .allow
        )
    }

    func testDNSInspectionEngagesWhenStagedOn() {
        let policy = makePolicy(domains: ["blocked.example"])
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                for: WebFilterFlowDescriptor(remoteAddress: "75.75.75.75", remotePort: 53, isTCP: false),
                policy: policy,
                at: activeDate,
                inspectsDNS: true
            ),
            .inspect(peekBytes: WebFilterFlowDecider.plaintextPeekBytes)
        )
    }

    func testUnnamedWebFlowIsInspectedRatherThanWavedThrough() {
        let policy = makePolicy(domains: ["blocked.example"])
        for port in [80, 443] {
            XCTAssertEqual(
                decide(WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: port), policy),
                .inspect(peekBytes: WebFilterFlowDecider.plaintextPeekBytes),
                "port \(port) carries a recoverable hostname"
            )
        }
    }

    func testTLSClientHelloSNIIsBlockedOnInspection() {
        let policy = makePolicy(domains: ["blocked.example"])
        let decision = WebFilterFlowDecider.decision(
            forOutboundBytes: clientHello(serverName: "www.blocked.example"),
            flow: WebFilterFlowDescriptor(remotePort: 443),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(decision, .drop)
    }

    func testTLSClientHelloForAllowedHostIsReleased() {
        let policy = makePolicy(domains: ["blocked.example"])
        let decision = WebFilterFlowDecider.decision(
            forOutboundBytes: clientHello(serverName: "www.allowed.example"),
            flow: WebFilterFlowDescriptor(remotePort: 443),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(decision, .allow)
    }

    func testDNSQuestionForBlockedDomainIsDropped() {
        let policy = makePolicy(domains: ["blocked.example"])
        let decision = WebFilterFlowDecider.decision(
            forOutboundBytes: dnsQuery(name: "www.blocked.example"),
            flow: WebFilterFlowDescriptor(remotePort: 53, isTCP: false),
            policy: policy,
            at: activeDate
        )
        XCTAssertEqual(decision, .drop)
    }

    func testDedicatedEncryptedDNSPortsAreClosedDuringAWebRule() {
        let policy = makePolicy(domains: ["blocked.example"])
        for port in [784, 853, 8853] {
            XCTAssertEqual(decide(WebFilterFlowDescriptor(remotePort: port), policy), .drop)
        }
    }

    func testAddressLiteralIsNotMistakenForAHostname() {
        // A Fortress allow-list must not accept a bare IP as an unmatched name.
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        let flow = WebFilterFlowDescriptor(hostname: "93.184.216.34", remoteAddress: "93.184.216.34", remotePort: 4711)
        XCTAssertEqual(decide(flow, policy), .drop)
        XCTAssertTrue(WebFilterFlowDecider.isAddressLiteral("93.184.216.34"))
        XCTAssertFalse(WebFilterFlowDecider.isAddressLiteral("blocked.example"))
    }

    func testFortressFailsClosedOnUnidentifiedTraffic() {
        let policy = makePolicy(mode: .fortressAllowList, domains: ["allowed.example"])
        let flow = WebFilterFlowDescriptor(remoteAddress: "93.184.216.34", remotePort: 4711)
        XCTAssertEqual(decide(flow, policy), .drop)
    }

    func testBlockListApplicationRuleDropsThatApplicationsFlows() {
        var policy = makePolicy(domains: ["blocked.example"])
        policy.rules[0].macApplicationIdentifiers = ["com.example.timesink"]
        let flow = WebFilterFlowDescriptor(
            hostname: "allowed.example",
            remotePort: 443,
            sourceSigningIdentifier: "com.example.TimeSink",
            sourceExecutablePath: "/Applications/TimeSink.app/Contents/MacOS/TimeSink"
        )
        XCTAssertEqual(decide(flow, policy), .drop)
    }

    func testSystemExecutablesAreExemptFromApplicationRules() {
        var policy = makePolicy(domains: ["blocked.example"])
        policy.rules[0].macApplicationIdentifiers = ["com.apple.nsurlsessiond"]
        let flow = WebFilterFlowDescriptor(
            hostname: "allowed.example",
            remotePort: 443,
            sourceSigningIdentifier: "com.apple.nsurlsessiond",
            sourceExecutablePath: "/usr/libexec/nsurlsessiond"
        )
        XCTAssertEqual(decide(flow, policy), .allow)
    }

    /// Chrome shuffles its TLS extension order per connection and its
    /// post-quantum ClientHello runs past 1700 bytes, so the server name lands
    /// beyond a fixed 1024-byte peek on most attempts. Measured on a live
    /// machine: SNI offsets of 1691, 1426, 1722, 1760, 1419, 429, 1748, 1798
    /// across eight connections to one host -- seven of eight past the window.
    /// A peek-once parser therefore blocks the site roughly one try in eight
    /// and releases it the rest of the time, which presents as a site that
    /// fails and then "re-routes" itself.
    /// The peek window must cover a real browser ClientHello. Chrome's
    /// post-quantum hello was measured at 1735-1831 bytes on this machine.
    func testPeekWindowCoversARealBrowserClientHello() {
        XCTAssertGreaterThanOrEqual(
            WebFilterFlowDecider.plaintextPeekBytes,
            2_048,
            "A peek shorter than a browser ClientHello lets late SNI through"
        )
    }

    func testChromeSizedClientHelloWithLateSNIIsNotReleased() {
        let policy = makePolicy(domains: ["blocked.example"])
        let hello = clientHello(serverName: "www.blocked.example", paddingBeforeServerName: 1_600)
        let flow = WebFilterFlowDescriptor(remoteAddress: "104.18.35.15", remotePort: 443)

        // The whole record resolves to the concealed name and is refused.
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: hello, flow: flow, policy: policy, at: activeDate
            ),
            .drop
        )

        // A prefix that stops short of the declared record must never resolve
        // to "allow"; that is the exact leak that let Chrome through.
        for prefix in [512, 1_024, 1_400] where prefix < hello.count {
            let decision = WebFilterFlowDecider.decision(
                forOutboundBytes: Data(hello.prefix(prefix)),
                flow: flow,
                policy: policy,
                at: activeDate
            )
            XCTAssertNotEqual(decision, .allow, "A truncated ClientHello (\(prefix)B) must not be released")
        }
    }

    /// The same shape for an allowed host must still be released, so the fix
    /// does not turn every large ClientHello into a block.
    func testChromeSizedClientHelloForAllowedHostIsReleased() {
        let policy = makePolicy(domains: ["blocked.example"])
        let hello = clientHello(serverName: "www.allowed.example", paddingBeforeServerName: 1_600)
        let flow = WebFilterFlowDescriptor(remoteAddress: "104.18.35.15", remotePort: 443)
        XCTAssertEqual(
            WebFilterFlowDecider.decision(
                forOutboundBytes: hello, flow: flow, policy: policy, at: activeDate
            ),
            .allow
        )
    }

    // MARK: - Helpers

    private func decide(
        _ flow: WebFilterFlowDescriptor,
        _ policy: DesktopEnforcementPolicy,
        at date: Date? = nil
    ) -> WebFilterFlowDecision {
        WebFilterFlowDecider.decision(for: flow, policy: policy, at: date ?? activeDate)
    }

    private var activeDate: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 12).date!
    }

    private var inactiveDate: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 3).date!
    }

    private func makePolicy(
        mode: DesktopEnforcementRule.Mode = .blockList,
        domains: Set<String>,
        blockedOverride: Set<String> = []
    ) -> DesktopEnforcementPolicy {
        var rules = [
            DesktopEnforcementRule(
                id: UUID(),
                name: "Test",
                isEnabled: true,
                enforcementMode: mode,
                windows: [DesktopTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)],
                domains: domains,
                macApplicationIdentifiers: [],
                windowsExecutablePaths: [],
                windowsPublisherRules: [],
                lockdown: lockdown
            )
        ]
        if !blockedOverride.isEmpty {
            rules.append(
                DesktopEnforcementRule(
                    id: UUID(),
                    name: "Explicit block",
                    isEnabled: true,
                    enforcementMode: .blockList,
                    windows: [DesktopTimeWindow(weekdays: [2], startMinutes: 9 * 60, endMinutes: 17 * 60)],
                    domains: blockedOverride,
                    macApplicationIdentifiers: [],
                    windowsExecutablePaths: [],
                    windowsPublisherRules: [],
                    lockdown: lockdown
                )
            )
        }
        return DesktopEnforcementPolicy(revision: 1, issuedAt: Date(), rules: rules)
    }

    private var lockdown: DesktopLockdownPolicy {
        DesktopLockdownPolicy(
            severity: "passageOnly",
            unlockDelayDays: 0,
            passageWordCount: 10,
            confirmationWindowHours: 1,
            editWindowHours: 1,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 0
        )
    }

    private func clientHello(
        serverName: String,
        extraExtensionType: Int? = nil,
        paddingBeforeServerName: Int = 0
    ) -> Data {
        let name = Array(serverName.utf8)
        var serverNameExtension: [UInt8] = []
        if paddingBeforeServerName > 0 {
            // Extension type 21 (padding), sized to push SNI late in the block.
            serverNameExtension += be16(21) + be16(paddingBeforeServerName)
            serverNameExtension += Array(repeating: 0x00, count: paddingBeforeServerName)
        }
        serverNameExtension += [0x00, 0x00]
        let entry: [UInt8] = [0x00] + be16(name.count) + name
        let list: [UInt8] = be16(entry.count) + entry
        serverNameExtension += be16(list.count) + list
        if let extraExtensionType {
            let payload: [UInt8] = [0x00, 0x01, 0x02, 0x03]
            serverNameExtension += be16(extraExtensionType) + be16(payload.count) + payload
        }

        var body: [UInt8] = [0x03, 0x03]
        body += Array(repeating: 0x41, count: 32) // random
        body += [0x00]                            // empty session id
        body += be16(2) + [0x13, 0x01]            // one cipher suite
        body += [0x01, 0x00]                      // one compression method
        body += be16(serverNameExtension.count) + serverNameExtension

        var handshake: [UInt8] = [0x01]
        handshake += [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)]
        handshake += body

        var record: [UInt8] = [0x16, 0x03, 0x01]
        record += be16(handshake.count) + handshake
        return Data(record)
    }

    private func clientHelloWithECHOnly() -> Data {
        var exts: [UInt8] = be16(0xFE0D) + be16(4) + [0x00, 0x01, 0x02, 0x03]
        var body: [UInt8] = [0x03, 0x03]
        body += Array(repeating: 0x41, count: 32)
        body += [0x00]
        body += be16(2) + [0x13, 0x01]
        body += [0x01, 0x00]
        body += be16(exts.count) + exts
        var handshake: [UInt8] = [0x01]
        handshake += [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)]
        handshake += body
        var record: [UInt8] = [0x16, 0x03, 0x01]
        record += be16(handshake.count) + handshake
        exts = []
        return Data(record)
    }

    private func clientHelloWithoutExtensions() -> Data {
        var body: [UInt8] = [0x03, 0x03]
        body += Array(repeating: 0x41, count: 32)
        body += [0x00]
        body += be16(2) + [0x13, 0x01]
        body += [0x01, 0x00]
        var handshake: [UInt8] = [0x01]
        handshake += [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)]
        handshake += body
        return Data([0x16, 0x03, 0x01] + be16(handshake.count) + handshake)
    }

    private func splitClientHelloAcrossRecords(_ hello: Data, firstPayloadBytes: Int) -> Data {
        let bytes = [UInt8](hello)
        let payload = Array(bytes.dropFirst(5))
        let first = Array(payload.prefix(firstPayloadBytes))
        let second = Array(payload.dropFirst(firstPayloadBytes))
        return Data(
            [0x16, 0x03, 0x01] + be16(first.count) + first
                + [0x16, 0x03, 0x01] + be16(second.count) + second
        )
    }

    private func dnsQuery(name: String) -> Data {
        var bytes: [UInt8] = [0x12, 0x34, 0x01, 0x00] + be16(1) + be16(0) + be16(0) + be16(0)
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes += [0x00] + be16(1) + be16(1)
        return Data(bytes)
    }

    private func be16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
