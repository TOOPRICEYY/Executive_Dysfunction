import Foundation

/// The verdict vocabulary shared by the macOS data provider and its tests.
///
/// `inspect` is the only state that can hold a flow open, so it is issued
/// deliberately and never for traffic the policy could not act on anyway.
enum WebFilterFlowDecision: Equatable {
    case allow
    case drop
    case inspect(peekBytes: Int)
}

/// A decision plus why a drop was reached.
///
/// The kind is not used to decide anything; it feeds `WebFilterFailOpenGovernor`,
/// which must be able to tell a drop the user asked for from a drop this filter
/// guessed at. Without that distinction the safety valve would switch
/// enforcement off for anyone who reloads a blocked page enough times.
struct WebFilterFlowOutcome: Equatable {
    var decision: WebFilterFlowDecision
    var dropKind: WebFilterDropKind?
    /// Stable, fixed-cardinality branch identifier used by diagnostics.
    ///
    /// This deliberately carries no hostname, address, URL, application
    /// identifier or rule identifier. Future outage reports need to say which
    /// branch made a decision without turning the status file into browsing
    /// history.
    var reason: WebFilterDecisionReason

    static func allow(_ reason: WebFilterDecisionReason) -> WebFilterFlowOutcome {
        WebFilterFlowOutcome(decision: .allow, dropKind: nil, reason: reason)
    }
    static func inspect(_ peekBytes: Int, reason: WebFilterDecisionReason) -> WebFilterFlowOutcome {
        WebFilterFlowOutcome(decision: .inspect(peekBytes: peekBytes), dropKind: nil, reason: reason)
    }
    static func drop(_ kind: WebFilterDropKind, reason: WebFilterDecisionReason) -> WebFilterFlowOutcome {
        WebFilterFlowOutcome(decision: .drop, dropKind: kind, reason: reason)
    }
}

/// Why the decision tree reached a verdict.
///
/// Raw values are persisted in the redacted diagnostics snapshot, so keep them
/// stable. The set is intentionally finite: logging arbitrary values here
/// would create both a privacy leak and unbounded telemetry cardinality.
enum WebFilterDecisionReason: String, Codable, Equatable, CaseIterable {
    case policyInactive = "policy_inactive"
    case failOpenBypass = "fail_open_bypass"
    case enforcementStackExempt = "enforcement_stack_exempt"
    case localScopeExempt = "local_scope_exempt"
    case captivePortalProbeAllowed = "captive_portal_probe_allowed"
    case captivePortalAssistantAllowed = "captive_portal_assistant_allowed"
    case sourceApplicationBlocked = "source_application_blocked"
    case knownHostRecoveryExempt = "known_host_recovery_exempt"
    case knownHostAllowed = "known_host_allowed"
    case knownHostDeferredBlock = "known_host_deferred_block"
    case knownHostBlocked = "known_host_blocked"
    case encryptedDNSBlocked = "encrypted_dns_blocked"
    case unnamedQUICBlocked = "unnamed_quic_blocked"
    /// Retained so an older persisted diagnostics snapshot still decodes.
    case unnamedQUICAllowed = "unnamed_quic_allowed"
    case unnamedQUICFortressBlocked = "unnamed_quic_fortress_blocked"
    case unnamedInspectable = "unnamed_inspectable"
    case unnamedPreconnectAllowed = "unnamed_preconnect_allowed"
    case correlatedBlockedEndpoint = "correlated_blocked_endpoint"
    case unidentifiedAllowed = "unidentified_allowed"
    case unidentifiedFortressBlocked = "unidentified_fortress_blocked"
    case completionKnownHostBlocked = "completion_known_host_blocked"
    case completionUnclassifiedAllowed = "completion_unclassified_allowed"
    case completionUnclassifiedFortressBlocked = "completion_unclassified_fortress_blocked"
    case tlsServerNameRecoveryExempt = "tls_server_name_recovery_exempt"
    case tlsServerNameAllowed = "tls_server_name_allowed"
    case tlsServerNameBlocked = "tls_server_name_blocked"
    case tlsAddressLiteralBlocked = "tls_address_literal_blocked"
    case tlsEncryptedClientHelloBlocked = "tls_ech_blocked"
    /// Retained so an older persisted diagnostics snapshot still decodes.
    case tlsEncryptedClientHelloAllowed = "tls_ech_allowed"
    case tlsEncryptedClientHelloFortressBlocked = "tls_ech_fortress_blocked"
    case tlsMissingServerNameAllowed = "tls_missing_sni_allowed"
    case tlsMissingServerNameFortressBlocked = "tls_missing_sni_fortress_blocked"
    case tlsMalformedAllowed = "tls_malformed_allowed"
    case tlsMalformedFortressBlocked = "tls_malformed_fortress_blocked"
    case tlsIncomplete = "tls_incomplete"
    case httpIncomplete = "http_incomplete"
    case httpHostRecoveryExempt = "http_host_recovery_exempt"
    case httpHostAllowed = "http_host_allowed"
    case httpHostBlocked = "http_host_blocked"
    case httpMissingHostAllowed = "http_missing_host_allowed"
    case httpMissingHostFortressBlocked = "http_missing_host_fortress_blocked"
    case httpMalformedAllowed = "http_malformed_allowed"
    case httpMalformedFortressBlocked = "http_malformed_fortress_blocked"
    case payloadHostnameRecoveryExempt = "payload_hostname_recovery_exempt"
    case payloadHostnameAllowed = "payload_hostname_allowed"
    case payloadHostnameBlocked = "payload_hostname_blocked"
    case payloadUnidentifiedAllowed = "payload_unidentified_allowed"
    case payloadUnidentifiedFortressBlocked = "payload_unidentified_fortress_blocked"
    case streamMissingStateAllowed = "stream_missing_state_allowed"
    case streamInvalidSequenceAllowed = "stream_invalid_sequence_allowed"
}

