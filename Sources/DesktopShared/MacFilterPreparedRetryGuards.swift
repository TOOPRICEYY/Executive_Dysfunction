import Darwin
import Dispatch
import Foundation
import dnssd

/// A prepared, revision-bound address set that can cross the containing-app to
/// Network Extension boundary in `vendorConfiguration`.
///
/// A provider must not perform blocking name resolution from `startFilter`.
/// The containing app can instead prepare this value before enabling the
/// filter. The provider accepts it only when the revision, complete canonical
/// domain set, lifetime, and exact bounded installation set all still match.
struct MacFilterPreparedRetryGuardSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var policyRevision: UInt64
    var preparedAt: Date
    var expiresAt: Date
    var domainSuffixes: [String]
    var addressesByDomainSuffix: [String: [String]]
    /// Explicit recovery mode, never inferred from missing/corrupt data. Named
    /// blocking stays active while only the missing IP guards are repaired.
    var permitsIncompleteCoverage: Bool? = nil

    init(
        policyRevision: UInt64,
        plan: MacFilterInterceptionPlan,
        resolution: MacFilterDomainAddressResolution,
        preparedAt: Date = Date(),
        validFor: TimeInterval,
        permitsIncompleteCoverage: Bool = false
    ) {
        let domains = MacFilterRetryGuardDomainCanonicalizer.canonicalSuffixes(
            plan.retryGuardResolutionDomainSuffixes
        )
        var preparedAddresses: [String: [String]] = [:]
        for domain in domains {
            preparedAddresses[domain] = Array(
                resolution.addressesByDomainSuffix[domain] ?? []
            ).compactMap(MacFilterInterceptionPlan.normalizedCorrelatedAddress)
                .sorted()
        }

        schemaVersion = Self.currentSchemaVersion
        self.policyRevision = policyRevision
        self.preparedAt = preparedAt
        expiresAt = preparedAt.addingTimeInterval(validFor)
        domainSuffixes = domains
        addressesByDomainSuffix = preparedAddresses
        self.permitsIncompleteCoverage = permitsIncompleteCoverage ? true : nil
    }

    func validate(
        for plan: MacFilterInterceptionPlan,
        policyRevision expectedRevision: UInt64,
        at date: Date = Date()
    ) -> MacFilterPreparedRetryGuardValidation {
        validate(for: plan, policyRevision: expectedRevision, at: date, requiresRevisionMatch: true)
    }

    /// A short-lived prepared address set belongs to the same enforcement plan,
    /// not to the containing app build which happened to write it. During an
    /// in-place app update the old preference remains available while the new
    /// provider is being prepared. Rebinding a still-valid, exact-plan snapshot
    /// avoids turning a momentary DNS outage in that handoff into a persistent
    /// availability pause. The expiration time is deliberately preserved: this
    /// never extends the lifetime of a previously resolved address.
    func rebound(
        for plan: MacFilterInterceptionPlan,
        policyRevision: UInt64,
        at date: Date = Date()
    ) -> MacFilterPreparedRetryGuardSnapshot? {
        guard permitsIncompleteCoverage != true else { return nil }
        guard case .accepted = validate(
            for: plan,
            policyRevision: self.policyRevision,
            at: date,
            requiresRevisionMatch: false
        ) else {
            return nil
        }
        var rebound = self
        rebound.policyRevision = policyRevision
        guard case .accepted = rebound.validate(
            for: plan,
            policyRevision: policyRevision,
            at: date
        ) else {
            return nil
        }
        return rebound
    }

    private func validate(
        for plan: MacFilterInterceptionPlan,
        policyRevision expectedRevision: UInt64,
        at date: Date,
        requiresRevisionMatch: Bool
    ) -> MacFilterPreparedRetryGuardValidation {
        guard schemaVersion == Self.currentSchemaVersion else {
            return .rejected(.unsupportedSchema)
        }
        guard !requiresRevisionMatch || policyRevision == expectedRevision else {
            return .rejected(.revisionMismatch)
        }
        guard preparedAt <= date else {
            return .rejected(.notYetValid)
        }
        guard expiresAt > preparedAt, date < expiresAt else {
            return .rejected(.expired)
        }
        guard plan.mode == .domainRules else {
            return .rejected(.planDoesNotRequireRetryGuards)
        }

        let expectedDomains = MacFilterRetryGuardDomainCanonicalizer.canonicalSuffixes(
            plan.retryGuardResolutionDomainSuffixes
        )
        let expectedDomainSet = Set(expectedDomains)
        guard domainSuffixes.count == expectedDomains.count,
              Set(domainSuffixes) == expectedDomainSet,
              addressesByDomainSuffix.count == expectedDomains.count,
              Set(addressesByDomainSuffix.keys) == expectedDomainSet else {
            return .rejected(.domainSetMismatch)
        }

        var resolution = MacFilterDomainAddressResolution()
        for domain in expectedDomains {
            resolution.record(addressesByDomainSuffix[domain] ?? [], forDomainSuffix: domain)
        }
        let retryGuards = resolution.retryGuards(for: plan)
        guard retryGuards.hasCompleteRequiredCoverage || permitsIncompleteCoverage == true else {
            return .rejected(.incompleteCoverage)
        }

        // Explicit sites require exact retry coverage. Helper domains remain
        // hostname/port drops, but an unavailable helper must not prevent the
        // user-selected site from being prepared and safely enabled.
        let missingInstalledCoverage = plan.retryGuardRequiredDomainSuffixes.contains { domain in
            let domainAddresses = resolution.addressesByDomainSuffix[domain] ?? []
            return domainAddresses.isDisjoint(with: retryGuards.addresses)
        }
        guard !missingInstalledCoverage || permitsIncompleteCoverage == true else {
            return .rejected(.incompleteCoverage)
        }

        return .accepted(
            MacFilterAcceptedPreparedRetryGuards(
                resolution: resolution,
                retryGuards: retryGuards,
                expiresAt: expiresAt
            )
        )
    }

    /// Reuse still-fresh answers for unchanged domains when the policy adds a
    /// domain. This never reuses expired addresses or certifies full coverage.
    func reusableResolution(for plan: MacFilterInterceptionPlan, at date: Date) -> MacFilterDomainAddressResolution {
        guard schemaVersion == Self.currentSchemaVersion,
              preparedAt <= date, expiresAt > date, expiresAt > preparedAt,
              Set(domainSuffixes) == Set(addressesByDomainSuffix.keys),
              domainSuffixes.count == addressesByDomainSuffix.count else { return .init() }
        var result = MacFilterDomainAddressResolution()
        for domain in plan.retryGuardResolutionDomainSuffixes {
            result.record(addressesByDomainSuffix[domain] ?? [], forDomainSuffix: domain)
        }
        return result
    }
}

