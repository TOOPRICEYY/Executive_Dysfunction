import XCTest

final class BlockPageRendererTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPageUsesRequestedReturnMessageAndNamesHost() {
        let html = BlockPageRenderer.html(
            host: "coinbase.com",
            status: .init(activeRuleCount: 1, activeDomainCount: 1, lockdownEndsAt: nil),
            now: now
        )

        XCTAssertTrue(html.contains("Holdfast has returned this time to you."))
        XCTAssertTrue(html.contains("coinbase.com"))
        XCTAssertTrue(html.contains("1 rule(s) active · 1 domain(s)"))
    }

    func testPageEscapesUntrustedHostText() {
        let html = BlockPageRenderer.html(
            host: "<script>alert(1)</script>",
            status: nil,
            now: now
        )

        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testPageShowsLockdownRemainingTime() {
        let html = BlockPageRenderer.html(
            host: "blocked.example",
            status: .init(
                activeRuleCount: 2,
                activeDomainCount: 3,
                lockdownEndsAt: now.addingTimeInterval(90 * 60)
            ),
            now: now
        )

        XCTAssertTrue(html.contains("Lockdown session — 1h 30m remaining"))
    }

    func testHostMappingsExistOnlyForFreshActiveConfiguredDomains() {
        let state = BlockPageFilterState(
            hasActiveWebRestrictions: true,
            updatedAt: now.addingTimeInterval(-5),
            blockedDomains: ["Coinbase.com", "not-configured.example"]
        )

        XCTAssertEqual(
            BlockPageHostPolicy.mappedDomains(
                state: state,
                configuredDomains: ["coinbase.com", "www.coinbase.com", "unrelated.example"],
                now: now
            ),
            ["coinbase.com", "www.coinbase.com"]
        )
        XCTAssertTrue(BlockPageHostPolicy.mappedDomains(
            state: .init(
                hasActiveWebRestrictions: false,
                updatedAt: now,
                blockedDomains: ["coinbase.com"]
            ),
            configuredDomains: ["coinbase.com"],
            now: now
        ).isEmpty)
        XCTAssertTrue(BlockPageHostPolicy.mappedDomains(
            state: .init(
                hasActiveWebRestrictions: true,
                updatedAt: now.addingTimeInterval(-13),
                blockedDomains: ["coinbase.com"]
            ),
            configuredDomains: ["coinbase.com"],
            now: now
        ).isEmpty)
    }

    func testManagedHostsBlockPreservesUnrelatedEntriesAndCanBeRemoved() throws {
        let original = """
        ##
        # Host Database
        ##
        127.0.0.1 localhost
        """
        let installed = try XCTUnwrap(BlockPageHostPolicy.replacingManagedBlock(
            in: original,
            domains: ["www.coinbase.com", "coinbase.com"]
        ))
        XCTAssertTrue(installed.contains("127.0.0.1 localhost"))
        XCTAssertTrue(installed.contains("127.0.0.1 coinbase.com"))
        XCTAssertTrue(installed.contains("127.0.0.1 www.coinbase.com"))

        let removed = try XCTUnwrap(BlockPageHostPolicy.replacingManagedBlock(
            in: installed,
            domains: []
        ))
        XCTAssertTrue(removed.contains("127.0.0.1 localhost"))
        XCTAssertFalse(removed.contains(BlockPageHostPolicy.markerBegin))
        XCTAssertFalse(removed.contains("coinbase.com"))
    }

    func testMalformedHostsMarkersAreNeverEdited() {
        let malformed = "127.0.0.1 localhost\n\(BlockPageHostPolicy.markerBegin)\n"
        XCTAssertNil(BlockPageHostPolicy.replacingManagedBlock(
            in: malformed,
            domains: ["coinbase.com"]
        ))
    }

    func testNestedAndInterleavedLegacyMarkersAreRefusedWithoutRemovingLines() {
        let begin = BlockPageHostPolicy.markerBegin
        let end = BlockPageHostPolicy.markerEnd
        let oldBegin = BlockPageHostPolicy.legacyMarkerBegin
        let oldEnd = BlockPageHostPolicy.legacyMarkerEnd
        for markers in [[begin, oldBegin, oldEnd, end], [begin, oldBegin, end, oldEnd]] {
            let contents = (["127.0.0.1 localhost"] + markers + ["192.0.2.1 personal.example"]).joined(separator: "\n")
            XCTAssertNil(BlockPageHostPolicy.replacingManagedBlock(in: contents, domains: []))
        }
    }

    func testLegacyBrandHostsBlockIsMigratedToHoldfastMarkers() throws {
        let legacy = """
        127.0.0.1 localhost
        \(BlockPageHostPolicy.legacyMarkerBegin)
        127.0.0.1 twitter.com
        \(BlockPageHostPolicy.legacyMarkerEnd)
        """

        let migrated = try XCTUnwrap(BlockPageHostPolicy.replacingManagedBlock(
            in: legacy,
            domains: ["coinbase.com"]
        ))

        XCTAssertFalse(migrated.contains(BlockPageHostPolicy.legacyMarkerBegin))
        XCTAssertTrue(migrated.contains(BlockPageHostPolicy.markerBegin))
        XCTAssertTrue(migrated.contains("127.0.0.1 coinbase.com"))
        XCTAssertFalse(migrated.contains("twitter.com"))
    }

    func testTemporaryPauseControlsAppearOnlyForSuppliedEligibleRule() {
        let rule = pauseRule(name: "Social <Focus>")
        let challenge = BlockPagePauseChallenge(
            token: String(repeating: "a", count: 43),
            host: "twitter.com",
            rule: rule,
            policyRevision: 17,
            passage: "type this exact deliberate confirmation passage",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let html = BlockPageRenderer.html(
            host: "twitter.com",
            status: nil,
            temporaryPauseOptions: [.init(rule: rule, challenge: challenge)],
            now: now
        )

        XCTAssertTrue(html.contains("method=\"post\" action=\"/temporary-pause\""))
        XCTAssertTrue(html.contains("value=\"600\" disabled>10 minutes"))
        XCTAssertTrue(html.contains("value=\"1800\" disabled>30 minutes"))
        XCTAssertTrue(html.contains("value=\"3600\" disabled>60 minutes"))
        XCTAssertTrue(html.contains("type this exact deliberate confirmation passage"))
        XCTAssertTrue(html.contains("Social &lt;Focus&gt;"))
        XCTAssertFalse(html.contains("value=\"7200\""))
        XCTAssertTrue(html.contains("name=\"intent\" value=\"consciousIntervention\" required"))
        XCTAssertTrue(html.contains("name=\"intent\" value=\"eDulgance\" required"))
        XCTAssertFalse(html.contains("required checked"))

        let unavailable = BlockPageRenderer.html(host: "twitter.com", status: nil, now: now)
        XCTAssertFalse(unavailable.contains("confirmation passage"))
        XCTAssertFalse(unavailable.contains("/temporary-pause"))
    }

    func testRuleMatcherUsesBlockListSuffixAndFortressExceptionSemantics() {
        let block = pauseRule(domains: ["example.com"])
        var fortress = pauseRule(name: "Fortress", domains: ["allowed.example"])
        fortress.enforcementMode = "fortressAllowList"

        XCTAssertEqual(
            BlockPageRuleMatcher.rulesBlocking(host: "www.sub.example.com", among: [block]).map(\.id),
            [block.id]
        )
        XCTAssertTrue(BlockPageRuleMatcher.rulesBlocking(
            host: "sub.allowed.example",
            among: [fortress]
        ).isEmpty)
        XCTAssertEqual(
            BlockPageRuleMatcher.rulesBlocking(host: "twitter.com", among: [fortress]).map(\.id),
            [fortress.id]
        )

        var forbidden = block
        forbidden.allowsTimeExtensions = false
        XCTAssertTrue(BlockPageRuleMatcher.eligibleRules(
            host: "example.com",
            among: [forbidden]
        ).isEmpty)
    }

    func testChallengeRequiresHostRuleRevisionFingerprintDurationAndPassage() throws {
        let rule = pauseRule(domains: ["twitter.com"])
        let token = String(repeating: "t", count: 43)
        let store = BlockPagePauseChallengeStore(
            tokenGenerator: { token },
            passageGenerator: { _ in "Type this passage exactly" }
        )
        let challenge = try store.issue(
            host: "www.twitter.com",
            rule: rule,
            policyRevision: 12,
            at: now
        ).get()

        XCTAssertEqual(challenge.host, "www.twitter.com")
        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "twitter.com",
                ruleID: rule.id,
                durationSeconds: 600,
                typedPassage: challenge.passage,
                currentRule: rule,
                currentPolicyRevision: 12,
                at: now
            ),
            .failure(.invalidHost)
        )
        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "www.twitter.com",
                ruleID: rule.id,
                durationSeconds: 601,
                typedPassage: challenge.passage,
                currentRule: rule,
                currentPolicyRevision: 12,
                at: now
            ),
            .failure(.unsupportedDuration)
        )
        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "www.twitter.com",
                ruleID: rule.id,
                durationSeconds: 600,
                typedPassage: "wrong words",
                currentRule: rule,
                currentPolicyRevision: 12,
                at: now
            ),
            .failure(.passageMismatch)
        )
        let pause = try store.redeem(
            token: token,
            host: "www.twitter.com",
            ruleID: rule.id,
            durationSeconds: 1_800,
            typedPassage: "  TYPE this passage\nexactly ",
            currentRule: rule,
            currentPolicyRevision: 12,
            at: now
        ).get()
        XCTAssertEqual(pause.ruleID, rule.id)
        XCTAssertEqual(pause.durationSeconds, 1_800)
        XCTAssertEqual(pause.expiresAt, now.addingTimeInterval(1_800))
        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "www.twitter.com",
                ruleID: rule.id,
                durationSeconds: 1_800,
                typedPassage: challenge.passage,
                currentRule: rule,
                currentPolicyRevision: 12,
                at: now
            ),
            .failure(.unavailable),
            "A successful challenge must be consumed exactly once"
        )
    }

    func testBrowserPassageHasThirtyMinutesButStillExpires() throws {
        let rule = pauseRule(domains: ["twitter.com"])
        for elapsed: TimeInterval in [29 * 60, 30 * 60] {
            let store = BlockPagePauseChallengeStore()
            let challenge = try store.issue(host: "twitter.com", rule: rule, policyRevision: 4, at: now).get()
            XCTAssertEqual(challenge.expiresAt.timeIntervalSince(now), 30 * 60)
            let result = store.redeem(token: challenge.token, host: "twitter.com", ruleID: rule.id,
                durationSeconds: 600, typedPassage: challenge.passage, currentRule: rule,
                currentPolicyRevision: 4, at: now.addingTimeInterval(elapsed))
            if elapsed < 30 * 60 {
                guard case .success = result else { return XCTFail("Passage must remain valid after five minutes") }
            } else {
                guard case .failure = result else { return XCTFail("Passage must expire at thirty minutes") }
            }
        }
    }

    func testChallengeIsConsumedWhenPolicyChanges() throws {
        let rule = pauseRule(domains: ["twitter.com"])
        let token = String(repeating: "p", count: 43)
        let store = BlockPagePauseChallengeStore(
            tokenGenerator: { token },
            passageGenerator: { _ in "deliberate words" }
        )
        _ = try store.issue(host: "twitter.com", rule: rule, policyRevision: 4, at: now).get()
        var changed = rule
        changed.policyFingerprint = String(repeating: "b", count: 64)

        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "twitter.com",
                ruleID: rule.id,
                durationSeconds: 600,
                typedPassage: "deliberate words",
                currentRule: changed,
                currentPolicyRevision: 4,
                at: now
            ),
            .failure(.policyChanged)
        )
        XCTAssertEqual(
            store.redeem(
                token: token,
                host: "twitter.com",
                ruleID: rule.id,
                durationSeconds: 600,
                typedPassage: "deliberate words",
                currentRule: rule,
                currentPolicyRevision: 4,
                at: now
            ),
            .failure(.unavailable)
        )
    }

    func testHTTPParserWaitsForCompleteBodyAndEnforcesSameOrigin() throws {
        let ruleID = UUID()
        let body = "challenge=abc&ruleID=\(ruleID.uuidString)&passage=typed+words&durationSeconds=600"
        let requestText = """
        POST /temporary-pause HTTP/1.1\r
        Host: twitter.com\r
        Origin: https://twitter.com\r
        Sec-Fetch-Site: same-origin\r
        Content-Type: application/x-www-form-urlencoded\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let data = Data(requestText.utf8)
        XCTAssertEqual(try BlockPageHTTPRequestParser.state(for: Data(data.dropLast())), .incomplete)
        XCTAssertEqual(try BlockPageHTTPRequestParser.state(for: data), .complete(length: data.count))

        let request = try BlockPageHTTPRequestParser.parse(data)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/temporary-pause")
        XCTAssertEqual(request.host, "twitter.com")
        XCTAssertTrue(request.hasSameOrigin(request.headers["origin"]))
        XCTAssertEqual(request.formValues?["passage"], "typed words")
        XCTAssertEqual(request.formValues?["durationSeconds"], "600")

        var crossSite = request
        crossSite.headers["origin"] = "https://attacker.example"
        crossSite.headers["sec-fetch-site"] = "cross-site"
        XCTAssertFalse(crossSite.hasSameOrigin(crossSite.headers["origin"]))
    }

    func testFormResponsePreservesOriginWithoutAllowingOpaqueOrCrossSiteRequests() throws {
        let response = try XCTUnwrap(String(data: BlockPageHTTPResponse.data(
            status: 403, reason: "Forbidden", body: "form"
        ), encoding: .utf8))
        XCTAssertTrue(response.contains("Referrer-Policy: same-origin\r\n"))
        XCTAssertFalse(response.contains("Referrer-Policy: no-referrer"))
        let request = BlockPageHTTPRequest(method: "POST", target: "/temporary-pause",
            headers: ["host": "twitter.com", "sec-fetch-site": "same-origin"], body: Data())
        XCTAssertTrue(request.hasSameOrigin("https://twitter.com"))
        XCTAssertFalse(request.hasSameOrigin("null"))
        XCTAssertFalse(request.hasSameOrigin(nil))
        XCTAssertFalse(request.hasSameOrigin("https://attacker.example"))
        var crossSite = request
        crossSite.headers["sec-fetch-site"] = "cross-site"
        XCTAssertFalse(crossSite.hasSameOrigin("https://twitter.com"))
    }

    func testTypingGuardUsesHashRestrictedScriptAndNoInlineEventHandlers() {
        let html = BlockPageRenderer.html(host: "twitter.com", status: nil)
        XCTAssertTrue(html.contains("<script>\(BlockPageTypingGuard.script)</script>"))
        XCTAssertTrue(BlockPageTypingGuard.script.contains("addEventListener('paste'"))
        XCTAssertTrue(BlockPageTypingGuard.script.contains("addEventListener('drop'"))
        XCTAssertTrue(BlockPageTypingGuard.script.contains("event.isTrusted"))
        let response = String(decoding: BlockPageHTTPResponse.data(status: 403, reason: "Forbidden", body: html), as: UTF8.self)
        XCTAssertTrue(response.contains("script-src \(BlockPageTypingGuard.cspSource)"))
        XCTAssertFalse(response.contains("script-src 'unsafe-inline'"))
    }

    func testHTTPParserRejectsChunkedOrUnboundedPost() {
        let chunked = Data("""
        POST /temporary-pause HTTP/1.1\r
        Host: twitter.com\r
        Transfer-Encoding: chunked\r
        \r
        0\r
        \r

        """.utf8)
        XCTAssertThrowsError(try BlockPageHTTPRequestParser.state(for: chunked)) {
            XCTAssertEqual($0 as? BlockPageHTTPRequestError, .unsupportedTransferEncoding)
        }

        let noLength = Data("""
        POST /temporary-pause HTTP/1.1\r
        Host: twitter.com\r
        \r

        """.utf8)
        XCTAssertThrowsError(try BlockPageHTTPRequestParser.state(for: noLength)) {
            XCTAssertEqual($0 as? BlockPageHTTPRequestError, .missingContentLength)
        }
    }

    func testPauseStoreWritesPrivateAtomicDocumentAndReplacesPerRule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-page-pause-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("temporary-pauses.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = BlockPageTemporaryPauseStore(fileURL: file, requiresRootOwnership: false)
        let rule = pauseRule()
        let first = temporaryPause(rule: rule, duration: 600, at: now)
        try store.grant(first, at: now, ruleName: "News", intent: .consciousIntervention)
        try store.grant(first, at: now, ruleName: "News", intent: .consciousIntervention)
        XCTAssertEqual(try store.bypassEvents(at: now).count, 1)

        XCTAssertEqual(try store.activePauses(at: now), [first])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let replacement = temporaryPause(rule: rule, duration: 3_600, at: now.addingTimeInterval(10))
        try store.grant(replacement, at: now.addingTimeInterval(10), ruleName: "News", intent: .eDulgance)
        XCTAssertEqual(try store.activePauses(at: now.addingTimeInterval(10)), [replacement])
        XCTAssertTrue(try store.activePauses(at: replacement.expiresAt).isEmpty)
        try store.pruneExpired(at: replacement.expiresAt)
        XCTAssertTrue(try store.activePauses(at: replacement.expiresAt).isEmpty)
        let history = try store.bypassEvents(at: replacement.expiresAt)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.intent), [.consciousIntervention, .eDulgance])
        XCTAssertEqual(history.map(\.groupName), ["News", "News"])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            BlockPageTemporaryPauseDocument(pauses: [replacement]))) as? [String: Any])
        fields["bypassHistory"] = "unsupported report data"
        let decoded = try JSONDecoder().decode(BlockPageTemporaryPauseDocument.self,
            from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(decoded.pauses, [replacement], "Reporting data must not revoke a valid pause")
    }

    func testBackoffGroupsExplainNativeAllowanceAndCannotIssueBrowserChallenge() {
        var rule = pauseRule(name: "News <focus>")
        rule.requiresAppForTemporaryAccess = true
        XCTAssertTrue(BlockPageRuleMatcher.eligibleRules(host: "twitter.com", among: [rule]).isEmpty)
        let result = BlockPagePauseChallengeStore().issue(host: "twitter.com", rule: rule, policyRevision: 1, at: now)
        guard case .failure(.invalidRule) = result else { return XCTFail("Browser must not evade native backoff") }
        let html = BlockPageRenderer.html(host: "twitter.com", status: nil, appRequiredRules: [rule.name])
        XCTAssertTrue(html.contains("News &lt;focus&gt;"))
        XCTAssertTrue(html.contains("Open Holdfast"))
        XCTAssertFalse(html.contains("action=\"/temporary-pause\""))
    }

    private func pauseRule(
        name: String = "Focus",
        domains: [String] = ["twitter.com"]
    ) -> BlockPageRuleDescriptor {
        BlockPageRuleDescriptor(
            id: UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!,
            name: name,
            enforcementMode: "blockList",
            domains: domains,
            allowsTimeExtensions: true,
            passageWordCount: 40,
            policyFingerprint: String(repeating: "a", count: 64)
        )
    }

    private func temporaryPause(
        rule: BlockPageRuleDescriptor,
        duration: Int,
        at date: Date
    ) -> BlockPageTemporaryPause {
        BlockPageTemporaryPause(
            ruleID: rule.id,
            policyRevision: 8,
            policyFingerprint: rule.policyFingerprint,
            grantedAt: date,
            expiresAt: date.addingTimeInterval(Double(duration)),
            durationSeconds: duration,
            requestID: UUID()
        )
    }
}