/// Describes one new flow using only values the provider can obtain cheaply.
/// Keeping this a plain struct lets the whole decision tree be exercised by
/// unit tests without a live Network Extension.
struct WebFilterFlowDescriptor: Equatable {
    var hostname: String?
    /// The remote endpoint as macOS reports it. May be an IP literal.
    var remoteAddress: String?
    var remotePort: Int?
    var isTCP: Bool
    var sourceSigningIdentifier: String?
    var sourceExecutablePath: String
    /// Set only after validating the audit-token owner against Apple's signing
    /// requirement AND an exact protected-system captive-portal executable.
    /// A bundle identifier or a User-Agent is not sufficient evidence.
    var sourceIsVerifiedCaptivePortalComponent: Bool

    init(
        hostname: String? = nil,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        isTCP: Bool = true,
        sourceSigningIdentifier: String? = nil,
        sourceExecutablePath: String = "",
        sourceIsVerifiedCaptivePortalComponent: Bool = false
    ) {
        self.hostname = hostname
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.isTCP = isTCP
        self.sourceSigningIdentifier = sourceSigningIdentifier
        self.sourceExecutablePath = sourceExecutablePath
        self.sourceIsVerifiedCaptivePortalComponent = sourceIsVerifiedCaptivePortalComponent
    }
}

enum WebFilterFlowDecider {
    /// Ports whose only purpose is encrypted DNS. Nothing else uses them, so
    /// closing them while a web rule runs cannot cost ordinary browsing.
    static let dedicatedEncryptedDNSPorts: Set<Int> = [784, 853, 8853]

    /// UDP ports that carry QUIC/HTTP3 web traffic.
    static let quicWebPorts: Set<Int> = [80, 443]

    /// Network Extension waits for the requested initial count during ordinary
    /// request/response traffic. A 16,640-byte request consequently wedged every
    /// inspected browser flow on the live Mac. Start with one byte; the provider
    /// then streams a declared TLS record in bounded pieces while retaining the
    /// full prefix locally for late-SNI classification.
    static let initialTCPPeekBytes = WebFilterStreamingInspection.initialPeekBytes

