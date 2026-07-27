import Foundation

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
    /// When the longest-running lockdown session ends, if one is running.
    var lockdownEndsAt: Date?

    init(policy: DesktopEnforcementPolicy, at date: Date = Date()) {
        let active = policy.activeRules(at: date)
        revision = policy.revision
        ruleCount = policy.rules.count
        activeRuleCount = active.count
        let domains = Set(active.filter { $0.enforcementMode == .blockList }.flatMap(\.domains))
        activeDomainCount = Set(active.flatMap(\.domains)).count
        hasActiveWebRestrictions = policy.hasActiveWebRestrictions(at: date)
        updatedAt = date
        blockedDomains = domains.isEmpty ? nil : domains.sorted()
        lockdownEndsAt = policy.activeSessions(at: date).map(\.endsAt).max()
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
    static func write(_ status: FilterEnforcementStatus) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(status).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }

    static func read() -> FilterEnforcementStatus? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(FilterEnforcementStatus.self, from: data)
    }
}

/// Compares what the app published against what the filter reports, and says
/// plainly which of the two is wrong.
enum FilterEnforcementSummary {
    /// Beyond this the filter is treated as not reporting. It heartbeats well
    /// inside this window even when no policy changes.
    static let staleAfter: TimeInterval = 120

    enum Health: Equatable {
        case notReporting
        case stale(seconds: Int)
        case behind(published: UInt64, enforcing: UInt64)
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
            "Filter last reported \(seconds)s ago; it may have stopped."
        case let .behind(published, enforcing):
            "Filter is behind: enforcing revision \(enforcing), app published \(published). New rules are not applied."
        case let .idle(revision):
            "Filter active at revision \(revision). No website rule is in force right now."
        case let .enforcing(revision, domains, rules):
            "Enforcing revision \(revision) — \(domains) domain(s) across \(rules) active rule(s)."
        }
    }

    static func isHealthy(_ health: Health) -> Bool {
        switch health {
        case .enforcing, .idle: true
        case .notReporting, .stale, .behind: false
        }
    }
}
