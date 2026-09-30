import XCTest
// The desktop decision layer is compiled directly into this hostless test
// bundle; see project.yml. Importing the app module would drag in
// NetworkExtension and a live filter configuration.

/// The readout exists to make silent failures loud, so its job is to be
/// pessimistic: anything short of "the filter says it is on the current
/// revision" must not read as healthy.
final class FilterEnforcementStatusTests: XCTestCase {
    func testMalformedBypassHistoryCannotBreakEnforcementStatus() throws {
        let original = status(revision: 9, at: now, domains: ["a.example"])
        let encoder = JSONEncoder()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        fields["browserBypassEvents"] = ["unsupportedFutureShape": true]
        let decoded = try JSONDecoder().decode(FilterEnforcementStatus.self,
            from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(decoded.revision, original.revision)
        XCTAssertEqual(decoded.blockPageRules, original.blockPageRules)
        XCTAssertNil(decoded.browserBypassEvents)
    }
    func testLimitedProtectionIsExplicitAndBecomesHealthyAfterDNSRecovery() {
        var value = status(revision: 8, at: now, domains: ["good.example", "missing.example"])
        value.macFilterSettings = MacFilterSettingsStatus(isReady: false, planMode: "domainRules",
            appliedPolicyRevision: 8, requiredRetryGuardDomainCount: 2, coveredRetryGuardDomainCount: 1,
            coveredRetryGuardDomainSuffixes: ["good.example"], correlatedAddressCount: 1,
            isFiltering: true, missingRetryGuardDomainSuffixes: ["missing.example"])
        let health = FilterEnforcementSummary.health(published: 8, status: value, now: now)
        XCTAssertEqual(health, .limited(revision: 8, missing: ["missing.example"]))
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("Hostname blocking is active"))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("missing.example"))
        value.macFilterSettings?.isReady = true
        value.macFilterSettings?.missingRetryGuardDomainSuffixes = []
        value.macFilterSettings?.coveredRetryGuardDomainCount = 2
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(FilterEnforcementSummary.health(published: 8, status: value, now: now)))
        XCTAssertEqual(FilterEnforcementSummary.health(published: 9, status: value, now: now), .behind(published: 9, enforcing: 8))
    }
    func testBehindRevisionIsReportedAsUnhealthy() {
        // Exactly the live failure: the app published a policy the filter
        // rejected, so newly added domains never blocked.
        let health = FilterEnforcementSummary.health(
            published: 183,
            status: status(revision: 104, at: now),
            now: now
        )
        XCTAssertEqual(health, .behind(published: 183, enforcing: 104))
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("183"))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("104"))
    }

    func testMissingReportIsUnhealthy() {
        let health = FilterEnforcementSummary.health(published: 5, status: nil)
        XCTAssertEqual(health, .notReporting)
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    func testStaleHeartbeatIsUnhealthy() {
        let old = now.addingTimeInterval(-(FilterEnforcementSummary.staleAfter + 30))
        let health = FilterEnforcementSummary.health(
            published: 10,
            status: status(revision: 10, at: old),
            now: now
        )
        guard case .stale = health else { return XCTFail("Expected stale, got \(health)") }
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(
            FilterEnforcementSummary.description(for: health).contains("not confirmed by a fresh heartbeat")
        )
    }

    /// A stopped filter must not look healthy just because its last report
    /// happened to carry the current revision.
    func testStalenessOutranksAMatchingRevision() {
        let old = now.addingTimeInterval(-(FilterEnforcementSummary.staleAfter + 1))
        let health = FilterEnforcementSummary.health(
            published: 42,
            status: status(revision: 42, at: old),
            now: now
        )
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    func testCurrentRevisionWithActiveRuleIsHealthy() {
        let health = FilterEnforcementSummary.health(
            published: 183,
            status: status(revision: 183, at: now, domains: ["a.example", "b.example"]),
            now: now
        )
        XCTAssertEqual(health, .enforcing(revision: 183, domains: 2, rules: 1))
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
    }

    /// A filter ahead of this app's counter is fine; the iPhone can publish too.
    func testFilterAheadOfPublishedRevisionIsHealthy() {
        let health = FilterEnforcementSummary.health(
            published: 100,
            status: status(revision: 120, at: now, domains: ["a.example"]),
            now: now
        )
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
    }

    func testIdleIsHealthyButSaysNoRuleIsInForce() {
        let health = FilterEnforcementSummary.health(
            published: 7,
            status: status(revision: 7, at: now, domains: [], windowActive: false),
            now: now
        )
        XCTAssertEqual(health, .idle(revision: 7))
        XCTAssertTrue(FilterEnforcementSummary.isHealthy(health))
        XCTAssertTrue(FilterEnforcementSummary.description(for: health).contains("No website rule"))
    }

    func testPendingMacSettingsCannotAppearHealthyOrEnforcing() {
        var pending = status(revision: 8, at: now, domains: ["coinbase.com"])
        pending.hasActiveWebRestrictions = false
        pending.activeRuleCount = 0
        pending.activeDomainCount = 0
        pending.blockedDomains = nil
        pending.macFilterSettings = MacFilterSettingsStatus(
            isReady: false,
            planMode: "domainRules",
            appliedPolicyRevision: 7,
            requiredRetryGuardDomainCount: 1,
            coveredRetryGuardDomainCount: 0,
            coveredRetryGuardDomainSuffixes: [],
            correlatedAddressCount: 0
        )

        let health = FilterEnforcementSummary.health(
            published: 8,
            status: pending,
            now: now
        )
        XCTAssertEqual(health, .applying(revision: 8))
        XCTAssertFalse(FilterEnforcementSummary.isHealthy(health))
    }

    func testStatusCountsOnlyActiveRulesAndDomains() {
        let policy = DesktopEnforcementPolicy(
            revision: 3,
            issuedAt: now,
            rules: [
                rule(domains: ["live.example"], windowActive: true),
                rule(domains: ["dormant.example"], windowActive: false)
            ]
        )
        let snapshot = FilterEnforcementStatus(policy: policy, at: now)
        XCTAssertEqual(snapshot.ruleCount, 2)
        XCTAssertEqual(snapshot.activeRuleCount, 1)
        XCTAssertEqual(snapshot.activeDomainCount, 1)
        XCTAssertTrue(snapshot.hasActiveWebRestrictions)
    }

    func testStatusPublishesOnlyActiveWebRulesAndTheirPauseOptIn() throws {
        var eligible = rule(domains: ["live.example"], windowActive: true)
        eligible.name = "Social sites"
        eligible.lockdown.allowsTimeExtensions = true
        eligible.lockdown.passageWordCount = 57
        let dormant = rule(domains: ["dormant.example"], windowActive: false)
        let policy = DesktopEnforcementPolicy(
            revision: 17,
            issuedAt: now,
            rules: [eligible, dormant]
        )

        let descriptor = try XCTUnwrap(
            FilterEnforcementStatus(policy: policy, at: now).blockPageRules?.first
        )
        XCTAssertEqual(descriptor.id, eligible.id)
        XCTAssertEqual(descriptor.name, "Social sites")
        XCTAssertEqual(descriptor.enforcementMode, "blockList")
        XCTAssertEqual(descriptor.domains, ["live.example"])
        XCTAssertTrue(descriptor.allowsTimeExtensions)
        XCTAssertEqual(descriptor.passageWordCount, 57)
        XCTAssertEqual(
            descriptor.policyFingerprint,
            policy.temporaryPauseFingerprint(for: eligible.id)
        )
    }

    func testPublishedRuleDescriptorDecodesInBlockPageServerSchema() throws {
        struct ServerEnvelope: Decodable {
            var blockPageRules: [BlockPageRuleDescriptor]?
        }
        var eligible = rule(domains: ["live.example"], windowActive: true)
        eligible.lockdown.allowsTimeExtensions = true
        let policy = DesktopEnforcementPolicy(
            revision: 18,
            issuedAt: now,
            rules: [eligible]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoded = try JSONDecoder().decode(
            ServerEnvelope.self,
            from: encoder.encode(FilterEnforcementStatus(policy: policy, at: now))
        )

        XCTAssertEqual(decoded.blockPageRules?.first?.id, eligible.id)
        XCTAssertEqual(decoded.blockPageRules?.first?.policyFingerprint,
                       policy.temporaryPauseFingerprint(for: eligible.id))
    }

    func testStatusSurvivesEncodingRoundTrip() throws {
        var original = status(revision: 9, at: now, domains: ["a.example"])
        original.macFilterSettings = MacFilterSettingsStatus(
            isReady: true,
            planMode: "domainRules",
            appliedPolicyRevision: 9,
            requiredRetryGuardDomainCount: 1,
            coveredRetryGuardDomainCount: 1,
            coveredRetryGuardDomainSuffixes: ["a.example"],
            correlatedAddressCount: 2
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(
            FilterEnforcementStatus.self,
            from: try encoder.encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Helpers

    private var now: Date {
        DateComponents(calendar: .current, year: 2025, month: 1, day: 6, hour: 12).date!
    }

    private func status(
        revision: UInt64,
        at date: Date,
        domains: Set<String> = ["a.example"],
        windowActive: Bool = true
    ) -> FilterEnforcementStatus {
        FilterEnforcementStatus(
            policy: DesktopEnforcementPolicy(
                revision: revision,
                issuedAt: date,
                rules: [rule(domains: domains, windowActive: windowActive)]
            ),
            at: date
        )
    }

    private func rule(domains: Set<String>, windowActive: Bool) -> DesktopEnforcementRule {
        DesktopEnforcementRule(
            id: UUID(),
            name: "Test",
            isEnabled: true,
            enforcementMode: .blockList,
            windows: [
                windowActive
                    ? DesktopTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1_439)
                    : DesktopTimeWindow(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 0, endMinutes: 1)
            ],
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

final class WebFilterDiagnosticsTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    func testDropPressureWarningRoundTripsWithoutReportingAFailOpen() throws {
        let diagnostics = WebFilterDiagnostics(providerStartedAt: started)
        let governor = WebFilterFailOpenGovernor(threshold: 1, now: started)
        XCTAssertTrue(governor.record(.unidentified, at: started))
        diagnostics.recordDropPressureWarning(revision: 42, at: started)
        let snapshot = diagnostics.snapshot(
            policyRevision: 42, heartbeatSequence: 1,
            failOpen: governor.state(at: started), at: started
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WebFilterDiagnosticsSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.dropPressureWarningActive, true)
        XCTAssertEqual(decoded.count(.dropPressureWarnings), 1)
        XCTAssertEqual(decoded.count(.failOpenTrips), 0)
        XCTAssertFalse(decoded.failOpenActive)
        XCTAssertNil(decoded.failOpenUntil)
        XCTAssertEqual(decoded.failOpenTrips, 0)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "dropPressureWarningActive")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(WebFilterDiagnosticsSnapshot.self, from: oldData).dropPressureWarningActive)
    }

    func testDecisionCountersExplainTheTerminalReleasePath() {
        let diagnostics = WebFilterDiagnostics(
            sessionID: "session-test",
            providerStartedAt: started,
            providerVersion: "1.0",
            providerBuild: "28"
        )
        let descriptor = WebFilterFlowDescriptor(
            hostname: nil,
            remoteAddress: "203.0.113.10",
            remotePort: 443,
            isTCP: true
        )
        diagnostics.recordDecision(
            stage: .newFlow,
            outcome: .inspect(16_640, reason: .unnamedInspectable),
            descriptor: descriptor,
            revision: 42,
            at: started
        )
        diagnostics.inspectionStarted(at: started)
        diagnostics.recordDecision(
            stage: .outboundData,
            outcome: .inspect(1_831, reason: .tlsIncomplete),
            descriptor: descriptor,
            revision: 42,
            bytes: 1_420,
            accumulatedBytes: 1_420,
            at: started.addingTimeInterval(0.1)
        )
        diagnostics.recordDecision(
            stage: .outboundComplete,
            outcome: .allow(.completionUnclassifiedAllowed),
            descriptor: descriptor,
            revision: 42,
            at: started.addingTimeInterval(0.2)
        )
        diagnostics.recordUnclassifiedCompletion(
            descriptor: descriptor,
            revision: 42,
            bytes: 1_420,
            continuations: 1,
            reason: .completionUnclassifiedAllowed,
            at: started.addingTimeInterval(0.2)
        )
        diagnostics.inspectionFinished(at: started.addingTimeInterval(0.2))

        let snapshot = diagnostics.snapshot(
            policyRevision: 42,
            heartbeatSequence: 7,
            failOpen: .init(
                isOpen: false,
                openUntil: nil,
                trips: 0,
                unidentifiedDropsInWindow: 0
            ),
            at: started.addingTimeInterval(1)
        )
        XCTAssertEqual(snapshot.sessionID, "session-test")
        XCTAssertEqual(snapshot.providerBuild, "28")
        XCTAssertEqual(snapshot.heartbeatSequence, 7)
        XCTAssertEqual(snapshot.count(.newFlows), 1)
        XCTAssertEqual(snapshot.count(.newFlowInspected), 1)
        XCTAssertEqual(snapshot.count(.outboundCallbacks), 1)
        XCTAssertEqual(snapshot.count(.outboundBytes), 1_420)
        XCTAssertEqual(
            snapshot.count(WebFilterDiagnosticCounter.completionUnclassifiedAllowed),
            1
        )
        XCTAssertEqual(snapshot.count(WebFilterDecisionReason.completionUnclassifiedAllowed), 1)
        XCTAssertEqual(snapshot.count(WebFilterDecisionReason.tlsIncomplete), 1)
        XCTAssertEqual(snapshot.currentInspections, 0)
        XCTAssertEqual(snapshot.peakInspections, 1)
        XCTAssertEqual(snapshot.maximumInspectedBytes, 1_420)
        XCTAssertEqual(snapshot.recentAnomalies.last?.code, .outboundCompletedUnclassified)
    }

    func testDiagnosticsNeverSerializeDestinationOrApplicationIdentity() throws {
        let diagnostics = WebFilterDiagnostics(
            sessionID: "privacy-test",
            providerStartedAt: started,
            providerVersion: "1.0",
            providerBuild: "28"
        )
        let descriptor = WebFilterFlowDescriptor(
            hostname: "private-host.example",
            remoteAddress: "192.0.2.99",
            remotePort: 443,
            isTCP: true,
            sourceSigningIdentifier: "com.private.browser",
            sourceExecutablePath: "/Users/private/SecretBrowser"
        )
        diagnostics.recordDecision(
            stage: .newFlow,
            outcome: .drop(.named, reason: .knownHostBlocked),
            descriptor: descriptor,
            revision: 9,
            at: started
        )
        diagnostics.recordInvalidSequence(
            .offsetGap,
            descriptor: descriptor,
            revision: 9,
            offset: 128,
            bytes: 512,
            at: started
        )
        let snapshot = diagnostics.snapshot(
            policyRevision: 9,
            heartbeatSequence: 1,
            failOpen: .init(
                isOpen: false,
                openUntil: nil,
                trips: 0,
                unidentifiedDropsInWindow: 0
            ),
            at: started
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-host.example"))
        XCTAssertFalse(text.contains("192.0.2.99"))
        XCTAssertFalse(text.contains("com.private.browser"))
        XCTAssertFalse(text.contains("SecretBrowser"))
        XCTAssertTrue(text.contains(WebFilterDecisionReason.knownHostBlocked.rawValue))
    }

    func testSourceIdentityFastPathIsCountedWithoutRecordingAnIdentity() throws {
        let diagnostics = WebFilterDiagnostics(
            sessionID: "identity-fast-path",
            providerStartedAt: started,
            providerVersion: "1.0",
            providerBuild: "30"
        )
        diagnostics.recordSourceIdentityResolution(requested: false, revision: 10, at: started)
        diagnostics.recordSourceIdentityResolution(requested: true, revision: 10, at: started)
        let snapshot = diagnostics.snapshot(
            policyRevision: 10,
            heartbeatSequence: 1,
            failOpen: .init(
                isOpen: false,
                openUntil: nil,
                trips: 0,
                unidentifiedDropsInWindow: 0
            ),
            at: started
        )
        XCTAssertEqual(snapshot.count(.sourceIdentityResolutionSkipped), 1)
        XCTAssertEqual(snapshot.count(.sourceIdentityResolutionRequested), 1)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("com."))
        XCTAssertFalse(encoded.contains("/Applications"))
    }

    func testRecentAnomaliesAreBounded() {
        let diagnostics = WebFilterDiagnostics(
            sessionID: "bounded-test",
            providerStartedAt: started,
            providerVersion: "1.0",
            providerBuild: "28"
        )
        let descriptor = WebFilterFlowDescriptor(remotePort: 443)
        for index in 0..<(WebFilterDiagnostics.maximumRecentAnomalies + 9) {
            diagnostics.recordInvalidSequence(
                .conflictingOverlap,
                descriptor: descriptor,
                revision: 1,
                offset: index,
                bytes: index,
                at: started.addingTimeInterval(Double(index))
            )
        }
        let snapshot = diagnostics.snapshot(
            policyRevision: 1,
            heartbeatSequence: 1,
            failOpen: .init(
                isOpen: false,
                openUntil: nil,
                trips: 0,
                unidentifiedDropsInWindow: 0
            )
        )
        XCTAssertEqual(snapshot.recentAnomalies.count, WebFilterDiagnostics.maximumRecentAnomalies)
        XCTAssertEqual(snapshot.recentAnomalies.first?.bytes, 9)
        XCTAssertEqual(
            snapshot.count(.invalidSequenceReleases),
            UInt64(WebFilterDiagnostics.maximumRecentAnomalies + 9)
        )
    }

    func testIdleHeartbeatDoesNotPretendAProviderEventOccurred() {
        let diagnostics = WebFilterDiagnostics(
            sessionID: "idle-test",
            providerStartedAt: started,
            providerVersion: "1.0",
            providerBuild: "28"
        )
        let failOpen = WebFilterFailOpenState(
            isOpen: false,
            openUntil: nil,
            trips: 0,
            unidentifiedDropsInWindow: 0
        )
        let initial = diagnostics.snapshot(
            policyRevision: 42,
            heartbeatSequence: 1,
            failOpen: failOpen,
            at: started
        )
        let later = diagnostics.snapshot(
            policyRevision: 42,
            heartbeatSequence: 2,
            failOpen: failOpen,
            at: started.addingTimeInterval(300)
        )

        XCTAssertEqual(later.lastEventAt, initial.lastEventAt)
        XCTAssertNil(later.lastFlowAt)
    }

    func testLegacyStatusWithoutDiagnosticsStillDecodes() throws {
        let json = """
        {
          "revision": 17,
          "ruleCount": 2,
          "activeRuleCount": 1,
          "activeDomainCount": 3,
          "hasActiveWebRestrictions": true,
          "updatedAt": 1700000000000
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let status = try decoder.decode(
            FilterEnforcementStatus.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(status.revision, 17)
        XCTAssertNil(status.diagnostics)
        XCTAssertNil(status.previousDiagnostics)
    }

    func testTypedStatusReadDistinguishesMissingAndCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("filter-status.json")

        XCTAssertEqual(FilterStatusStore.readResult(from: file), .missing)
        try Data("not-json".utf8).write(to: file)
        XCTAssertEqual(FilterStatusStore.readResult(from: file), .corrupt)
    }

    func testFutureDiagnosticsSchemaIsReportedBeforeTypedPayloadDecode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("filter-status.json")
        let json = """
        {
          "revision": 71,
          "ruleCount": 2,
          "activeRuleCount": 1,
          "activeDomainCount": 3,
          "hasActiveWebRestrictions": true,
          "updatedAt": 1700000000000,
          "previousDiagnostics": {
            "schemaVersion": 999,
            "futureRequiredField": {"futureEnum": "unknown-to-this-build"}
          }
        }
        """
        try Data(json.utf8).write(to: file)

        guard case let .unsupportedDiagnosticsSchema(status, schema) =
                FilterStatusStore.readResult(from: file) else {
            return XCTFail("Expected an unsupported diagnostics schema result")
        }
        XCTAssertEqual(schema, 999)
        XCTAssertEqual(status.revision, 71)
        XCTAssertNil(status.diagnostics)
        XCTAssertNil(status.previousDiagnostics)
    }

    func testStatusPublisherHeartbeatsWithoutAnyFlowCallbacks() {
        let capture = FilterStatusCapture()
        let providerStartedAt = started
        let wroteTwice = expectation(description: "initial status plus timer heartbeat")
        wroteTwice.expectedFulfillmentCount = 2
        wroteTwice.assertForOverFulfill = false
        let publisher = FilterStatusPublisher(
            heartbeat: 0.05,
            writer: { status in
                capture.append(status)
                wroteTwice.fulfill()
            },
            previousDiagnosticsReader: { nil }
        )
        publisher.start(initialRevision: 0) { sequence, previous, now in
            FilterEnforcementStatus(
                policy: .empty,
                at: now,
                diagnostics: WebFilterDiagnosticsSnapshot(
                    schemaVersion: WebFilterDiagnosticsSnapshot.currentSchemaVersion,
                    sessionID: "heartbeat-test",
                    providerStartedAt: providerStartedAt,
                    providerVersion: "1.0",
                    providerBuild: "28",
                    lastEventAt: now,
                    lastFlowAt: nil,
                    policyRevision: 0,
                    heartbeatSequence: sequence,
                    counters: [:],
                    decisionReasons: [:],
                    currentInspections: 0,
                    peakInspections: 0,
                    maximumInspectedBytes: 0,
                    failOpenActive: false,
                    failOpenUntil: nil,
                    failOpenTrips: 0,
                    unidentifiedDropsInWindow: 0,
                    recentAnomalies: []
                ),
                previousDiagnostics: previous
            )
        }
        wait(for: [wroteTwice], timeout: 1)
        publisher.stop()

        let sequences = capture.statuses.compactMap(\.diagnostics?.heartbeatSequence)
        XCTAssertGreaterThanOrEqual(sequences.count, 2)
        XCTAssertEqual(Array(sequences.prefix(2)), [1, 2])
    }

    func testStatusPublisherSerializesConcurrentRevisionWrites() {
        let capture = FilterStatusCapture()
        let writes = expectation(description: "initial plus revision writes")
        writes.expectedFulfillmentCount = 33
        let publisher = FilterStatusPublisher(
            heartbeat: 60,
            writer: { status in
                capture.append(status)
                writes.fulfill()
            },
            previousDiagnosticsReader: { nil }
        )
        let providerStartedAt = started
        publisher.start(initialRevision: 0) { sequence, previous, now in
            Self.statusForPublisherTest(
                sequence: sequence,
                sessionID: "serialization-test",
                previous: previous,
                now: now,
                providerStartedAt: providerStartedAt
            )
        }

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            publisher.recordIfRevisionChanged(UInt64(index + 1))
        }
        wait(for: [writes], timeout: 2)
        publisher.stop()

        let sequences = capture.statuses.compactMap(\.diagnostics?.heartbeatSequence)
        XCTAssertEqual(sequences.count, 33)
        for (index, sequence) in sequences.enumerated() {
            XCTAssertEqual(sequence, UInt64(index + 1))
        }
    }

    func testStatusPublisherCannotWriteAfterStopReturns() {
        let capture = FilterStatusCapture()
        let publisher = FilterStatusPublisher(
            heartbeat: 0.01,
            writer: { capture.append($0) },
            previousDiagnosticsReader: { nil }
        )
        let providerStartedAt = started
        publisher.start(initialRevision: 0) { sequence, previous, now in
            Self.statusForPublisherTest(
                sequence: sequence,
                sessionID: "stop-test",
                previous: previous,
                now: now,
                providerStartedAt: providerStartedAt
            )
        }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            publisher.recordIfRevisionChanged(UInt64(index + 1))
        }
        publisher.stop()
        let countAfterStop = capture.statuses.count

        Thread.sleep(forTimeInterval: 0.08)
        publisher.recordIfRevisionChanged(100)
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(capture.statuses.count, countAfterStop)
    }

    func testStatusPublisherPublishNowFinishesTransitionWriteBeforeReturning() {
        let capture = FilterStatusCapture()
        let publisher = FilterStatusPublisher(
            heartbeat: 60,
            writer: { capture.append($0) },
            previousDiagnosticsReader: { nil }
        )
        let providerStartedAt = started
        publisher.start(initialRevision: 0) { sequence, previous, now in
            Self.statusForPublisherTest(
                sequence: sequence,
                sessionID: "transition-test",
                previous: previous,
                now: now,
                providerStartedAt: providerStartedAt
            )
        }
        XCTAssertEqual(capture.statuses.count, 1)

        publisher.publishNow(reason: "settings-pending")
        XCTAssertEqual(
            capture.statuses.compactMap(\.diagnostics?.heartbeatSequence),
            [1, 2],
            "The pending/ready transition write must be durable before publishNow returns"
        )
        publisher.stop()
    }

    private static func statusForPublisherTest(
        sequence: UInt64,
        sessionID: String,
        previous: WebFilterDiagnosticsSnapshot?,
        now: Date,
        providerStartedAt: Date
    ) -> FilterEnforcementStatus {
        FilterEnforcementStatus(
            policy: .empty,
            at: now,
            diagnostics: WebFilterDiagnosticsSnapshot(
                schemaVersion: WebFilterDiagnosticsSnapshot.currentSchemaVersion,
                sessionID: sessionID,
                providerStartedAt: providerStartedAt,
                providerVersion: "1.0",
                providerBuild: "28",
                lastEventAt: providerStartedAt,
                lastFlowAt: nil,
                policyRevision: 0,
                heartbeatSequence: sequence,
                counters: [:],
                decisionReasons: [:],
                currentInspections: 0,
                peakInspections: 0,
                maximumInspectedBytes: 0,
                failOpenActive: false,
                failOpenUntil: nil,
                failOpenTrips: 0,
                unidentifiedDropsInWindow: 0,
                recentAnomalies: []
            ),
            previousDiagnostics: previous
        )
    }
}

private final class FilterStatusCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [FilterEnforcementStatus] = []

    var statuses: [FilterEnforcementStatus] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func append(_ status: FilterEnforcementStatus) {
        lock.lock()
        captured.append(status)
        lock.unlock()
    }
}