    /// Infrastructure the enforcement stack itself depends on. Blocking these
    /// under a Fortress rule would stop the Mac from ever receiving the policy
    /// update that ends the block, which is an unrecoverable state for a
    /// self-restraint tool. They are exempt from fail-closed handling only,
    /// never from an explicit user rule.
    static let recoveryCriticalSuffixes: Set<String> = [
        "push.apple.com",
        "apple-cloudkit.com",
        "icloud-content.com",
        "gateway.icloud.com",
        "setup.icloud.com",
        "time.apple.com",
        "ocsp.apple.com",
        "ocsp2.apple.com",
        "crl.apple.com",
        "valid.apple.com",
        "certs.apple.com"
    ]

    static func decision(
        for flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date(),
        inspectsDNS: Bool = inspectsDNSQueries
    ) -> WebFilterFlowDecision {
        outcome(for: flow, policy: policy, at: date, inspectsDNS: inspectsDNS).decision
    }

    static func outcome(
        for flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date(),
        inspectsDNS: Bool = inspectsDNSQueries,
        matchesRecentlyBlockedEndpoint: Bool = false
    ) -> WebFilterFlowOutcome {
        // 1. Idle is free. With no active web rule the filter is a pass-through,
        //    so a scheduling bug or a stale policy can never cost connectivity.
        //
        //    Note that a block-list rule naming no domains is not an active web
        //    restriction: it has nothing to block, so it must not switch on any
        //    fail-closed handling. See `hasActiveWebRestrictions`.
        guard policy.hasActiveWebRestrictions(at: date) else { return .allow(.policyInactive) }

        // 2. The controlling app and its extension must always reach the network.
        if isEnforcementStack(flow.sourceSigningIdentifier) { return .allow(.enforcementStackExempt) }

        // 3. Local-scope destinations are not websites. Blocking them breaks
        //    printing, Continuity and local development for no enforcement gain.
        if let address = flow.remoteAddress, isLocalScope(address) { return .allow(.localScopeExempt) }

        if let reason = captivePortalAllowance(for: flow, policy: policy, at: date) {
            return .allow(reason)
        }

        let fortress = policy.hasActiveFortress(at: date)

        // macOS asks for the new-flow verdict before a BSD socket reports a
        // successful connect. Live testing proved that returning a data-filter
        // verdict here can deadlock: curl waits for connect before writing its
        // ClientHello, while Network Extension waits for that ClientHello
        // before completing connect. A recently *named* blocked flow gives us a
        // bounded alternative for Chrome retries that lose their hostname.
        if matchesRecentlyBlockedEndpoint,
           flow.hostname?.isEmpty != false,
           flow.remoteAddress?.isEmpty == false {
            // This is not an arbitrary fail-closed guess: the endpoint was
            // positively correlated with a domain named by the active policy.
            // Treat it as an intentional drop so repeated browser retries
            // cannot trip the outage circuit breaker and fail enforcement open.
            return .drop(.named, reason: .correlatedBlockedEndpoint)
        }

        // 4. Application rules are enforced at the socket only for block-list
        //    rules. A Fortress rule's application allow-list is not applied
        //    here: cutting a browser off entirely would make that same rule's
        //    website exceptions unreachable, which is never what was asked for.
        if blocksSourceApplication(flow, policy: policy, at: date) {
            return .drop(.named, reason: .sourceApplicationBlocked)
        }

        // 5. A name we already have is the cheapest and most reliable signal.
        if let hostname = flow.hostname, !hostname.isEmpty, !isAddressLiteral(hostname) {
            if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
                return .allow(.knownHostRecoveryExempt)
            }
            guard policy.blocksNetworkHostname(hostname, at: date) else {
                return .allow(.knownHostAllowed)
            }

            // The framework-provided name is already authoritative. Deferring
            // this intentional block to the data phase creates held state for
            // no classification benefit and was part of the machine-wide
            // outage path. Refuse it directly on every port.
            return .drop(.named, reason: .knownHostBlocked)
        }

