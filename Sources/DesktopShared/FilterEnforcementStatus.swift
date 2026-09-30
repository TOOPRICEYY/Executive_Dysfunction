import Foundation

/// The minimum rule detail the loopback block-page daemon needs in order to
/// prove that a requested hostname is blocked by one exact active rule. This
/// file is intentionally public-on-disk, so it never contains selection tokens,
/// executable rules, authentication material, or the generated passage.
struct BlockPageRuleStatus: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var enforcementMode: String
    var domains: [String]
    var allowsTimeExtensions: Bool
    var passageWordCount: Int
    var policyFingerprint: String
    var requiresAppForTemporaryAccess: Bool? = nil
}

/// Structured proof that the macOS provider has finished applying the exact
/// system-rule plan represented by this status record. Optional on the parent
/// status so older app/extension builds remain mutually readable during an
/// upgrade.
struct MacFilterSettingsStatus: Codable, Equatable {
    var isReady: Bool
    var planMode: String
    var appliedPolicyRevision: UInt64?
    var requiredRetryGuardDomainCount: Int
    var coveredRetryGuardDomainCount: Int
    var coveredRetryGuardDomainSuffixes: [String]
    var correlatedAddressCount: Int
    /// Named rules are installed, even if IP retry coverage is still partial.
    var isFiltering: Bool? = nil
    var missingRetryGuardDomainSuffixes: [String]? = nil
}

/// What the running filter believes it is enforcing, right now.
///
/// Every silent failure this project has hit looked identical from the outside:
/// rules that quietly did nothing. A stale policy, a rejected revision and a
/// filter that never started are indistinguishable unless the filter says what
/// it is actually using. This is that statement.
struct FilterEnforcementStatus: Codable, Equatable {
    var revision: UInt64
    var ruleCount: Int
    var activeRuleCount: Int
    var activeDomainCount: Int
    var hasActiveWebRestrictions: Bool
    var updatedAt: Date
    /// Domains currently blocked, so the block page can confirm it is naming a
    /// domain the filter really refuses rather than guessing from the request.
    var blockedDomains: [String]?
    /// Active web rules used to render an exact-rule temporary-pause form.
    /// Optional so older providers and controlling apps remain compatible.
    var blockPageRules: [BlockPageRuleStatus]?
    var temporaryAllowanceExpirations: [UUID: Date]?
    @BypassEventBuffer var browserBypassEvents: [BypassEvent]? = nil
    /// When the longest-running lockdown session ends, if one is running.
    var lockdownEndsAt: Date?
    /// Redacted counters for the current provider process. Optional so an app
    /// built against this schema can still read status written by older
    /// extensions during an upgrade.
    var diagnostics: WebFilterDiagnosticsSnapshot?
    /// Last snapshot written by the previous provider process. Keeping one
    /// bounded predecessor makes a restart visible even after the current
    /// heartbeat replaces the old status file.
    var previousDiagnostics: WebFilterDiagnosticsSnapshot?
    /// macOS-only applied-settings readiness and retry-guard coverage.
    var macFilterSettings: MacFilterSettingsStatus?