enum MacRetryGuardRecovery {
    static let foregroundRetries = 2
    static func shouldResumeNamedBlocking(after preparationRetry: Int) -> Bool {
        preparationRetry >= foregroundRetries
    }
    static func preparationMessage(missing: [String], resuming: Bool) -> String {
        let names = missing.sorted().joined(separator: ", ")
        return resuming
            ? "Resuming hostname blocking. IP retry protection is incomplete for: \(names). DNS will retry automatically; these sites may still be reachable by cached IP."
            : "Web enforcement is temporarily stopped while blocked-site DNS is prepared. Retrying: \(names)."
    }
}

struct MacFilterAcceptedPreparedRetryGuards: Equatable, Sendable {
    var resolution: MacFilterDomainAddressResolution
    var retryGuards: MacFilterRetryGuardSet
    var expiresAt: Date
}

enum MacFilterPreparedRetryGuardRejection: String, Equatable, Sendable {
    case unsupportedSchema
    case revisionMismatch
    case notYetValid
    case expired
    case planDoesNotRequireRetryGuards
    case domainSetMismatch
    case incompleteCoverage
}

enum MacFilterPreparedRetryGuardValidation: Equatable, Sendable {
    case accepted(MacFilterAcceptedPreparedRetryGuards)
    case rejected(MacFilterPreparedRetryGuardRejection)
}

/// The single result of one bounded asynchronous resolution batch. A timeout
/// or cancellation intentionally returns whatever was learned before the batch
/// ended; callers decide whether that partial result is sufficient. Prepared
/// snapshot validation never accepts partial coverage.
struct MacFilterAsyncDNSResolutionResult: Equatable, Sendable {
    var resolution: MacFilterDomainAddressResolution
    var requestedDomainSuffixes: [String]
    var settledDomainSuffixes: [String]
    var unresolvedDomainSuffixes: [String]
    var didReachDeadline: Bool
    var wasCancelled: Bool
}

/// Idempotent cancellation for an asynchronous resolution batch.
final class MacFilterDNSResolutionTask: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }
}

/// An injectable per-domain lookup handle. Production handles own one
/// `DNSServiceRef`; tests use this seam to model timeouts and hostile late
/// callbacks without issuing live DNS requests.
final class MacFilterDNSLookupHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }
}

struct MacFilterDNSLookupEvent: Equatable, Sendable {
    var address: String?
    var isAddition: Bool
    var moreComing: Bool
    var errorCode: Int32
}

/// Cancellable, non-blocking address resolution built on the public DNS-SD
/// callback API. All DNSServiceRefs are scheduled and deallocated on the same
/// private serial queue, as required by `DNSServiceSetDispatchQueue`.
final class MacFilterAsyncDomainResolver: @unchecked Sendable {
    typealias LookupStarter = @Sendable (
        _ domainSuffix: String,
        _ callbackQueue: DispatchQueue,
        _ callback: @escaping @Sendable (MacFilterDNSLookupEvent) -> Void
    ) -> MacFilterDNSLookupHandle?

