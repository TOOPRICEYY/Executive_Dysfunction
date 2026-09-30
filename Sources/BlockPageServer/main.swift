import Foundation
import Darwin
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
private let configuredDomainsPath = supportDirectory + "/configured-domains.txt"
private let hostsPath = setting("BLOCKPAGE_HOSTS", "/etc/hosts")
private let pausesPath = setting(
    "BLOCKPAGE_PAUSES",
    "/Library/Application Support/ExecutiveDysfunction/blockpage/temporary-pauses.json"
)
private let httpsPort = UInt16(setting("BLOCKPAGE_HTTPS_PORT", "443")) ?? 443
private let httpPort = UInt16(setting("BLOCKPAGE_HTTP_PORT", "80")) ?? 80
private let challengeStore = BlockPagePauseChallengeStore()
private let pauseStore = BlockPageTemporaryPauseStore(
    fileURL: URL(fileURLWithPath: pausesPath),
    requiresRootOwnership: pausesPath == BlockPageTemporaryPauseStore.defaultURL.path
)

// MARK: - Status

private struct Status: Decodable {
    var revision: UInt64
    var activeRuleCount: Int
    var activeDomainCount: Int
    var blockedDomains: [String]?
    var lockdownEndsAt: Date?
    var hasActiveWebRestrictions: Bool?
    var updatedAt: Date?
    var blockPageRules: [BlockPageRuleDescriptor]?
}

private func readStatus() -> Status? {
    guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(Status.self, from: data)
}

private func readConfiguredDomains() -> [String] {
    guard let contents = try? String(contentsOfFile: configuredDomainsPath, encoding: .utf8) else {
        return []
    }
    return contents.components(separatedBy: .newlines)
}

private func activeHostMappings(now: Date = Date()) -> [String] {
    let state = readStatus().flatMap { status -> BlockPageFilterState? in
        guard let active = status.hasActiveWebRestrictions,
              let updatedAt = status.updatedAt else { return nil }
        return BlockPageFilterState(
            hasActiveWebRestrictions: active,
            updatedAt: updatedAt,
            blockedDomains: status.blockedDomains ?? []
        )
    }
    return BlockPageHostPolicy.mappedDomains(
        state: state,
        configuredDomains: readConfiguredDomains(),
        now: now
    )
}

private func synchronizeHosts(forceEmpty: Bool = false) {
    guard let existing = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
        FileHandle.standardError.write(Data("blockpage: cannot read \(hostsPath)\n".utf8))
        return
    }
    let domains = forceEmpty ? [] : activeHostMappings()
    guard let updated = BlockPageHostPolicy.replacingManagedBlock(
        in: existing,
        domains: domains
    ) else {
        FileHandle.standardError.write(Data("blockpage: malformed managed hosts markers; refusing to edit\n".utf8))
        return
    }
    guard updated != existing else { return }
    do {
        try Data(updated.utf8).write(to: URL(fileURLWithPath: hostsPath), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: hostsPath
        )
        FileHandle.standardError.write(
            Data("blockpage: synchronized \(domains.count) active host mapping(s)\n".utf8)
        )
    } catch {
        FileHandle.standardError.write(
            Data("blockpage: hosts synchronization failed: \(error.localizedDescription)\n".utf8)
        )
    }
}

// MARK: - Page

private func freshStatus(now: Date = Date()) -> Status? {
    guard let status = readStatus(),
          status.hasActiveWebRestrictions == true,
          let updatedAt = status.updatedAt,
          now.timeIntervalSince(updatedAt) >= 0,
          now.timeIntervalSince(updatedAt) <= BlockPageHostPolicy.statusFreshness else {
        return nil
    }
    return status
}

