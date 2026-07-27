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

    init(
        hostname: String? = nil,
        remoteAddress: String? = nil,
        remotePort: Int? = nil,
        isTCP: Bool = true,
        sourceSigningIdentifier: String? = nil,
        sourceExecutablePath: String = ""
    ) {
        self.hostname = hostname
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.isTCP = isTCP
        self.sourceSigningIdentifier = sourceSigningIdentifier
        self.sourceExecutablePath = sourceExecutablePath
    }
}

enum WebFilterFlowDecider {
    /// Ports whose only purpose is encrypted DNS. Nothing else uses them, so
    /// closing them while a web rule runs cannot cost ordinary browsing.
    static let dedicatedEncryptedDNSPorts: Set<Int> = [784, 853, 8853]

    /// UDP ports that carry QUIC/HTTP3 web traffic.
    static let quicWebPorts: Set<Int> = [80, 443]

    /// Large enough for a complete TLS record, because a ClientHello does *not*
    /// put the server name near the front.
    ///
    /// Chrome shuffles its extension order per connection, and its
    /// post-quantum key share pushes the ClientHello past 1700 bytes. Measured
    /// on a live machine, the server name landed at offsets 1691, 1426, 1722,
    /// 1760, 1419, 429, 1748 and 1798 across eight connections to a single
    /// host: seven of eight sat beyond a 1024-byte window. A short peek blocked
    /// that site roughly one attempt in eight and released it otherwise, which
    /// presents as a site that fails and then re-routes itself.
    ///
    /// Asking for this much is safe. `peekOutboundBytes` is an upper bound, not
    /// a threshold: a 39-byte write was verified to arrive immediately under a
    /// 1024-byte peek, so requesting more than the client sends does not hold
    /// the flow. Re-peeking after a short first look was tried and did not
    /// deliver, so the whole record is requested up front.
    static let plaintextPeekBytes = 16_640

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
        // 1. Idle is free. With no active web rule the filter is a pass-through,
        //    so a scheduling bug or a stale policy can never cost connectivity.
        guard policy.hasActiveWebRestrictions(at: date) else { return .allow }

        // 2. The controlling app and its extension must always reach the network.
        if isEnforcementStack(flow.sourceSigningIdentifier) { return .allow }

        // 3. Local-scope destinations are not websites. Blocking them breaks
        //    printing, Continuity and local development for no enforcement gain.
        if let address = flow.remoteAddress, isLocalScope(address) { return .allow }

        let fortress = policy.hasActiveFortress(at: date)

        // 4. Application rules are enforced at the socket only for block-list
        //    rules. A Fortress rule's application allow-list is not applied
        //    here: cutting a browser off entirely would make that same rule's
        //    website exceptions unreachable, which is never what was asked for.
        if blocksSourceApplication(flow, policy: policy, at: date) { return .drop }

        // 5. A name we already have is the cheapest and most reliable signal.
        if let hostname = flow.hostname, !hostname.isEmpty, !isAddressLiteral(hostname) {
            if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
                return .allow
            }
            guard policy.blocksNetworkHostname(hostname, at: date) else { return .allow }

            // Dropping a TCP web flow before it connects makes the client wait
            // for its own connect timeout, and a browser that hangs for twelve
            // seconds reads as "the internet is down" rather than "this site is
            // blocked". Letting the handshake complete and refusing the first
            // write instead fails in milliseconds. The name is re-checked in
            // the data phase, so this costs no enforcement: nothing is ever
            // carried on the flow.
            if let port = flow.remotePort, flow.isTCP, isInspectablePort(port, isTCP: true) {
                return .inspect(peekBytes: plaintextPeekBytes)
            }
            return .drop
        }

        if let port = flow.remotePort, dedicatedEncryptedDNSPorts.contains(port) { return .drop }

        // QUIC hides its handshake, so an unnamed UDP web flow is the one path
        // that reaches a site with no inspectable name anywhere. Refusing it
        // costs nothing permanent: every browser races QUIC against TCP and
        // falls back, and the TCP attempt carries a readable ClientHello.
        // Named QUIC flows were already decided above and are untouched.
        if !flow.isTCP, let port = flow.remotePort, quicWebPorts.contains(port) { return .drop }

        // 6. No name yet. Peek only where a name is actually recoverable from
        //    the first write: DNS questions, HTTP requests and TLS ClientHellos.
        if let port = flow.remotePort, isInspectablePort(port, isTCP: flow.isTCP, inspectsDNS: inspectsDNS) {
            return .inspect(peekBytes: plaintextPeekBytes)
        }

        // 7. Anything else is unidentified. Fortress fails closed; a block-list
        //    rule has nothing to match on and must not turn into an outage.
        return fortress ? .drop : .allow
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
                && rule.macApplicationIdentifiers.contains(identifier)
        }
    }

    /// Applied to outbound bytes of a flow that returned `.inspect`.
    static func decision(
        forOutboundBytes bytes: Data,
        flow: WebFilterFlowDescriptor,
        policy: DesktopEnforcementPolicy,
        at date: Date = Date()
    ) -> WebFilterFlowDecision {
        guard policy.hasActiveWebRestrictions(at: date) else { return .allow }
        if isEnforcementStack(flow.sourceSigningIdentifier) { return .allow }

        let fortress = policy.hasActiveFortress(at: date)
        if blocksSourceApplication(flow, policy: policy, at: date) { return .drop }

        // A name established at flow setup is authoritative and is re-applied
        // here, so a flow held back for fast failure cannot escape by sending
        // a payload this filter cannot parse.
        if let known = flow.hostname, !known.isEmpty, !isAddressLiteral(known),
           policy.blocksNetworkHostname(known, at: date),
           !(fortress && isRecoveryCritical(known) && !policy.blocksDomainExplicitly(known, at: date)) {
            return .drop
        }

        if flow.isTCP, flow.remotePort == 443 || flow.remotePort == 8443 {
            switch NetworkHostnameInspector.tlsClientHello(in: bytes) {
            case let .serverName(hostname):
                guard !isAddressLiteral(hostname) else { return .drop }
                if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
                    return .allow
                }
                return policy.blocksNetworkHostname(hostname, at: date) ? .drop : .allow
            case .encryptedClientHello, .missingServerName, .malformed:
                // A TLS connection with no trustworthy visible identity cannot
                // safely pass a hostname block. Normal browser TLS uses SNI;
                // refusing only these concealed/invalid hellos preserves named
                // browsing while closing the retry bypass.
                return .drop
            case let .incomplete(requiredBytes):
                return .inspect(peekBytes: requiredBytes)
            case .notTLS:
                break
            }
        }

        guard let hostname = NetworkHostnameInspector.hostname(in: bytes) else {
            return fortress ? .drop : .allow
        }
        if fortress, isRecoveryCritical(hostname), !policy.blocksDomainExplicitly(hostname, at: date) {
            return .allow
        }
        return policy.blocksNetworkHostname(hostname, at: date) ? .drop : .allow
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
        if port == 53 { return inspectsDNS }
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

    /// Loopback, link-local, and RFC1918/ULA space. These never identify a
    /// website, so they stay reachable even when a rule fails closed.
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