    init(
        policy: DesktopEnforcementPolicy,
        at date: Date = Date(),
        diagnostics: WebFilterDiagnosticsSnapshot? = nil,
        previousDiagnostics: WebFilterDiagnosticsSnapshot? = nil
    ) {
        let active = policy.activeRules(at: date)
        let forced = policy.sessionForcedRuleIDs(at: date)
        revision = policy.revision
        ruleCount = policy.rules.count
        activeRuleCount = Set(active.map(\.id)).count
        let domains = Set(active.filter { $0.enforcementMode == .blockList }.flatMap(\.domains))
        activeDomainCount = Set(active.flatMap(\.domains)).count
        hasActiveWebRestrictions = policy.hasActiveWebRestrictions(at: date)
        updatedAt = date
        blockedDomains = domains.isEmpty ? nil : domains.sorted()
        let pageRules = active.compactMap { rule -> BlockPageRuleStatus? in
            guard rule.enforcementMode == .fortressAllowList || !rule.domains.isEmpty else {
                return nil
            }
            return BlockPageRuleStatus(
                id: rule.id,
                name: rule.name,
                enforcementMode: rule.enforcementMode.rawValue,
                domains: rule.domains.sorted(),
                allowsTimeExtensions: !forced.contains(rule.id) && rule.lockdown.allowsTimeExtensions && !rule.lockdown.needsNativeTemporaryAccess,
                passageWordCount: rule.lockdown.effectiveTemporaryAccessPassageWordCount,
                policyFingerprint: policy.temporaryPauseFingerprint(for: rule.id),
                requiresAppForTemporaryAccess: !forced.contains(rule.id) && rule.lockdown.permitsAnyTemporaryAccess && rule.lockdown.needsNativeTemporaryAccess
            )
        }
        blockPageRules = pageRules.isEmpty ? nil : pageRules
        temporaryAllowanceExpirations = Dictionary(policy.rules.compactMap { rule -> (UUID, Date)? in
            guard !forced.contains(rule.id), let expiry = rule.pausedUntil, expiry > date else { return nil }
            return (rule.id, expiry)
        }, uniquingKeysWith: max)
        lockdownEndsAt = policy.activeSessions(at: date).map(\.endsAt).max()
        self.diagnostics = diagnostics
        self.previousDiagnostics = previousDiagnostics
        macFilterSettings = nil
    }

    fileprivate init(base: FilterEnforcementStatusBase) {
        revision = base.revision
        ruleCount = base.ruleCount
        activeRuleCount = base.activeRuleCount
        activeDomainCount = base.activeDomainCount
        hasActiveWebRestrictions = base.hasActiveWebRestrictions
        updatedAt = base.updatedAt
        blockedDomains = base.blockedDomains
        blockPageRules = base.blockPageRules
        temporaryAllowanceExpirations = base.temporaryAllowanceExpirations
        browserBypassEvents = base.browserBypassEvents
        lockdownEndsAt = base.lockdownEndsAt
        diagnostics = nil
        previousDiagnostics = nil
        macFilterSettings = base.macFilterSettings
    }
}

/// Minimal forward-compatible view used before decoding the versioned
/// diagnostics payload. `Decodable` ignores future top-level fields.
fileprivate struct FilterEnforcementStatusBase: Decodable {
    var revision: UInt64
    var ruleCount: Int
    var activeRuleCount: Int
    var activeDomainCount: Int
    var hasActiveWebRestrictions: Bool
    var updatedAt: Date
    var blockedDomains: [String]?
    var blockPageRules: [BlockPageRuleStatus]?
    var temporaryAllowanceExpirations: [UUID: Date]?
    @BypassEventBuffer var browserBypassEvents: [BypassEvent]?
    var lockdownEndsAt: Date?
    var macFilterSettings: MacFilterSettingsStatus?
}

private struct FilterDiagnosticsSchemaProbe: Decodable {
    struct Diagnostics: Decodable {
        var schemaVersion: Int
    }

    var diagnostics: Diagnostics?
    var previousDiagnostics: Diagnostics?

    var newestSchema: Int? {
        [diagnostics?.schemaVersion, previousDiagnostics?.schemaVersion]
            .compactMap { $0 }
            .max()
    }
}

enum FilterStatusReadResult: Equatable {
    case available(FilterEnforcementStatus)
    case missing
    case unreadable(domain: String, code: Int)
    case corrupt
    case unsupportedDiagnosticsSchema(status: FilterEnforcementStatus, schema: Int)

    var status: FilterEnforcementStatus? {
        switch self {
        case let .available(status), let .unsupportedDiagnosticsSchema(status, _): status
        case .missing, .unreadable, .corrupt: nil
        }
    }
}