private func page(host: String, now: Date = Date()) -> String {
    let status = freshStatus(now: now)
    let renderStatus = status.map {
        BlockPageRenderStatus(
            activeRuleCount: $0.activeRuleCount,
            activeDomainCount: $0.activeDomainCount,
            lockdownEndsAt: $0.lockdownEndsAt
        )
    }
    let options = BlockPageRuleMatcher.eligibleRules(
        host: host,
        among: status?.blockPageRules ?? []
    ).compactMap { rule -> BlockPageTemporaryPauseOption? in
        guard case let .success(challenge) = challengeStore.issue(
            host: host,
            rule: rule,
            policyRevision: status?.revision ?? 0,
            at: now
        ) else { return nil }
        return BlockPageTemporaryPauseOption(rule: rule, challenge: challenge)
    }
    return BlockPageRenderer.html(
        host: host,
        status: renderStatus,
        temporaryPauseOptions: options,
        appRequiredRules: BlockPageRuleMatcher.rulesBlocking(host: host, among: status?.blockPageRules ?? [])
            .filter { $0.requiresAppForTemporaryAccess == true }.map(\.name),
        now: now
    )
}

private func requestError(
    status: Int,
    reason: String,
    message: String
) -> Data {
    BlockPageHTTPResponse.data(
        status: status,
        reason: reason,
        body: BlockPageRenderer.requestErrorHTML(message: message)
    )
}

private func response(to request: BlockPageHTTPRequest, now: Date = Date()) -> Data {
    guard let host = request.host else {
        return requestError(status: 400, reason: "Bad Request", message: "The requested host was invalid.")
    }
    if request.method == "GET" || request.method == "HEAD" {
        return BlockPageHTTPResponse.data(
            status: 403,
            reason: "Forbidden",
            body: request.method == "HEAD" ? "" : page(host: host, now: now)
        )
    }
    guard request.method == "POST", request.target == "/temporary-pause" else {
        return requestError(status: 404, reason: "Not Found", message: "That block-page action does not exist.")
    }
    guard request.hasSameOrigin(request.headers["origin"]) else {
        // Never log submitted passages or challenge tokens.
        let originKind = request.headers["origin"].map { $0 == "null" ? "opaque" : "present" } ?? "missing"
        FileHandle.standardError.write(Data("blockpage: pause_origin_rejected origin_kind=\(originKind)\n".utf8))
        return requestError(status: 403, reason: "Forbidden", message: "The browser did not provide valid block-page origin information. Reload the original blocked page to get a fresh form and try again. If this repeats, update the Holdfast block-page helper.")
    }
    guard let form = request.formValues,
          form.count == 5,
          let rawIntent = form["intent"],
          let intent = BypassEvent.Intent(rawValue: rawIntent),
          let token = form["challenge"],
          let rawRuleID = form["ruleID"],
          let ruleID = UUID(uuidString: rawRuleID),
          let typedPassage = form["passage"],
          let rawDuration = form["durationSeconds"],
          let durationSeconds = Int(rawDuration) else {
        return requestError(status: 400, reason: "Bad Request", message: "The temporary exception request was incomplete.")
    }
    guard let status = freshStatus(now: now) else {
        return requestError(status: 409, reason: "Conflict", message: "The filter is not reporting a fresh active policy. No exception was made.")
    }
    let eligible = BlockPageRuleMatcher.eligibleRules(
        host: host,
        among: status.blockPageRules ?? []
    )
    let currentRule = eligible.first { $0.id == ruleID }
    switch challengeStore.redeem(
        token: token,
        host: host,
        ruleID: ruleID,
        durationSeconds: durationSeconds,
        typedPassage: typedPassage,
        currentRule: currentRule,
        currentPolicyRevision: status.revision,
        at: now
    ) {
    case let .success(pause):
        do {
            try pauseStore.grant(pause, at: now, ruleName: currentRule?.name ?? "Blocking Group", intent: intent)
            let ruleName = currentRule?.name ?? "Selected rule"
            FileHandle.standardError.write(Data(
                "blockpage: temporary pause granted request=\(pause.requestID.uuidString.lowercased()) rule=\(pause.ruleID.uuidString.lowercased()) duration_seconds=\(pause.durationSeconds)\n".utf8
            ))
            return BlockPageHTTPResponse.data(
                status: 200,
                reason: "OK",
                body: BlockPageRenderer.pauseGrantedHTML(
                    host: host,
                    ruleName: ruleName,
                    durationSeconds: durationSeconds
                )
            )
        } catch {
            FileHandle.standardError.write(Data(
                "blockpage: temporary pause persistence failed error=\(String(describing: error))\n".utf8
            ))
            return requestError(status: 503, reason: "Service Unavailable", message: "The exception could not be saved safely. The rule remains active.")
        }
    case let .failure(error):
        let statusCode = error == .rateLimited ? 429 : 403
        let reason = error == .rateLimited ? "Too Many Requests" : "Forbidden"
        let message: String = switch error {
        case .passageMismatch: "The typed passage did not match. No exception was made."
        case .unsupportedDuration: "Only 10, 30, or 60 minutes can be selected."
        case .expired: "That confirmation passage expired. Reload the block page for a new one."
        case .rateLimited: "Too many incorrect attempts were received. Wait a minute, then reload the page."
        case .policyChanged: "The rule changed after this page loaded. Reload it before trying again."
        case .invalidHost, .invalidRule, .unavailable: "That confirmation request is no longer valid. Reload the block page."
        }
        return requestError(status: statusCode, reason: reason, message: message)
    }
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
          let importedIdentity = entries.first?[kSecImportItemIdentity as String] else {
        FileHandle.standardError.write(Data("blockpage: PKCS12 import failed (\(status))\n".utf8))
        return nil
    }
    // Swift's Core Foundation overlay does not permit a conditional SecIdentity
    // cast here, so validate the runtime CF type before using the API-guaranteed
    // object conversion. A malformed import now disables HTTPS instead of
    // terminating the block-page daemon.
    let importedObject = importedIdentity as AnyObject
    guard CFGetTypeID(importedObject) == SecIdentityGetTypeID() else {
        FileHandle.standardError.write(Data("blockpage: PKCS12 identity has an unexpected type\n".utf8))
        return nil
    }
    return unsafeDowncast(importedObject, to: SecIdentity.self)
}

