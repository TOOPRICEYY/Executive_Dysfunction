import Dispatch
import Foundation
import XCTest

final class MacFilterPreparedRetryGuardsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testIncompleteCoverageRequiresExplicitRecoveryModeAndPreservesKnownGuards() {
        let plan = makePlan(blocked: ["good.example", "missing.example"], required: ["good.example", "missing.example"])
        let resolution = MacFilterDomainAddressResolution(addressesByDomainSuffix: ["good.example": ["203.0.113.10"]])
        var snapshot = MacFilterPreparedRetryGuardSnapshot(policyRevision: 5, plan: plan,
            resolution: resolution, preparedAt: now, validFor: 60)
        XCTAssertEqual(snapshot.validate(for: plan, policyRevision: 5, at: now), .rejected(.incompleteCoverage))
        snapshot.permitsIncompleteCoverage = true
        guard case let .accepted(value) = snapshot.validate(for: plan, policyRevision: 5, at: now) else {
            return XCTFail("Explicit partial mode must resume named blocking")
        }
        XCTAssertEqual(value.retryGuards.addresses, ["203.0.113.10"])
        XCTAssertEqual(value.retryGuards.missingRequiredDomainSuffixes, ["missing.example"])
        XCTAssertFalse(value.retryGuards.hasCompleteRequiredCoverage)
        XCTAssertEqual(snapshot.validate(for: plan, policyRevision: 6, at: now), .rejected(.revisionMismatch))
        XCTAssertEqual(snapshot.validate(for: plan, policyRevision: 5, at: now.addingTimeInterval(61)), .rejected(.expired))
        XCTAssertNil(snapshot.rebound(for: plan, policyRevision: 6, at: now), "Partial mode must not masquerade as a complete fallback")
    }

    func testCompleteDNSFailureCanStartNamedRulesWithoutFabricatingAddresses() throws {
        let plan = makePlan(blocked: ["missing.example"], required: ["missing.example"])
        let snapshot = MacFilterPreparedRetryGuardSnapshot(policyRevision: 5, plan: plan,
            resolution: .init(), preparedAt: now, validFor: 60, permitsIncompleteCoverage: true)
        let restored = try JSONDecoder().decode(MacFilterPreparedRetryGuardSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard case let .accepted(value) = restored.validate(for: plan, policyRevision: 5, at: now) else {
            return XCTFail("Recovery should be transportable with zero public answers")
        }
        XCTAssertTrue(value.retryGuards.addresses.isEmpty)
        XCTAssertEqual(value.retryGuards.missingRequiredDomainSuffixes, ["missing.example"])
    }

    func testCachedAnswersCanSeedAnExpandedPlanWithoutInventingCoverage() {
        let old = makePlan(blocked: ["old.example"], required: ["old.example"])
        let expanded = makePlan(blocked: ["old.example", "new.example"], required: ["old.example", "new.example"])
        let snapshot = MacFilterPreparedRetryGuardSnapshot(policyRevision: 5, plan: old,
            resolution: .init(addressesByDomainSuffix: ["old.example": ["203.0.113.10"]]), preparedAt: now, validFor: 60)
        let reused = snapshot.reusableResolution(for: expanded, at: now).retryGuards(for: expanded)
        XCTAssertEqual(reused.addresses, ["203.0.113.10"])
        XCTAssertEqual(reused.missingRequiredDomainSuffixes, ["new.example"])
        XCTAssertTrue(snapshot.reusableResolution(for: expanded, at: now.addingTimeInterval(61)).addressesByDomainSuffix.isEmpty)
        XCTAssertTrue(snapshot.reusableResolution(for: expanded, at: now.addingTimeInterval(-1)).addressesByDomainSuffix.isEmpty)
        let other = makePlan(blocked: ["different.example"], required: ["different.example"])
        XCTAssertTrue(snapshot.reusableResolution(for: other, at: now).addressesByDomainSuffix.isEmpty)
    }

    func testBoundedForegroundRetriesResumeBlockingInsteadOfGivingUp() {
        XCTAssertFalse(MacRetryGuardRecovery.shouldResumeNamedBlocking(after: 0))
        XCTAssertFalse(MacRetryGuardRecovery.shouldResumeNamedBlocking(after: 1))
        XCTAssertTrue(MacRetryGuardRecovery.shouldResumeNamedBlocking(after: 2))
        XCTAssertTrue(MacRetryGuardRecovery.shouldResumeNamedBlocking(after: 20))
        let message = MacRetryGuardRecovery.preparationMessage(missing: ["bad.example"], resuming: true)
        XCTAssertTrue(message.contains("bad.example"))
        XCTAssertTrue(message.contains("incomplete"))
        XCTAssertTrue(message.contains("cached IP"))
        XCTAssertFalse(message.contains("suspended it while idle"))
    }

    func testSnapshotAcceptsCompleteExplicitCoverageWhenHelperHasNoAnswer() {
        let plan = makePlan(
            blocked: ["blocked.example", "dns.google"],
            required: ["blocked.example"]
        )
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.10"], forDomainSuffix: "blocked.example")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 17,
            plan: plan,
            resolution: resolution,
            preparedAt: now,
            validFor: 60
        )

        guard case let .accepted(accepted) = snapshot.validate(
            for: plan,
            policyRevision: 17,
            at: now.addingTimeInterval(1)
        ) else {
            return XCTFail("A helper lookup failure must not mask complete explicit coverage")
        }
        XCTAssertEqual(accepted.retryGuards.addresses, ["203.0.113.10"])
        XCTAssertTrue(accepted.retryGuards.hasCompleteRequiredCoverage)
        XCTAssertEqual(accepted.expiresAt, now.addingTimeInterval(60))
    }

    func testSnapshotPreservesExplicitChildSubsumedBySystemRuleParent() {
        let plan = makePlan(
            blocked: ["example.com"],
            required: ["blocked.example.com"]
        )
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.20"], forDomainSuffix: "blocked.example.com")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 18,
            plan: plan,
            resolution: resolution,
            preparedAt: now,
            validFor: 60
        )

        XCTAssertEqual(snapshot.domainSuffixes, ["blocked.example.com", "example.com"])
        guard case let .accepted(accepted) = snapshot.validate(
            for: plan,
            policyRevision: 18,
            at: now.addingTimeInterval(1)
        ) else {
            return XCTFail("The explicit child needs its own retry correlation answer")
        }
        XCTAssertEqual(accepted.retryGuards.addresses, ["203.0.113.20"])
    }

    func testSnapshotRejectsIncompleteExplicitCoverage() {
        let plan = makePlan(
            blocked: ["blocked.example", "dns.google"],
            required: ["blocked.example"]
        )
        var helperOnly = MacFilterDomainAddressResolution()
        helperOnly.record(["8.8.8.8"], forDomainSuffix: "dns.google")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 19,
            plan: plan,
            resolution: helperOnly,
            preparedAt: now,
            validFor: 60
        )

        XCTAssertEqual(
            snapshot.validate(for: plan, policyRevision: 19, at: now.addingTimeInterval(1)),
            .rejected(.incompleteCoverage)
        )
    }

    func testUpdateCanReuseValidatedUnexpiredSnapshotWhenFreshResolutionIsIncomplete() {
        let plan = makePlan(
            blocked: ["blocked.example"],
            required: ["blocked.example"]
        )
        var previousResolution = MacFilterDomainAddressResolution()
        previousResolution.record(["203.0.113.25"], forDomainSuffix: "blocked.example")
        let previousSnapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 24,
            plan: plan,
            resolution: previousResolution,
            preparedAt: now,
            validFor: 60
        )

        var incompleteFreshResolution = MacFilterDomainAddressResolution()
        incompleteFreshResolution.record([], forDomainSuffix: "blocked.example")
        XCTAssertFalse(
            incompleteFreshResolution.retryGuards(for: plan).hasCompleteRequiredCoverage
        )

        let updateTime = now.addingTimeInterval(10)
        guard let rebound = previousSnapshot.rebound(
            for: plan,
            policyRevision: 25,
            at: updateTime
        ) else {
            return XCTFail("An unexpired exact-plan snapshot should survive an in-place update")
        }

        XCTAssertEqual(rebound.policyRevision, 25)
        XCTAssertEqual(rebound.preparedAt, previousSnapshot.preparedAt)
        XCTAssertEqual(rebound.expiresAt, previousSnapshot.expiresAt)
        guard case let .accepted(accepted) = rebound.validate(
            for: plan,
            policyRevision: 25,
            at: updateTime
        ) else {
            return XCTFail("The rebound snapshot must still provide complete retry coverage")
        }
        XCTAssertEqual(accepted.retryGuards.addresses, ["203.0.113.25"])
    }

    func testUpdateCannotReuseExpiredOrDifferentPlanSnapshot() {
        let oldPlan = makePlan(blocked: ["blocked.example"], required: ["blocked.example"])
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.26"], forDomainSuffix: "blocked.example")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 26,
            plan: oldPlan,
            resolution: resolution,
            preparedAt: now,
            validFor: 10
        )
        let changedPlan = makePlan(blocked: ["other.example"], required: ["other.example"])

        XCTAssertNil(
            snapshot.rebound(
                for: oldPlan,
                policyRevision: 27,
                at: now.addingTimeInterval(10)
            )
        )
        XCTAssertNil(
            snapshot.rebound(
                for: changedPlan,
                policyRevision: 27,
                at: now.addingTimeInterval(1)
            )
        )
    }

    func testSnapshotRejectsWrongRevisionLifetimeSchemaAndPlanMode() {
        let plan = makePlan(blocked: ["blocked.example"], required: ["blocked.example"])
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.30"], forDomainSuffix: "blocked.example")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 20,
            plan: plan,
            resolution: resolution,
            preparedAt: now,
            validFor: 60
        )

        XCTAssertEqual(
            snapshot.validate(for: plan, policyRevision: 21, at: now.addingTimeInterval(1)),
            .rejected(.revisionMismatch)
        )
        XCTAssertEqual(
            snapshot.validate(for: plan, policyRevision: 20, at: now.addingTimeInterval(-1)),
            .rejected(.notYetValid)
        )
        XCTAssertEqual(
            snapshot.validate(for: plan, policyRevision: 20, at: now.addingTimeInterval(60)),
            .rejected(.expired)
        )

        var wrongSchema = snapshot
        wrongSchema.schemaVersion += 1
        XCTAssertEqual(
            wrongSchema.validate(for: plan, policyRevision: 20, at: now.addingTimeInterval(1)),
            .rejected(.unsupportedSchema)
        )

        let bypass = MacFilterInterceptionPlan(
            mode: .bypass,
            defaultAction: .allow,
            blockedDomainSuffixes: [],
            blockedDestinationPorts: []
        )
        XCTAssertEqual(
            snapshot.validate(for: bypass, policyRevision: 20, at: now.addingTimeInterval(1)),
            .rejected(.planDoesNotRequireRetryGuards)
        )
    }

    func testSnapshotRequiresExactCanonicalDeclaredAndStoredDomainSets() {
        let plan = makePlan(
            blocked: ["blocked.example", "dns.google"],
            required: ["blocked.example"]
        )
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.40"], forDomainSuffix: "blocked.example")
        let original = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 22,
            plan: plan,
            resolution: resolution,
            preparedAt: now,
            validFor: 60
        )

        var duplicateDeclaration = original
        duplicateDeclaration.domainSuffixes.append("blocked.example")
        XCTAssertEqual(
            duplicateDeclaration.validate(
                for: plan,
                policyRevision: 22,
                at: now.addingTimeInterval(1)
            ),
            .rejected(.domainSetMismatch)
        )

        var noncanonicalStoredKey = original
        noncanonicalStoredKey.addressesByDomainSuffix["DNS.GOOGLE"] =
            noncanonicalStoredKey.addressesByDomainSuffix.removeValue(forKey: "dns.google")
        XCTAssertEqual(
            noncanonicalStoredKey.validate(
                for: plan,
                policyRevision: 22,
                at: now.addingTimeInterval(1)
            ),
            .rejected(.domainSetMismatch)
        )
    }

    func testTransportRoundTripsOptionalPreparedSnapshot() throws {
        let plan = makePlan(blocked: ["blocked.example"], required: ["blocked.example"])
        var resolution = MacFilterDomainAddressResolution()
        resolution.record(["203.0.113.50"], forDomainSuffix: "blocked.example")
        let snapshot = MacFilterPreparedRetryGuardSnapshot(
            policyRevision: 23,
            plan: plan,
            resolution: resolution,
            preparedAt: now,
            validFor: 60
        )
        let policy = DesktopEnforcementPolicy(
            revision: 23,
            issuedAt: now,
            rules: [],
            weakeningAuthorizationExpiresAt: nil,
            lockdownSessions: nil
        )

        let withSnapshot = try DesktopPolicyConfigurationTransport.vendorConfiguration(
            for: policy,
            preparedRetryGuards: snapshot
        )
        XCTAssertEqual(
            DesktopPolicyConfigurationTransport.preparedRetryGuards(from: withSnapshot),
            snapshot
        )
        XCTAssertEqual(DesktopPolicyConfigurationTransport.policy(from: withSnapshot), policy)
        XCTAssertEqual(DesktopPolicyConfigurationTransport.revision(from: withSnapshot), 23)

        let withoutSnapshot = try DesktopPolicyConfigurationTransport.vendorConfiguration(for: policy)
        XCTAssertNil(DesktopPolicyConfigurationTransport.preparedRetryGuards(from: withoutSnapshot))

        var corruptSnapshot = withSnapshot
        corruptSnapshot["preparedRetryGuardsData"] = Data([0xFF])
        XCTAssertNil(DesktopPolicyConfigurationTransport.preparedRetryGuards(from: corruptSnapshot))
        XCTAssertEqual(DesktopPolicyConfigurationTransport.policy(from: corruptSnapshot), policy)
    }

    func testResolverCompletesEarlyAfterAllCanonicalLookupsSettle() {
        let completions = LockedBox<[MacFilterAsyncDNSResolutionResult]>([])
        let cancellations = LockedBox(0)
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "retry-guard-tests.success")
        let resolver = MacFilterAsyncDomainResolver(queue: queue) { _, callbackQueue, callback in
            let handle = MacFilterDNSLookupHandle {
                cancellations.withValue { $0 += 1 }
            }
            callbackQueue.async {
                callback(
                    MacFilterDNSLookupEvent(
                        address: "203.0.113.60",
                        isAddition: true,
                        moreComing: false,
                        errorCode: 0
                    )
                )
            }
            return handle
        }

        _ = resolver.resolve(
            domainSuffixes: ["WWW.Example.com.", "api.example.com", "example.com"],
            timeout: 0.25
        ) { result in
            completions.withValue { $0.append(result) }
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .success)
        let first = completions.value.first
        XCTAssertEqual(first?.requestedDomainSuffixes, ["api.example.com", "example.com"])
        XCTAssertEqual(first?.settledDomainSuffixes, ["api.example.com", "example.com"])
        XCTAssertEqual(first?.unresolvedDomainSuffixes, [])
        XCTAssertEqual(first?.didReachDeadline, false)
        XCTAssertEqual(first?.wasCancelled, false)
        XCTAssertEqual(
            first?.resolution.addressesByDomainSuffix,
            [
                "api.example.com": ["203.0.113.60"],
                "example.com": ["203.0.113.60"]
            ]
        )
        XCTAssertEqual(cancellations.value, 2)

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(completions.value.count, 1, "The dormant deadline must not complete twice")
    }

    func testResolverDeadlineCancelsHandlesAndCompletesExactlyOnce() {
        let completions = LockedBox<[MacFilterAsyncDNSResolutionResult]>([])
        let cancellations = LockedBox(0)
        let finished = DispatchSemaphore(value: 0)
        let resolver = MacFilterAsyncDomainResolver(
            queue: DispatchQueue(label: "retry-guard-tests.timeout")
        ) { _, _, _ in
            MacFilterDNSLookupHandle {
                cancellations.withValue { $0 += 1 }
            }
        }

        _ = resolver.resolve(
            domainSuffixes: ["one.example", "two.example"],
            timeout: 0.03
        ) { result in
            completions.withValue { $0.append(result) }
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completions.value.count, 1)
        XCTAssertEqual(completions.value.first?.didReachDeadline, true)
        XCTAssertEqual(completions.value.first?.wasCancelled, false)
        XCTAssertEqual(
            completions.value.first?.unresolvedDomainSuffixes,
            ["one.example", "two.example"]
        )
        XCTAssertEqual(cancellations.value, 2)

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(completions.value.count, 1)
    }

    func testResolverCancellationIsIdempotentAndCompletesExactlyOnce() {
        let completions = LockedBox<[MacFilterAsyncDNSResolutionResult]>([])
        let cancellations = LockedBox(0)
        let finished = DispatchSemaphore(value: 0)
        let resolver = MacFilterAsyncDomainResolver(
            queue: DispatchQueue(label: "retry-guard-tests.cancel")
        ) { _, _, _ in
            MacFilterDNSLookupHandle {
                cancellations.withValue { $0 += 1 }
            }
        }

        let task = resolver.resolve(domainSuffixes: ["cancel.example"], timeout: 0.05) { result in
            completions.withValue { $0.append(result) }
            finished.signal()
        }
        task.cancel()
        task.cancel()

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completions.value.count, 1)
        XCTAssertEqual(completions.value.first?.didReachDeadline, false)
        XCTAssertEqual(completions.value.first?.wasCancelled, true)
        XCTAssertEqual(cancellations.value, 1)

        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(completions.value.count, 1, "Cancellation and deadline must not race twice")
        XCTAssertEqual(cancellations.value, 1)
    }

    func testResolverIgnoresHostileLateCallbackAfterDeadline() throws {
        typealias Callback = @Sendable (MacFilterDNSLookupEvent) -> Void
        let callback = LockedBox<Callback?>(nil)
        let completions = LockedBox<[MacFilterAsyncDNSResolutionResult]>([])
        let cancellations = LockedBox(0)
        let starterRan = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let resolver = MacFilterAsyncDomainResolver(
            queue: DispatchQueue(label: "retry-guard-tests.late-callback")
        ) { _, _, suppliedCallback in
            callback.withValue { $0 = suppliedCallback }
            starterRan.signal()
            return MacFilterDNSLookupHandle {
                cancellations.withValue { $0 += 1 }
            }
        }

        _ = resolver.resolve(domainSuffixes: ["late.example"], timeout: 0.03) { result in
            completions.withValue { $0.append(result) }
            finished.signal()
        }
        XCTAssertEqual(starterRan.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)

        let lateCallback = try XCTUnwrap(callback.value)
        lateCallback(
            MacFilterDNSLookupEvent(
                address: "203.0.113.70",
                isAddition: true,
                moreComing: false,
                errorCode: 0
            )
        )
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(completions.value.count, 1)
        XCTAssertEqual(completions.value.first?.didReachDeadline, true)
        XCTAssertEqual(
            completions.value.first?.resolution.addressesByDomainSuffix,
            [:],
            "An event after teardown must not mutate the completed result"
        )
        XCTAssertEqual(cancellations.value, 1)
    }

    func testResolverOutlivesAReleasedOwnerUntilPromisedCompletion() {
        let completions = LockedBox(0)
        let finished = DispatchSemaphore(value: 0)
        var resolver: MacFilterAsyncDomainResolver? = MacFilterAsyncDomainResolver(
            queue: DispatchQueue(label: "retry-guard-tests.lifetime")
        ) { _, _, _ in
            MacFilterDNSLookupHandle {}
        }

        _ = resolver?.resolve(domainSuffixes: ["lifetime.example"], timeout: 0.03) { _ in
            completions.withValue { $0 += 1 }
            finished.signal()
        }
        resolver = nil

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completions.value, 1)
    }

    private func makePlan(
        blocked: [String],
        required: [String]
    ) -> MacFilterInterceptionPlan {
        MacFilterInterceptionPlan(
            mode: .domainRules,
            defaultAction: .allow,
            blockedDomainSuffixes: blocked,
            blockedDestinationPorts: MacFilterInterceptionPlan.dedicatedEncryptedDNSPorts,
            retryGuardRequiredDomainSuffixes: required
        )
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
