import Foundation
import Network
import NetworkExtension
import OSLog

final class MacWebFilterProvider: NEFilterDataProvider {
    private let policyLoader = ResilientDesktopPolicyLoader()
    private let sourceResolver = FlowSourceResolver()
    private let statusPublisher = FilterStatusPublisher()
    private let inspectionLock = NSLock()
    private var outboundPrefixes: [ObjectIdentifier: Data] = [:]
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "data-provider"
    )

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let policy = currentPolicy()
        logger.notice("Started data provider at policy revision \(policy.revision, privacy: .public)")
        completionHandler(nil)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let policy = currentPolicy()
        let descriptor = self.descriptor(for: flow)

        // Measures how the framework actually honours `peekOutboundBytes`:
        // whether it delivers whatever the client wrote, or waits for the full
        // request. The answer decides how much a ClientHello peek can safely
        // ask for. Scoped to one port so no real traffic can be affected.
        if FilterProbe.isEnabled, descriptor.remotePort == FilterProbe.port {
            logger.notice("PROBE new flow port \(FilterProbe.port, privacy: .public) peek \(FilterProbe.peekBytes, privacy: .public)")
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: FilterProbe.peekBytes
            )
        }
        if FilterProbe.isEnabled, FilterProbe.probeOnly { return .allow() }

        switch WebFilterFlowDecider.decision(for: descriptor, policy: policy) {
        case .allow:
            return .allow()
        case .drop:
            logger.debug("Dropped flow at revision \(policy.revision, privacy: .public), host \(descriptor.hostname ?? descriptor.remoteAddress ?? "unknown", privacy: .private)")
            return .drop()
        case let .inspect(peekBytes):
            // The data callback either resolves the payload or, for a declared
            // partial TLS record, requests the exact larger prefix needed to
            // classify the ClientHello.
            beginInspection(of: flow)
            return .filterDataVerdict(
                withFilterInbound: false,
                peekInboundBytes: 0,
                filterOutbound: true,
                peekOutboundBytes: peekBytes
            )
        }
    }

    override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        let policy = currentPolicy()
        let descriptor = self.descriptor(for: flow)

        if FilterProbe.isEnabled, descriptor.remotePort == FilterProbe.port {
            logger.notice("PROBE outbound data offset \(offset, privacy: .public) bytes \(readBytes.count, privacy: .public)")
            return .allow()
        }

        guard let accumulatedBytes = accumulate(readBytes, at: offset, for: flow) else {
            logger.error("Dropped inspected flow with invalid byte sequence at revision \(policy.revision, privacy: .public), offset \(offset, privacy: .public), bytes \(readBytes.count, privacy: .public)")
            finishInspection(of: flow)
            return .drop()
        }

        let decision = WebFilterFlowDecider.decision(
            forOutboundBytes: accumulatedBytes,
            flow: descriptor,
            policy: policy
        )
        switch decision {
        case .drop:
            logger.debug("Dropped inspected flow at revision \(policy.revision, privacy: .public)")
            finishInspection(of: flow)
            return .drop()
        case let .inspect(peekBytes):
            let remainingBytes = max(1, peekBytes - accumulatedBytes.count)
            logger.debug("Continuing inspected flow at revision \(policy.revision, privacy: .public), offset \(offset, privacy: .public), chunk \(readBytes.count, privacy: .public), accumulated \(accumulatedBytes.count, privacy: .public), remaining \(remainingBytes, privacy: .public), endpoint \(descriptor.hostname ?? descriptor.remoteAddress ?? "unknown", privacy: .private)")
            return NEFilterDataVerdict(passBytes: 0, peekBytes: remainingBytes)

        case .allow:
            logger.debug("Allowed classified flow at revision \(policy.revision, privacy: .public), offset \(offset, privacy: .public), bytes \(readBytes.count, privacy: .public), endpoint \(descriptor.hostname ?? descriptor.remoteAddress ?? "unknown", privacy: .private)")
            finishInspection(of: flow)
            return .allow()
        }
    }

    /// A flow held back for fast failure might close without ever writing.
    /// Re-applying the verdict here stops that becoming a silent allow.
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        finishInspection(of: flow)
        let descriptor = self.descriptor(for: flow)
        switch WebFilterFlowDecider.decision(for: descriptor, policy: currentPolicy()) {
        case .drop, .inspect:
            // This callback is reached only when the requested outbound prefix
            // can never become complete. Do not convert that terminally
            // unclassified handshake into an allow.
            return .drop()
        case .allow:
            return .allow()
        }
    }

    private func currentPolicy() -> DesktopEnforcementPolicy {
        let policy = policyLoader.current(vendorConfiguration: filterConfiguration.vendorConfiguration)
        // Off-thread and throttled; the flow path never touches the file system.
        statusPublisher.record(policy)
        return policy
    }

    private func beginInspection(of flow: NEFilterFlow) {
        inspectionLock.lock()
        outboundPrefixes[ObjectIdentifier(flow)] = Data()
        inspectionLock.unlock()
    }

    private func accumulate(_ readBytes: Data, at offset: Int, for flow: NEFilterFlow) -> Data? {
        inspectionLock.lock()
        defer { inspectionLock.unlock() }
        let key = ObjectIdentifier(flow)
        var prefix = outboundPrefixes[key] ?? Data()
        guard WebFilterOutboundByteAccumulator.append(readBytes, at: offset, to: &prefix) else {
            outboundPrefixes.removeValue(forKey: key)
            return nil
        }
        outboundPrefixes[key] = prefix
        return prefix
    }

    private func finishInspection(of flow: NEFilterFlow) {
        inspectionLock.lock()
        outboundPrefixes.removeValue(forKey: ObjectIdentifier(flow))
        inspectionLock.unlock()
    }

    private func descriptor(for flow: NEFilterFlow) -> WebFilterFlowDescriptor {
        var descriptor = WebFilterFlowDescriptor(hostname: flow.url?.host)
        // macOS supplies an audit token rather than iOS's bundle identifier.
        if let identity = sourceResolver.identity(forAuditToken: flow.sourceAppAuditToken) {
            descriptor.sourceSigningIdentifier = identity.signingIdentifier
            descriptor.sourceExecutablePath = identity.executablePath
        }
        guard let socketFlow = flow as? NEFilterSocketFlow else { return descriptor }

        if descriptor.hostname?.isEmpty != false {
            descriptor.hostname = socketFlow.remoteHostname
        }
        descriptor.isTCP = socketFlow.socketProtocol == IPPROTO_TCP
        let endpoint = remoteEndpoint(of: socketFlow)
        descriptor.remoteAddress = endpoint.address
        descriptor.remotePort = endpoint.port
        return descriptor
    }

    private func remoteEndpoint(of flow: NEFilterSocketFlow) -> (address: String?, port: Int?) {
        guard #available(macOS 15.0, *), let endpoint = flow.remoteFlowEndpoint,
              case let .hostPort(host, port) = endpoint else { return (nil, nil) }
        let address: String? = switch host {
        case let .ipv4(value): "\(value)"
        case let .ipv6(value): "\(value)"
        case let .name(name, _): name
        @unknown default: nil
        }
        return (address, Int(port.rawValue))
    }
}