// MARK: - Listeners

private func serve(connection: NWConnection) {
    connection.stateUpdateHandler = { state in
        if case .failed = state { connection.cancel() }
    }
    receiveRequest(connection: connection)
    connection.start(queue: .global(qos: .utility))
}

private func receiveRequest(connection: NWConnection, accumulated: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, isComplete, error in
        if error != nil {
            connection.cancel()
            return
        }
        var requestData = accumulated
        if let data { requestData.append(data) }
        do {
            switch try BlockPageHTTPRequestParser.state(for: requestData) {
            case .incomplete where !isComplete:
                receiveRequest(connection: connection, accumulated: requestData)
            case .incomplete:
                send(requestError(status: 400, reason: "Bad Request", message: "The HTTP request ended before it was complete."), on: connection)
            case let .complete(length):
                let request = try BlockPageHTTPRequestParser.parse(Data(requestData.prefix(length)))
                send(response(to: request), on: connection)
            }
        } catch {
            send(requestError(status: 400, reason: "Bad Request", message: "The HTTP request was invalid or too large."), on: connection)
        }
    }
}

private func send(_ response: Data, on connection: NWConnection) {
    connection.send(
        content: response,
        completion: .contentProcessed { _ in connection.cancel() }
    )
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

// Top-level executable state is main-actor isolated under Swift 6. Keeping the
// lightweight one-second status/hosts check on the main queue also gives the
// daemon a single serialization point for timers and termination cleanup.
let hostsTimer = DispatchSource.makeTimerSource(queue: .main)
hostsTimer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
hostsTimer.setEventHandler { synchronizeHosts() }
hostsTimer.resume()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    synchronizeHosts(forceEmpty: true)
    exit(EXIT_SUCCESS)
}
terminationSource.resume()
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    synchronizeHosts(forceEmpty: true)
    exit(EXIT_SUCCESS)
}
interruptSource.resume()
FileHandle.standardError.write(
    Data("blockpage: serving on 127.0.0.1:\(httpPort) and :\(httpsPort)\n".utf8)
)
dispatchMain()