/// A world-readable file owned by the filter.
///
/// A content filter has no `sendProviderMessage`, and the extension runs as
/// root, so its App Group container and Keychain items are unreadable by the
/// signed-in user's app. A file the root extension writes and the user's app
/// reads is the one direction that works.
enum FilterStatusStore {
    static let directoryURL = URL(fileURLWithPath: "/Library/Application Support/ExecutiveDysfunction", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("filter-status.json", isDirectory: false)

    /// Written by the extension only. Readable by everyone so the controlling
    /// app can show it without elevating.
    static func write(_ status: FilterEnforcementStatus, to destination: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(status).write(to: destination, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    static func read() -> FilterEnforcementStatus? {
        readResult().status
    }

    static func readResult(from source: URL = fileURL) -> FilterStatusReadResult {
        guard FileManager.default.fileExists(atPath: source.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            let error = error as NSError
            return .unreadable(domain: error.domain, code: error.code)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        // Probe the tiny version envelope before strongly typed decoding. A
        // future diagnostics schema may add enum cases or required fields that
        // this build cannot decode; that is "unsupported", not file corruption.
        if let probe = try? decoder.decode(FilterDiagnosticsSchemaProbe.self, from: data),
           let schema = probe.newestSchema,
           schema > WebFilterDiagnosticsSnapshot.currentSchemaVersion {
            guard let base = try? decoder.decode(FilterEnforcementStatusBase.self, from: data) else {
                return .corrupt
            }
            return .unsupportedDiagnosticsSchema(
                status: FilterEnforcementStatus(base: base),
                schema: schema
            )
        }
        guard let status = try? decoder.decode(FilterEnforcementStatus.self, from: data) else {
            return .corrupt
        }
        return .available(status)
    }
}

/// Compares what the app published against what the filter reports, and says
/// plainly which of the two is wrong.
enum FilterEnforcementSummary {
    /// Beyond this the filter is treated as not reporting. It heartbeats well
    /// inside this window even when no policy changes.
    static let staleAfter: TimeInterval = 20

    enum Health: Equatable {
        case notReporting
        case stale(seconds: Int)
        case behind(published: UInt64, enforcing: UInt64)
        case applying(revision: UInt64)
        case limited(revision: UInt64, missing: [String])
        case idle(revision: UInt64)
        case enforcing(revision: UInt64, domains: Int, rules: Int)
    }

    static func health(
        published: UInt64?,
        status: FilterEnforcementStatus?,
        now: Date = Date()
    ) -> Health {
        guard let status else { return .notReporting }
        let age = now.timeIntervalSince(status.updatedAt)
        if age > staleAfter { return .stale(seconds: Int(age)) }
        // A filter that never accepted the newest policy is the failure that
        // previously showed up only as rules that did nothing.
        if let published, status.revision < published {
            return .behind(published: published, enforcing: status.revision)
        }
        if let settings = status.macFilterSettings,
           settings.isFiltering == true, !settings.isReady {
            return .limited(revision: status.revision, missing: settings.missingRetryGuardDomainSuffixes ?? [])
        }
        if status.macFilterSettings?.isReady == false {
            return .applying(revision: status.revision)
        }
        guard status.hasActiveWebRestrictions else { return .idle(revision: status.revision) }
        return .enforcing(
            revision: status.revision,
            domains: status.activeDomainCount,
            rules: status.activeRuleCount
        )
    }

    static func description(for health: Health) -> String {
        switch health {
        case .notReporting:
            "Filter is not reporting a policy. It may not be running."
        case let .stale(seconds):
            "Filter last reported \(seconds)s ago. Current enforcement is not confirmed by a fresh heartbeat."
        case let .behind(published, enforcing):
            "Filter is behind: enforcing revision \(enforcing), app published \(published). New rules are not applied."
        case let .applying(revision):
            "Filter is applying revision \(revision); web enforcement is not ready yet."
        case let .limited(revision, missing):
            "Hostname blocking is active at revision \(revision). IP retry protection is incomplete for: \(missing.joined(separator: ", ")). DNS retries automatically; cached-IP access may still work for these sites."
        case let .idle(revision):
            "Filter active at revision \(revision). No website rule is in force right now."
        case let .enforcing(revision, domains, rules):
            "Enforcing revision \(revision) — \(domains) domain(s) across \(rules) active rule(s)."
        }
    }

    static func isHealthy(_ health: Health) -> Bool {
        switch health {
        case .enforcing, .idle: true
        case .notReporting, .stale, .behind, .applying, .limited: false
        }
    }
}