    private let queue: DispatchQueue
    private let lookupStarter: LookupStarter
    private var operations: [UUID: ResolutionOperation] = [:]

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.GabrielPrice.ExecutiveDysfunction.retry-guard-resolution",
            qos: .utility
        )
    ) {
        self.queue = queue
        lookupStarter = Self.productionLookupStarter
    }

    init(queue: DispatchQueue, lookupStarter: @escaping LookupStarter) {
        self.queue = queue
        self.lookupStarter = lookupStarter
    }

    /// Starts all canonical domain lookups concurrently and returns no later
    /// than the caller's one overall deadline. Completion is invoked exactly
    /// once on the resolver's serial queue, including after cancellation.
    @discardableResult
    func resolve(
        domainSuffixes: [String],
        timeout: TimeInterval,
        collectForFullWindow: Bool = false,
        completion: @escaping @Sendable (MacFilterAsyncDNSResolutionResult) -> Void
    ) -> MacFilterDNSResolutionTask {
        let identifier = UUID()
        let domains = MacFilterRetryGuardDomainCanonicalizer.canonicalSuffixes(domainSuffixes)
        let boundedTimeout = timeout.isFinite ? max(0, timeout) : 0
        let deadline = DispatchTime.now() + boundedTimeout

        queue.async { [self] in
            let operation = ResolutionOperation(
                identifier: identifier,
                domains: domains,
                collectForFullWindow: collectForFullWindow,
                completion: completion
            )
            operations[identifier] = operation
            startLookups(for: operation)
        }
        queue.asyncAfter(deadline: deadline) { [self] in
            guard let operation = operations[identifier] else { return }
            let incomplete = operation.settledDomains.count != operation.domains.count
            finish(identifier, didReachDeadline: incomplete, wasCancelled: false)
        }

        return MacFilterDNSResolutionTask { [weak self] in
            self?.queue.async { [weak self] in
                self?.finish(identifier, didReachDeadline: false, wasCancelled: true)
            }
        }
    }

    @discardableResult
    func resolve(
        for plan: MacFilterInterceptionPlan,
        timeout: TimeInterval,
        completion: @escaping @Sendable (MacFilterAsyncDNSResolutionResult) -> Void
    ) -> MacFilterDNSResolutionTask {
        resolve(
            domainSuffixes: plan.retryGuardResolutionDomainSuffixes,
            timeout: timeout,
            collectForFullWindow: true,
            completion: completion
        )
    }

    private func startLookups(for operation: ResolutionOperation) {
        for domain in operation.domains {
            let identifier = operation.identifier
            let handle = lookupStarter(domain, queue) { [weak self] event in
                guard let self else { return }
                queue.async { [weak self] in
                    self?.receive(event, for: domain, operation: identifier)
                }
            }
            if operation.isFinished {
                handle?.cancel()
                return
            }
            if let handle {
                operation.handles[domain] = handle
            } else {
                operation.settledDomains.insert(domain)
            }
        }
        if !operation.isFinished, !operation.collectForFullWindow || operation.domains.isEmpty,
           operation.settledDomains.count == operation.domains.count {
            finish(operation.identifier, didReachDeadline: false, wasCancelled: false)
        }
    }

    private func receive(
        _ event: MacFilterDNSLookupEvent,
        for domain: String,
        operation identifier: UUID
    ) {
        guard let operation = operations[identifier], !operation.isFinished else { return }

        if let rawAddress = event.address,
           let address = MacFilterInterceptionPlan.normalizedCorrelatedAddress(rawAddress) {
            if event.isAddition {
                operation.addressesByDomain[domain, default: []].insert(address)
            } else {
                operation.addressesByDomain[domain]?.remove(address)
            }
        }
        if event.errorCode != DNSServiceErrorType(kDNSServiceErr_NoError) || !event.moreComing {
            operation.settledDomains.insert(domain)
        } else {
            operation.settledDomains.remove(domain)
        }
        // MoreComing=false ends only the current callback batch, not the DNS
        // query. In enforcement preparation keep the reference alive through
        // the bounded window so delayed A/AAAA answers also receive guards.
        if !operation.collectForFullWindow, operation.settledDomains.count == operation.domains.count {
            finish(identifier, didReachDeadline: false, wasCancelled: false)
        }
    }

    private func finish(
        _ identifier: UUID,
        didReachDeadline: Bool,
        wasCancelled: Bool
    ) {
        guard let operation = operations.removeValue(forKey: identifier),
              !operation.isFinished else { return }
        operation.isFinished = true

        // This method runs only on `queue`, the same queue on which production
        // DNSServiceRefs were scheduled. Deallocation is therefore safe even
        // when the overall deadline wins a race with a DNS callback.
        for handle in operation.handles.values {
            handle.cancel()
        }
        operation.handles.removeAll()

        var resolution = MacFilterDomainAddressResolution()
        for domain in operation.domains {
            resolution.record(operation.addressesByDomain[domain] ?? [], forDomainSuffix: domain)
        }
        let unresolved = operation.domains.filter {
            resolution.addressesByDomainSuffix[$0]?.isEmpty != false
        }
        operation.completion(
            MacFilterAsyncDNSResolutionResult(
                resolution: resolution,
                requestedDomainSuffixes: operation.domains,
                settledDomainSuffixes: operation.settledDomains.sorted(),
                unresolvedDomainSuffixes: unresolved,
                didReachDeadline: didReachDeadline,
                wasCancelled: wasCancelled
            )
        )
    }

    private static let productionLookupStarter: LookupStarter = {
        domainSuffix,
        callbackQueue,
        callback in
        let lookup = DNSServiceLookup(callback: callback)
        guard lookup.start(domainSuffix: domainSuffix, callbackQueue: callbackQueue) else {
            return nil
        }
        return MacFilterDNSLookupHandle {
            lookup.cancel()
        }
    }
}

