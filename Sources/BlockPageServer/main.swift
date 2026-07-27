import Foundation
import Network
import Security

/// Serves the page a blocked site shows instead of a connection error.
///
/// A content filter can only allow or drop a flow — it cannot inject bytes, and
/// the built-in remediation page (`remediateVerdictWithRemediationURLMapKey:`)
/// is iOS-only. So the page has to come from somewhere the browser will connect
/// to and trust: blocked domains are pointed at loopback, and this server
/// answers as them using leaf certificates minted by a locally trusted CA.
///
/// Deliberately *not* a transparent proxy. Redirecting only blocked names keeps
/// every other connection away from this code entirely; a bug here can cost the
/// block page, not the machine's network.
///
/// The filter still drops real connections to these domains. If the redirect is
/// ever bypassed — a browser resolving over DoH ignores /etc/hosts — the site
/// stays blocked, just without the explanation.

/// Overridable so the certificate and TLS path can be exercised on a high port
/// against a throwaway CA, without touching the system trust store, `/etc/hosts`
/// or port 443.
private func setting(_ name: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
}

private let supportDirectory = setting(
    "BLOCKPAGE_DIR",
    "/Library/Application Support/ExecutiveDysfunction/blockpage"
)
private let identityPath = supportDirectory + "/identity.p12"
private let passwordPath = supportDirectory + "/identity.pass"
private let statusPath = setting(
    "BLOCKPAGE_STATUS",
    "/Library/Application Support/ExecutiveDysfunction/filter-status.json"
)
private let httpsPort = UInt16(setting("BLOCKPAGE_HTTPS_PORT", "443")) ?? 443
private let httpPort = UInt16(setting("BLOCKPAGE_HTTP_PORT", "80")) ?? 80

// MARK: - Status

private struct Status: Decodable {
    var revision: UInt64
    var activeRuleCount: Int
    var activeDomainCount: Int
    var blockedDomains: [String]?
    var lockdownEndsAt: Date?
}

private func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(Status.self, from: data)
}

private func remainingDescription(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(max(1, minutes))m"
}

// MARK: - Page

private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func page(host: String) -> String {
    let status = readStatus()
    let safeHost = escape(host.isEmpty ? "This site" : host)

    var detail = ""
    if let endsAt = status?.lockdownEndsAt, endsAt > Date() {
        detail = """
        <p class="lock">Lockdown session — \(remainingDescription(endsAt.timeIntervalSinceNow)) remaining</p>
        """
    } else if let status {
        detail = """
        <p class="lock">\(status.activeRuleCount) rule(s) active · \(status.activeDomainCount) domain(s)</p>
        """
    }

    return """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Blocked — \(safeHost)</title><style>
    :root{color-scheme:light dark}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
      background:#f5f5f7;color:#1d1d1f;padding:24px}
    .card{max-width:30rem;width:100%;background:#fff;border-radius:18px;padding:36px 32px;
      box-shadow:0 1px 3px rgba(0,0,0,.08),0 12px 32px rgba(0,0,0,.06);text-align:center}
    .mark{font-size:44px;line-height:1;margin-bottom:14px}
    h1{font-size:1.3rem;margin:0 0 6px;letter-spacing:-.01em}
    .host{font:600 1.05rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
      background:#f0f0f3;border-radius:8px;padding:8px 12px;margin:16px 0;word-break:break-all}
    p{margin:8px 0;color:#5c5c61;font-size:.92rem}
    .lock{color:#8a5a00;font-weight:500}
    .foot{margin-top:22px;padding-top:16px;border-top:1px solid #e8e8ed;font-size:.8rem;color:#86868b}
    @media (prefers-color-scheme:dark){
      body{background:#000;color:#f5f5f7}
      .card{background:#1c1c1e;box-shadow:none}
      .host{background:#2c2c2e}
      p{color:#98989d}.lock{color:#ffb340}
      .foot{border-top-color:#38383a;color:#8e8e93}}
    </style></head><body><div class="card">
    <div class="mark">🔒</div>
    <h1>Blocked</h1>
    <p>by Executive Dysfunction</p>
    <div class="host">\(safeHost)</div>
    \(detail)
    <p class="foot">You asked for this site to be unavailable right now.</p>
    </div></body></html>
    """
}

private func httpResponse(host: String) -> Data {
    let body = Data(page(host: host).utf8)
    let header = """
    HTTP/1.1 403 Forbidden\r
    Content-Type: text/html; charset=utf-8\r
    Content-Length: \(body.count)\r
    Cache-Control: no-store, must-revalidate\r
    Connection: close\r
    \r\n
    """
    return Data(header.utf8) + body
}

/// Pulls the Host header out so the page can name the site the user asked for.
private func host(fromRequest data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8) else { return "" }
    for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
        if line.lowercased().hasPrefix("host:") {
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ":").first ?? ""
        }
    }
    return ""
}

// MARK: - TLS identity

private func loadIdentity() -> SecIdentity? {
    guard let data = FileManager.default.contents(atPath: identityPath) else {
        FileHandle.standardError.write(Data("blockpage: no identity at \(identityPath)\n".utf8))
        return nil
    }
    let password = (try? String(contentsOfFile: passwordPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var items: CFArray?
    let status = SecPKCS12Import(
        data as CFData,
        [kSecImportExportPassphrase as String: password] as CFDictionary,
        &items
    )
    guard status == errSecSuccess,
          let entries = items as? [[String: Any]],
          let identity = entries.first?[kSecImportItemIdentity as String] else {
        FileHandle.standardError.write(Data("blockpage: PKCS12 import failed (\(status))\n".utf8))
        return nil
    }
    return (identity as! SecIdentity)
}

// MARK: - Listeners

private func serve(connection: NWConnection) {
    connection.stateUpdateHandler = { state in
        if case .failed = state { connection.cancel() }
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
        let requestedHost = data.map(host(fromRequest:)) ?? ""
        connection.send(
            content: httpResponse(host: requestedHost),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
    connection.start(queue: .global(qos: .utility))
}

private func startListener(port: NWEndpoint.Port, identity: SecIdentity?) {
    let parameters: NWParameters
    if let identity, let secIdentity = sec_identity_create(identity) {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        // Browsers reaching a block page are ordinary modern clients.
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        parameters = NWParameters(tls: options)
    } else {
        parameters = NWParameters.tcp
    }
    parameters.allowLocalEndpointReuse = true
    // Only loopback: nothing here should ever be reachable from the network.
    // This carries the port too — passing `on:` as well makes NWListener reject
    // the parameters outright.
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

    guard let listener = try? NWListener(using: parameters) else {
        FileHandle.standardError.write(Data("blockpage: cannot listen on \(port)\n".utf8))
        return
    }
    listener.newConnectionHandler = serve(connection:)
    listener.stateUpdateHandler = { state in
        if case let .failed(error) = state {
            FileHandle.standardError.write(Data("blockpage: listener \(port) failed: \(error)\n".utf8))
        }
    }
    listener.start(queue: .global(qos: .utility))
}

let identity = loadIdentity()
if let port = NWEndpoint.Port(rawValue: httpsPort) { startListener(port: port, identity: identity) }
if let port = NWEndpoint.Port(rawValue: httpPort) { startListener(port: port, identity: nil) }
FileHandle.standardError.write(
    Data("blockpage: serving on 127.0.0.1:\(httpPort) and :\(httpsPort)\n".utf8)
)
dispatchMain()