        if let port = flow.remotePort, dedicatedEncryptedDNSPorts.contains(port) {
            return .drop(.unidentified, reason: .encryptedDNSBlocked)
        }

        // QUIC hides its handshake, so an unnamed UDP web flow has no later SNI
        // callback where a domain rule could be applied. Refuse it and let web
        // clients retry over inspectable TCP. This is an unidentified drop and
        // therefore feeds the provider's fail-open safety valve.
        if !flow.isTCP, let port = flow.remotePort, quicWebPorts.contains(port) {
            return .drop(.unidentified, reason: .unnamedQUICBlocked)
        }

        // 6. No name yet. Do not request outbound payload at new-flow time.
        //    Some socket clients cannot produce it until connect completes, so
        //    even a one-byte peek held every HTTPS connection on the live Mac.
        //    Fortress is intentionally default-deny; a block list must release
        //    traffic it cannot identify.
        if let port = flow.remotePort, isInspectablePort(port, isTCP: flow.isTCP, inspectsDNS: inspectsDNS) {
            return fortress
                ? .drop(.unidentified, reason: .unidentifiedFortressBlocked)
                : .allow(.unnamedPreconnectAllowed)
        }

        // 7. Anything else is unidentified. Fortress fails closed; a block-list
        //    rule has nothing to match on and must not turn into an outage.
        return fortress
            ? .drop(.unidentified, reason: .unidentifiedFortressBlocked)
            : .allow(.unidentifiedAllowed)
    }

    /// The verdict for a flow whose outbound data has ended without ever being
    /// classified.
    ///
    /// The provider previously re-ran the *new flow* decision here, which
    /// returns `.inspect` for any unnamed web flow, and mapped `.inspect` to
    /// `.drop()`. So a stream that ended without a readable ClientHello was
    /// killed. This was an earlier outage path, separate from the later live
    /// incident where a 16,640-byte initial peek held every inspected flow.
    ///
    /// Nothing is lost by releasing here. The flow never revealed a name, so
    /// dropping it was never enforcement — it was a guess, and the guess was
    /// wrong far more often than it was right. A flow that *did* reveal a
    /// blocked name was already dropped in the data phase and never reaches
    /// this path.
    static func decisionAtOutboundCompletion(
        for flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> WebFilterFlowOutcome {
        guard policy.hasActiveWebRestrictions(at: date) else { return .allow(.policyInactive) }
        if isEnforcementStack(flow.sourceSigningIdentifier) { return .allow(.enforcementStackExempt) }
        if let address = flow.remoteAddress, isLocalScope(address) { return .allow(.localScopeExempt) }

        if let reason = captivePortalAllowance(for: flow, policy: policy, at: date) {
            return .allow(reason)
        }

        if blocksSourceApplication(flow, policy: policy, at: date) {
            return .drop(.named, reason: .sourceApplicationBlocked)
        }

        // A name established at flow setup is authoritative, so a flow held back
        // for fast failure cannot escape simply by writing nothing.
        let fortress = policy.hasActiveFortress(at: date)
        if let known = flow.hostname, !known.isEmpty, !isAddressLiteral(known),
           policy.blocksNetworkHostname(known, at: date),
           !(fortress && isRecoveryCritical(known) && !policy.blocksDomainExplicitly(known, at: date)) {
            return .drop(.named, reason: .completionKnownHostBlocked)
        }

        // Unidentified. Fortress is default-deny and still refuses; a block-list
        // rule has no name to match and must release rather than take the
        // machine offline.
        return fortress
            ? .drop(.unidentified, reason: .completionUnclassifiedFortressBlocked)
            : .allow(.completionUnclassifiedAllowed)
    }

    /// Block-list application rules only. Returns false whenever the source is
    /// unknown, so an unresolvable audit token degrades to website enforcement
    /// rather than to a silent deny.
    static func blocksSourceApplication(
        _ flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date
    ) -> Bool {
        guard let identifier = flow.sourceSigningIdentifier?.lowercased(), !identifier.isEmpty else {
            return false
        }
        if isEnforcementStack(identifier) { return false }
        let path = flow.sourceExecutablePath.lowercased()
        if path.hasPrefix("/system/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") {
            return false
        }
        return policy.activeRules(at: date).contains { rule in
            rule.enforcementMode == .blockList
                && rule.matchesApplication(identifier)
        }
    }

    /// Applied to outbound bytes of a flow that returned `.inspect`.
    static func decision(
        forOutboundBytes bytes: Data,
        flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> WebFilterFlowDecision {
        outcome(forOutboundBytes: bytes, flow: flow, policy: policy, at: date).decision
    }

    static func outcome(
        forOutboundBytes bytes: Data,
        flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> WebFilterFlowOutcome {
        guard policy.hasActiveWebRestrictions(at: date) else { return .allow(.policyInactive) }
        if isEnforcementStack(flow.sourceSigningIdentifier) { return .allow(.enforcementStackExempt) }

        if let reason = captivePortalAllowance(for: flow, policy: policy, at: date) {
            return .allow(reason)
        }

        let fortress = policy.hasActiveFortress(at: date)
        if blocksSourceApplication(flow, policy: policy, at: date) {
            return .drop(.named, reason: .sourceApplicationBlocked)
        }

        // A name established at flow setup is authoritative and is re-applied
        // here, so a flow held back for fast failure cannot escape by sending
        // a payload this filter cannot parse.
        if let known = flow.hostname, !known.isEmpty, !isAddressLiteral(known),
           policy.blocksNetworkHostname(known, at: date),
           !(fortress && isRecoveryCritical(known) && !policy.blocksDomainExplicitly(known, at: date)) {
            return .drop(.named, reason: .knownHostBlocked)
        }

        if flow.isTCP, flow.remotePort == 443 || flow.remotePort == 8443 {
            switch NetworkHostnameInspector.tlsClientHello(in: bytes) {
            case let .serverName(hostname):
                guard !isAddressLiteral(hostname) else {
                    return .drop(.unidentified, reason: .tlsAddressLiteralBlocked)
                }
                if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
                    return .allow(.tlsServerNameRecoveryExempt)
                }
                return policy.blocksNetworkHostname(hostname, at: date)
                    ? .drop(.named, reason: .tlsServerNameBlocked)
                    : .allow(.tlsServerNameAllowed)
            case .encryptedClientHello:
                // A visible SNI wins inside the parser, including Chrome's ECH
                // GREASE. This branch means the complete hello exposed no name,
                // so allowing it would be a deterministic hostname bypass.
                return .drop(.unidentified, reason: .tlsEncryptedClientHelloBlocked)
            case .missingServerName:
                return fortress
                    ? .drop(.unidentified, reason: .tlsMissingServerNameFortressBlocked)
                    : .allow(.tlsMissingServerNameAllowed)
            case .malformed:
                return fortress
                    ? .drop(.unidentified, reason: .tlsMalformedFortressBlocked)
                    : .allow(.tlsMalformedAllowed)
            case let .incomplete(requiredBytes):
                return .inspect(requiredBytes, reason: .tlsIncomplete)
            case .notTLS:
                break
            }
        }

        if flow.isTCP,
           let port = flow.remotePort,
           port == 80 || port == 443 || port == 8080 || port == 8443 {
            switch NetworkHostnameInspector.httpRequest(in: bytes) {
            case let .incomplete(requiredBytes):
                // HTTP has no length field. Ask for a bounded window instead
                // of one byte at a time; the streamer still passes only bytes
                // already received and retains a bounded prefix.
                return .inspect(
                    min(
                        NetworkHostnameInspector.maximumHTTPHeaderBytes,
                        max(requiredBytes, bytes.count + WebFilterStreamingInspection.maximumPeekBytes)
                    ),
                    reason: .httpIncomplete
                )
            case let .host(hostname):
                if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
                    return .allow(.httpHostRecoveryExempt)
                }
                return policy.blocksNetworkHostname(hostname, at: date)
                    ? .drop(.named, reason: .httpHostBlocked)
                    : .allow(.httpHostAllowed)
            case .missingHost:
                return fortress
                    ? .drop(.unidentified, reason: .httpMissingHostFortressBlocked)
                    : .allow(.httpMissingHostAllowed)
            case .malformed:
                return fortress
                    ? .drop(.unidentified, reason: .httpMalformedFortressBlocked)
                    : .allow(.httpMalformedAllowed)
            case .notHTTP:
                break
            }
        }

        guard let hostname = NetworkHostnameInspector.hostname(in: bytes) else {
            return fortress
                ? .drop(.unidentified, reason: .payloadUnidentifiedFortressBlocked)
                : .allow(.payloadUnidentifiedAllowed)
        }
        if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
            return .allow(.payloadHostnameRecoveryExempt)
        }
        return policy.blocksNetworkHostname(hostname, at: date)
            ? .drop(.named, reason: .payloadHostnameBlocked)
            : .allow(.payloadHostnameAllowed)
    }

    /// Dropping DNS questions is deliberately off.
    ///
    /// It was measured on a live machine and withdrawn. Dropping the question
    /// for a blocked domain does block it, but the stub resolver then retries
    /// across every configured server before giving up, so the user waits
    /// about fifteen seconds and sees a generic timeout. Refusing the
    /// connection instead reaches the same outcome in roughly thirty
    /// milliseconds, and a blocked site that fails instantly reads as
    /// "blocked" rather than as "my internet is broken" -- which is the
    /// failure mode this whole design is trying to avoid.
    ///
    /// Nothing is lost in coverage: the connection to that domain is refused
    /// by name, and by TLS SNI when the client skips DNS and dials an IP
    /// directly. Both were verified against a live rule.
    static let inspectsDNSQueries = false

    static func isInspectablePort(_ port: Int, isTCP: Bool, inspectsDNS: Bool = inspectsDNSQueries) -> Bool {
        // DNS is datagram/framed traffic and cannot use the TCP partial-pass
        // streamer safely. The feature remains deliberately off; a future DNS
        // implementation needs a separate whole-message verdict path.
        if port == 53 { return false }
        guard isTCP else { return false }
        return port == 80 || port == 443 || port == 8080 || port == 8443
    }

    static func isEnforcementStack(_ signingIdentifier: String?) -> Bool {
        guard let identifier = signingIdentifier?.lowercased(), !identifier.isEmpty else { return false }
        let root = "com.gabrielprice.executivedysfunction"
        return identifier == root || identifier.hasPrefix(root + ".")
    }

    static func isRecoveryCritical(_ rawHostname: String) -> Bool {
        let host = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recoveryCriticalSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Loopback, link-local, RFC1918/ULA and RFC6598 shared address space. These
    /// never identify a website, so they stay reachable even when a rule fails
    /// closed.
    ///
    /// 100.64.0.0/10 is included deliberately. It is carrier-grade NAT space and
    /// is what VPN and mesh clients hand out for their internal endpoints — this
    /// machine's only DNS resolver lives at 100.64.0.2, behind a full-tunnel
    /// VPN. Nothing reachable there is a public website, and refusing it can cut
    /// off name resolution for the entire system, which presents as a total
    /// outage rather than as a blocked site.
    /// Login is infrastructure, not an all-browser pause. Only the exact Apple
    /// probe and the verified OS login components get this exception. Explicit
    /// user domain blocks still win, including a redirect to a blocked website.
    static func captivePortalAllowance(
        for flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date
    ) -> WebFilterDecisionReason? {
        guard MacCaptivePortalPolicy.isAuthenticationTransport(flow),
              !policy.blocksDomainExplicitly(flow.hostname ?? "", at: date) else { return nil }
        if flow.sourceIsVerifiedCaptivePortalComponent {
            return .captivePortalAssistantAllowed
        }
        if MacCaptivePortalPolicy.isProbeHostname(flow.hostname),
           !blocksSourceApplication(flow, policy: policy, at: date) {
            return .captivePortalProbeAllowed
        }
        return nil
    }

    static func isLocalScope(_ rawAddress: String) -> Bool {
        var address = rawAddress.lowercased()
        if let percent = address.firstIndex(of: "%") { address = String(address[address.startIndex..<percent]) }
        if address.hasPrefix("[") { address.removeFirst() }
        if address.hasSuffix("]") { address.removeLast() }
        if address.isEmpty { return false }

        if address.contains(":") {
            if address == "::1" || address == "::" { return true }
            if address.hasPrefix("fe8") || address.hasPrefix("fe9")
                || address.hasPrefix("fea") || address.hasPrefix("feb") { return true }
            if address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
            // IPv4-mapped IPv6 keeps the IPv4 scope rules.
            if let mapped = address.split(separator: ":").last, mapped.contains(".") {
                return isLocalScope(String(mapped))
            }
            return false
        }

        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (127, _), (10, _), (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func isAddressLiteral(_ value: String) -> Bool {
        var candidate = value
        if candidate.hasPrefix("[") { candidate.removeFirst() }
        if candidate.hasSuffix("]") { candidate.removeLast() }
        if candidate.contains(":") { return true }
        let octets = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }
}

/// No arbitrary process names, all-Apple exemption, portal-address allowlist,
/// User-Agent matching, or global timer can grant this recovery path.
enum MacCaptivePortalPolicy {
    static let probeHostname = "captive.apple.com"

    static func isProbeHostname(_ hostname: String?) -> Bool {
        guard var hostname = hostname?.lowercased() else { return false }
        while hostname.hasSuffix(".") { hostname.removeLast() }
        return hostname == probeHostname
    }

    static func isAuthenticationTransport(_ flow: WebFilterFlowDescriptor) -> Bool {
        flow.isTCP && (flow.remotePort == 80 || flow.remotePort == 443)
    }

    static func webPort(for url: URL?) -> Int? {
        guard let url else { return nil }
        switch url.scheme?.lowercased() {
        case "http": return url.port ?? 80
        case "https": return url.port ?? 443
        default: return nil
        }
    }

    static func isSystemComponent(signingIdentifier: String?, executablePath: String) -> Bool {
        switch (signingIdentifier, executablePath) {
        case ("com.apple.CaptiveNetworkAssistant",
              "/System/Library/CoreServices/Captive Network Assistant.app/Contents/MacOS/Captive Network Assistant"),
             ("com.apple.captiveagent", "/usr/libexec/captiveagent"):
            return true
        default:
            return false
        }
    }
}

/// Reassembles the non-overlapping chunks Network Extension supplies across
/// successive data callbacks. Callback offsets are stream offsets: requesting
/// more bytes does not cause the framework to re-present the earlier prefix,
/// even when zero bytes have been passed to the destination.
enum WebFilterOutboundByteAccumulator {
    static func append(_ readBytes: Data, at offset: Int, to prefix: inout Data) -> Bool {
        guard offset >= 0, offset <= prefix.count else { return false }

        if offset < prefix.count {
            let overlapCount = min(prefix.count - offset, readBytes.count)
            let existingOverlap = prefix[offset..<(offset + overlapCount)]
            guard existingOverlap.elementsEqual(readBytes.prefix(overlapCount)) else { return false }
            prefix.append(readBytes.dropFirst(overlapCount))
        } else {
            prefix.append(readBytes)
        }
        return prefix.count <= NetworkHostnameInspector.maximumClientHelloBytes
    }
}