private final class ResolutionOperation: @unchecked Sendable {
    let identifier: UUID
    let domains: [String]
    let collectForFullWindow: Bool
    let completion: @Sendable (MacFilterAsyncDNSResolutionResult) -> Void
    var handles: [String: MacFilterDNSLookupHandle] = [:]
    var addressesByDomain: [String: Set<String>] = [:]
    var settledDomains: Set<String> = []
    var isFinished = false

    init(
        identifier: UUID,
        domains: [String],
        collectForFullWindow: Bool,
        completion: @escaping @Sendable (MacFilterAsyncDNSResolutionResult) -> Void
    ) {
        self.identifier = identifier
        self.domains = domains
        self.collectForFullWindow = collectForFullWindow
        self.completion = completion
    }
}

private final class DNSServiceLookup: @unchecked Sendable {
    private var reference: DNSServiceRef?
    private let callback: @Sendable (MacFilterDNSLookupEvent) -> Void

    init(callback: @escaping @Sendable (MacFilterDNSLookupEvent) -> Void) {
        self.callback = callback
    }

    func start(domainSuffix: String, callbackQueue: DispatchQueue) -> Bool {
        var createdReference: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsTimeout)
        let protocols = DNSServiceProtocol(
            kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6
        )
        let startError = DNSServiceGetAddrInfo(
            &createdReference,
            flags,
            UInt32(kDNSServiceInterfaceIndexAny),
            protocols,
            domainSuffix,
            macFilterDNSServiceGetAddrInfoReply,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard startError == DNSServiceErrorType(kDNSServiceErr_NoError),
              let createdReference else {
            return false
        }
        reference = createdReference

        let queueError = DNSServiceSetDispatchQueue(createdReference, callbackQueue)
        guard queueError == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            reference = nil
            DNSServiceRefDeallocate(createdReference)
            return false
        }
        return true
    }

    func cancel() {
        guard let reference else { return }
        self.reference = nil
        DNSServiceRefDeallocate(reference)
    }

    fileprivate func receive(
        flags: DNSServiceFlags,
        errorCode: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        let numericAddress = errorCode == kDNSServiceErr_NoError ? address.flatMap(Self.numericAddress) : nil
        callback(
            MacFilterDNSLookupEvent(
                address: numericAddress,
                isAddition: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                moreComing: flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0,
                errorCode: errorCode
            )
        )
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(
            address,
            length,
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

private func macFilterDNSServiceGetAddrInfoReply(
    _ serviceReference: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ hostname: UnsafePointer<CChar>?,
    _ address: UnsafePointer<sockaddr>?,
    _ ttl: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<DNSServiceLookup>.fromOpaque(context).takeUnretainedValue().receive(
        flags: flags,
        errorCode: errorCode,
        address: address
    )
}

private enum MacFilterRetryGuardDomainCanonicalizer {
    static func canonicalSuffixes<S: Sequence>(_ rawDomains: S) -> [String]
    where S.Element == String {
        Set(rawDomains.compactMap(canonicalSuffix)).sorted()
    }

    static func canonicalSuffix(_ rawDomain: String) -> String? {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        guard !domain.isEmpty,
              !domain.contains("/"),
              domain.utf8.allSatisfy({ byte in
                  (byte >= 0x61 && byte <= 0x7a)
                      || (byte >= 0x30 && byte <= 0x39)
                      || byte == 0x2d
                      || byte == 0x2e
              }) else { return nil }
        return domain
    }
}
