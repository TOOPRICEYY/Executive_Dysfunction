import CryptoKit
import Foundation
import Security

enum DesktopEnforcementConstants {
    static let appGroupIdentifier = "group.com.GabrielPrice.ExecutiveDysfunction"
    // Keep this prefix aligned with DEVELOPMENT_TEAM in project.yml. It is
    // intentionally explicit because Keychain APIs don't expand build-setting
    // syntax at runtime.
    static let keychainAccessGroup = "7GXNZJMGPD.com.GabrielPrice.ExecutiveDysfunction.shared"
    static let policyFileName = "desktop-enforcement-policy.json"
    static let keychainService = "com.GabrielPrice.ExecutiveDysfunction.desktop-policy"
    static let keychainAccount = "policy-authentication-key.v1"
    static let webFilterExtensionIdentifier = "com.GabrielPrice.ExecutiveDysfunction.WebFilter"

    /// Blocking these common encrypted-DNS endpoints while a web rule is
    /// active prevents browsers from trivially bypassing inspected DNS. This
    /// is deliberately conservative; custom DoH endpoints remain a reason to
    /// use Fortress mode or an MDM-enforced resolver for maximum assurance.
    static let encryptedDNSProviderDomains: Set<String> = [
        "cloudflare-dns.com", "dns.google", "dns.quad9.net",
        "doh.opendns.com", "dns.nextdns.io", "doh.cleanbrowsing.org",
        "one.one.one.one", "dns.adguard-dns.com", "dns-family.adguard.com",
        "dns-unfiltered.adguard.com"
    ]
}

struct DesktopEnforcementPolicy: Codable, Equatable {
    var schemaVersion = 1
    var revision: UInt64
    var issuedAt: Date
    var rules: [DesktopEnforcementRule]
    /// Set only after the local passage/delay workflow has completed. It is
    /// covered by the policy HMAC and deliberately absent from normal saves.
    var weakeningAuthorizationExpiresAt: Date?
    /// Time-boxed commitments holding block lists on. Optional so policies
    /// written before sessions existed still decode.
    var lockdownSessions: [DesktopLockdownSession]?

    static let empty = DesktopEnforcementPolicy(
        revision: 0,
        issuedAt: .distantPast,
        rules: [],
        weakeningAuthorizationExpiresAt: nil,
        lockdownSessions: nil
    )

    func blocksDomain(_ rawDomain: String, at date: Date = Date()) -> Bool {
        let domain = Self.normalizedDomain(rawDomain)
        guard !domain.isEmpty else { return false }
        return activeRules(at: date).contains { rule in
            switch rule.enforcementMode {
            case .blockList:
                rule.domains.contains { Self.domain(domain, matches: $0) }
            case .fortressAllowList:
                !rule.domains.contains { Self.domain(domain, matches: $0) }
            }
        }
    }

    /// True only when a block-list rule names this domain. Fortress's
    /// default-deny is deliberately excluded, so callers can tell "the user
    /// asked for this to be blocked" apart from "nothing allowed it yet".
    func blocksDomainExplicitly(_ rawDomain: String, at date: Date = Date()) -> Bool {
        let domain = Self.normalizedDomain(rawDomain)
        guard !domain.isEmpty else { return false }
        return activeRules(at: date).contains { rule in
            rule.enforcementMode == .blockList
                && rule.domains.contains { Self.domain(domain, matches: $0) }
        }
    }

    func blocksApplication(signingIdentifier: String?, executablePath: String, at date: Date = Date()) -> Bool {
        let identifier = signingIdentifier?.lowercased() ?? ""
        let path = executablePath.lowercased()

        // Never interfere with Apple system components or the enforcement stack.
        if path.hasPrefix("/system/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") {
            return false
        }
        let protectedIdentifiers = [
            "com.gabrielprice.executivedysfunction",
            DesktopEnforcementConstants.webFilterExtensionIdentifier.lowercased()
        ]
        if protectedIdentifiers.contains(where: { identifier == $0 || identifier.hasPrefix($0 + ".") }) {
            return false
        }

        return activeRules(at: date).contains { rule in
            let matchesIdentifier = rule.macApplicationIdentifiers.contains(identifier)
            switch rule.enforcementMode {
            case .blockList: return matchesIdentifier
            case .fortressAllowList: return !matchesIdentifier
            }
        }
    }

    /// A lockdown session overrides both the schedule and the enabled flag for
    /// the rules it names. Committing to a list ahead of time is worth nothing
    /// if it still depends on a toggle staying switched on, or on the clock
    /// being inside a weekly window.
    func activeRules(at date: Date, calendar: Calendar = .current) -> [DesktopEnforcementRule] {
        let forced = sessionForcedRuleIDs(at: date)
        return rules.filter { rule in
            if forced.contains(rule.id) { return true }
            return rule.isEnabled && rule.windows.contains { $0.isActive(at: date, calendar: calendar) }
        }
    }

    func hasActiveFortress(at date: Date = Date()) -> Bool {
        activeRules(at: date).contains { $0.enforcementMode == .fortressAllowList }
    }

    func hasActiveWebRestrictions(at date: Date = Date()) -> Bool {
        activeRules(at: date).contains {
            $0.enforcementMode == .fortressAllowList || !$0.domains.isEmpty
        }
    }

    func blocksNetworkHostname(_ rawDomain: String, at date: Date = Date()) -> Bool {
        let domain = Self.normalizedDomain(rawDomain)
        guard !domain.isEmpty else { return false }
        if hasActiveWebRestrictions(at: date),
           DesktopEnforcementConstants.encryptedDNSProviderDomains.contains(where: {
               Self.domain(domain, matches: $0)
           }) {
            return true
        }
        return blocksDomain(domain, at: date)
    }

    /// Ports dedicated to encrypted DNS can bypass hostname-based website
    /// rules when the endpoint name is unavailable. Keep those closed while a
    /// web rule is active, but never treat ordinary HTTPS/QUIC (port 443) as
    /// unidentified DNS. Globally dropping UDP 443 caused browsers to lose all
    /// web access instead of reliably falling back to TCP.
    func blocksUnidentifiedNetworkPort(_ port: Int?, at date: Date = Date()) -> Bool {
        guard hasActiveWebRestrictions(at: date), let port else { return false }
        return [784, 853, 8853].contains(port)
    }

    private static func normalizedDomain(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        if result.hasPrefix("www.") { result.removeFirst(4) }
        return result
    }

    private static func domain(_ candidate: String, matches ruleDomain: String) -> Bool {
        let rule = normalizedDomain(ruleDomain)
        return candidate == rule || candidate.hasSuffix("." + rule)
    }
}

struct DesktopEnforcementRule: Codable, Equatable, Identifiable {
    enum Mode: String, Codable { case blockList, fortressAllowList }

    var id: UUID
    var name: String
    var isEnabled: Bool
    var enforcementMode: Mode
    var windows: [DesktopTimeWindow]
    var domains: Set<String>
    var macApplicationIdentifiers: Set<String>
    var windowsExecutablePaths: Set<String>
    var windowsPublisherRules: Set<String>
    var lockdown: DesktopLockdownPolicy
}

struct DesktopLockdownPolicy: Codable, Equatable {
    var severity: String
    var unlockDelayDays: Int
    var passageWordCount: Int
    var confirmationWindowHours: Int
    var editWindowHours: Int
    var allowsTimeExtensions: Bool
    var maximumTimeExtensionHours: Int
}

struct DesktopTimeWindow: Codable, Equatable, Hashable {
    var weekdays: Set<Int>
    var startMinutes: Int
    var endMinutes: Int

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        weekdays.contains { startWeekday in
            let weekday = calendar.component(.weekday, from: date)
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            if startMinutes < endMinutes {
                return weekday == startWeekday && minute >= startMinutes && minute < endMinutes
            }
            let followingWeekday = startWeekday == 7 ? 1 : startWeekday + 1
            return (weekday == startWeekday && minute >= startMinutes)
                || (weekday == followingWeekday && minute < endMinutes)
        }
    }
}

extension DesktopEnforcementPolicy {
    init(
        cloudRules: [CloudRulePreference],
        revision: UInt64,
        issuedAt: Date = Date(),
        weakeningAuthorizationExpiresAt: Date? = nil,
        lockdownSessions: [DesktopLockdownSession]? = nil
    ) {
        self.init(
            revision: revision,
            issuedAt: issuedAt,
            rules: cloudRules.map { rule in
                DesktopEnforcementRule(
                    id: rule.id,
                    name: rule.name,
                    isEnabled: rule.isEnabled,
                    enforcementMode: DesktopEnforcementRule.Mode(rawValue: rule.enforcementMode) ?? .blockList,
                    windows: rule.windows.map {
                        DesktopTimeWindow(
                            weekdays: $0.weekdays,
                            startMinutes: $0.startMinutes,
                            endMinutes: $0.endMinutes
                        )
                    },
                    domains: Set(rule.domains.map { $0.domain.lowercased() }),
                    macApplicationIdentifiers: Set(rule.macApplicationIdentifiers.map { $0.lowercased() }),
                    windowsExecutablePaths: Set(rule.windowsExecutablePaths.map { $0.lowercased() }),
                    windowsPublisherRules: Set(rule.windowsPublisherRules.map { $0.lowercased() }),
                    lockdown: DesktopLockdownPolicy(
                        severity: rule.lockdown.severity,
                        unlockDelayDays: rule.lockdown.unlockDelayDays,
                        passageWordCount: rule.lockdown.passageWordCount,
                        confirmationWindowHours: rule.lockdown.confirmationWindowHours,
                        editWindowHours: rule.lockdown.editWindowHours,
                        allowsTimeExtensions: rule.lockdown.allowsTimeExtensions,
                        maximumTimeExtensionHours: rule.lockdown.maximumTimeExtensionHours
                    )
                )
            },
            weakeningAuthorizationExpiresAt: weakeningAuthorizationExpiresAt,
            lockdownSessions: lockdownSessions
        )
    }
}

enum DesktopPolicyRestrictionEvaluator {
    static func canReplace(
        existing: DesktopEnforcementPolicy,
        with proposed: DesktopEnforcementPolicy,
        at now: Date = Date()
    ) -> Bool {
        guard existing.revision > 0 else { return true }
        if let expiry = proposed.weakeningAuthorizationExpiresAt, now < expiry { return true }

        let proposedByID = Dictionary(uniqueKeysWithValues: proposed.rules.map { ($0.id, $0) })
        for old in existing.rules {
            // An explicitly unlocked rule has no stronger-only boundary.
            if old.lockdown.severity == "none" { continue }
            guard let new = proposedByID[old.id], isSameOrStricter(old: old, new: new) else {
                return false
            }
        }
        return true
    }

    private static func isSameOrStricter(old: DesktopEnforcementRule, new: DesktopEnforcementRule) -> Bool {
        guard old.enforcementMode == new.enforcementMode else { return false }
        if old.isEnabled && !new.isEnabled { return false }
        if !weeklyCoverage(new.windows).isSuperset(of: weeklyCoverage(old.windows)) { return false }

        switch old.enforcementMode {
        case .blockList:
            guard new.domains.isSuperset(of: old.domains),
                  new.macApplicationIdentifiers.isSuperset(of: old.macApplicationIdentifiers),
                  new.windowsExecutablePaths.isSuperset(of: old.windowsExecutablePaths),
                  new.windowsPublisherRules.isSuperset(of: old.windowsPublisherRules)
            else { return false }
        case .fortressAllowList:
            guard new.domains.isSubset(of: old.domains),
                  new.macApplicationIdentifiers.isSubset(of: old.macApplicationIdentifiers),
                  new.windowsExecutablePaths.isSubset(of: old.windowsExecutablePaths),
                  new.windowsPublisherRules.isSubset(of: old.windowsPublisherRules)
            else { return false }
        }
        return lockdownIsSameOrStricter(old: old.lockdown, new: new.lockdown)
    }

    private static func lockdownIsSameOrStricter(
        old: DesktopLockdownPolicy,
        new: DesktopLockdownPolicy
    ) -> Bool {
        if lockdownStrength(new.severity) < lockdownStrength(old.severity) { return false }
        if new.unlockDelayDays < old.unlockDelayDays { return false }
        if new.passageWordCount < old.passageWordCount { return false }
        if new.editWindowHours > old.editWindowHours { return false }
        if old.severity == "repeatedConfirmations",
           new.confirmationWindowHours > old.confirmationWindowHours { return false }
        if !old.allowsTimeExtensions && new.allowsTimeExtensions { return false }
        if old.allowsTimeExtensions && new.allowsTimeExtensions,
           new.maximumTimeExtensionHours > old.maximumTimeExtensionHours { return false }
        return true
    }

    private static func lockdownStrength(_ severity: String) -> Int {
        switch severity {
        case "none": return 0
        case "passageOnly": return 1
        case "delayed", "appDefault": return 2
        case "repeatedConfirmations": return 3
        default: return 2
        }
    }

    private static func weeklyCoverage(_ windows: [DesktopTimeWindow]) -> Set<Int> {
        let day = 1_440
        let week = 7 * day
        var result = Set<Int>()
        for window in windows {
            let duration = window.startMinutes < window.endMinutes
                ? window.endMinutes - window.startMinutes
                : day - window.startMinutes + window.endMinutes
            for weekday in window.weekdays {
                let start = (weekday - 1) * day + window.startMinutes
                for offset in 0..<max(0, duration) { result.insert((start + offset) % week) }
            }
        }
        return result
    }
}

struct AuthenticatedDesktopPolicy: Codable, Equatable {
    var policy: DesktopEnforcementPolicy
    var authenticationCode: String
}

/// `NEFilterProviderConfiguration.vendorConfiguration` is the supported bridge
/// from the signed-in containing app to a root content-filter system extension.
/// App Group containers and legacy keychains are scoped to the process's user
/// context on macOS, so they cannot be the sole transport for this boundary.
enum DesktopPolicyConfigurationTransport {
    private static let policyDataKey = "desktopPolicyData"
    private static let policyRevisionKey = "desktopPolicyRevision"

    static func vendorConfiguration(for policy: DesktopEnforcementPolicy) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return [
            policyDataKey: try encoder.encode(policy),
            policyRevisionKey: NSNumber(value: policy.revision)
        ]
    }

    static func policy(from vendorConfiguration: [String: Any]?) -> DesktopEnforcementPolicy? {
        guard let data = vendorConfiguration?[policyDataKey] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(DesktopEnforcementPolicy.self, from: data)
    }

    static func revision(from vendorConfiguration: [String: Any]?) -> UInt64? {
        (vendorConfiguration?[policyRevisionKey] as? NSNumber)?.uint64Value
    }
}

enum DesktopPolicyError: LocalizedError {
    case appGroupUnavailable
    case keychain(OSStatus)
    case invalidAuthentication
    case rolledBack(current: UInt64, proposed: UInt64)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: "The desktop enforcement App Group is unavailable."
        case let .keychain(status): "Desktop policy keychain access failed (status \(status))."
        case .invalidAuthentication: "The desktop enforcement policy failed authentication."
        case let .rolledBack(current, proposed):
            "Rejected desktop policy rollback from revision \(current) to \(proposed)."
        }
    }
}

enum DesktopPolicyAuthenticator {
    static func authenticationCode(for policy: DesktopEnforcementPolicy, key: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(policy)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    static func authenticate(_ envelope: AuthenticatedDesktopPolicy, key: Data) throws -> DesktopEnforcementPolicy {
        let expected = try authenticationCode(for: envelope.policy, key: key)
        guard timingSafeEqual(expected, envelope.authenticationCode) else {
            throw DesktopPolicyError.invalidAuthentication
        }
        return envelope.policy
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

final class DesktopPolicyKeyStore {
    func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw DesktopPolicyError.keychain(status) }

        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try load() { return existing }
        guard addStatus == errSecSuccess else { throw DesktopPolicyError.keychain(addStatus) }
        return key
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DesktopPolicyError.keychain(status)
        }
        return data
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: DesktopEnforcementConstants.keychainService,
            kSecAttrAccount as String: DesktopEnforcementConstants.keychainAccount,
            kSecAttrAccessGroup as String: DesktopEnforcementConstants.keychainAccessGroup
        ]
    }
}

final class DesktopPolicyFileStore {
    private let keyStore = DesktopPolicyKeyStore()

    func publish(_ policy: DesktopEnforcementPolicy) throws {
        let key = try keyStore.loadOrCreate()
        let envelope = AuthenticatedDesktopPolicy(
            policy: policy,
            authenticationCode: try DesktopPolicyAuthenticator.authenticationCode(for: policy, key: key)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: try policyURL(), options: [.atomic, .completeFileProtection])
    }

    func loadVerified(minimumRevision: UInt64 = 0) throws -> DesktopEnforcementPolicy {
        let data = try Data(contentsOf: policyURL())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(AuthenticatedDesktopPolicy.self, from: data)
        guard envelope.policy.revision >= minimumRevision else {
            throw DesktopPolicyError.rolledBack(current: minimumRevision, proposed: envelope.policy.revision)
        }
        guard let key = try keyStore.load() else { throw DesktopPolicyError.invalidAuthentication }
        return try DesktopPolicyAuthenticator.authenticate(envelope, key: key)
    }

    /// A macOS content-filter system extension runs outside the signed-in
    /// user's keychain context. Consequently, it cannot read a HMAC key that
    /// the containing app placed in the user's legacy file-based keychain,
    /// even when both targets carry the same access-group entitlement.
    ///
    /// This fallback is deliberately usable only behind the monotonic
    /// restriction evaluator in `ResilientDesktopPolicyLoader`. It also drops
    /// the app-authored weakening authorization so an edited shared file can
    /// never use this path to relax an accepted rule.
    func loadForMonotonicFallback(minimumRevision: UInt64 = 0) throws -> DesktopEnforcementPolicy {
        let data = try Data(contentsOf: policyURL())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(AuthenticatedDesktopPolicy.self, from: data)
        guard envelope.policy.revision >= minimumRevision else {
            throw DesktopPolicyError.rolledBack(
                current: minimumRevision,
                proposed: envelope.policy.revision
            )
        }
        var policy = envelope.policy
        policy.weakeningAuthorizationExpiresAt = nil
        return policy
    }

    private func policyURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DesktopEnforcementConstants.appGroupIdentifier
        ) else { throw DesktopPolicyError.appGroupUnavailable }
        return container.appendingPathComponent(DesktopEnforcementConstants.policyFileName, isDirectory: false)
    }
}

/// Persistence for the last accepted policy baseline.
///
/// Injectable so tests are hermetic: the Keychain item is keyed only by service
/// and account, so anything running as the same user shares one baseline. A
/// test that used the real store silently inherited a revision left behind by
/// another process and then rejected its own fixtures as rollbacks.
protocol AcceptedPolicyPersisting: AnyObject {
    func load() -> DesktopEnforcementPolicy?
    func save(_ policy: DesktopEnforcementPolicy) throws
}

/// An in-memory baseline, for tests and for any context that must not touch the
/// shared Keychain item.
final class InMemoryAcceptedPolicyStore: AcceptedPolicyPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DesktopEnforcementPolicy?

    init(_ initial: DesktopEnforcementPolicy? = nil) { stored = initial }

    func load() -> DesktopEnforcementPolicy? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ policy: DesktopEnforcementPolicy) throws {
        lock.lock(); defer { lock.unlock() }
        stored = policy
    }
}

/// A target-private, this-device-only baseline. Because no access group is
/// supplied, the controller app cannot replace the copy owned by the web-filter
/// system extension. This closes the reboot/restart gap in an in-memory-only baseline.
final class AcceptedDesktopPolicyStore: AcceptedPolicyPersisting {
    private let service = "com.GabrielPrice.ExecutiveDysfunction.accepted-desktop-policy.v1"
    private let account = "last-accepted-policy"

    func load() -> DesktopEnforcementPolicy? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(DesktopEnforcementPolicy.self, from: data)
    }

    func save(_ policy: DesktopEnforcementPolicy) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(policy)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw DesktopPolicyError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw DesktopPolicyError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Keeps the last authenticated policy in memory. A corrupt, missing, or older
/// shared file never clears a previously accepted restriction snapshot.
///
/// `current()` sits on the packet and flow paths, so it must stay allocation-
/// light and must never perform file or Keychain I/O inline. Decoding the
/// vendor configuration on every flow, and writing the Keychain baseline on
/// every accepted read, is enough to starve the filter and present as a total
/// loss of connectivity rather than as a slow filter.
final class ResilientDesktopPolicyLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let store = DesktopPolicyFileStore()
    private let acceptedStore: AcceptedPolicyPersisting
    private let refreshQueue = DispatchQueue(
        label: "com.GabrielPrice.ExecutiveDysfunction.policy-refresh",
        qos: .utility
    )
    private var cached: DesktopEnforcementPolicy
    /// The vendor-configuration revision already folded into `cached`. Without
    /// it the loader re-decodes the same JSON blob for the lifetime of the
    /// filter, because an accepted revision always satisfies `>= cached`.
    private var ingestedVendorRevision: UInt64?
    private var lastAttempt = Date.distantPast
    private var isRefreshing = false

    init(acceptedStore: AcceptedPolicyPersisting = AcceptedDesktopPolicyStore()) {
        self.acceptedStore = acceptedStore
        cached = acceptedStore.load() ?? .empty
    }

    func current(
        vendorConfiguration: [String: Any]? = nil,
        now: Date = Date()
    ) -> DesktopEnforcementPolicy {
        lock.lock()

        // The vendor configuration is authoritative and is applied on its
        // revision alone.
        //
        // It reaches the filter only by way of the signed containing app
        // writing system-owned Network Extension preferences, which already
        // requires the administrator rights needed to remove the filter
        // outright. The stronger-only evaluator therefore buys nothing here,
        // and it caused real harm: a baseline naming a rule the user has since
        // deleted can never be matched again, so every later policy was
        // rejected and the filter enforced one stale snapshot forever, with no
        // way to observe or clear it. Newly blocked domains simply never
        // arrived.
        //
        // Tamper resistance still belongs on the shared file, which is
        // user-writable; `scheduleRefresh` keeps the strict evaluator there.
        // Rollback is still refused by the monotonic revision check.
        if let proposedRevision = DesktopPolicyConfigurationTransport.revision(
            from: vendorConfiguration
        ), proposedRevision != ingestedVendorRevision, proposedRevision >= cached.revision,
           let proposed = DesktopPolicyConfigurationTransport.policy(from: vendorConfiguration),
           proposed.revision == proposedRevision {
            // Latched only on acceptance, so a proposal rejected for a
            // transient reason is retried rather than skipped forever.
            ingestedVendorRevision = proposedRevision
            // A running session outlives the policy that started it. The app
            // republishes on every refresh, so without this a commitment would
            // end at the next routine save rather than at the time promised.
            let merged = proposed.carryingForwardSessions(from: cached, at: now)
            cached = merged
            persist(merged)
        }

        let shouldRefresh = !isRefreshing && now.timeIntervalSince(lastAttempt) >= 2
        if shouldRefresh {
            lastAttempt = now
            isRefreshing = true
        }
        let snapshot = cached
        lock.unlock()

        if shouldRefresh { scheduleRefresh(minimumRevision: snapshot.revision) }
        return snapshot
    }

    /// Reads the shared file and Keychain off the network path and folds the
    /// result in only if it is same-or-stronger. A refresh that fails leaves
    /// the last accepted snapshot untouched.
    private func scheduleRefresh(minimumRevision: UInt64) {
        refreshQueue.async { [self] in
            let loaded = (try? store.loadVerified(minimumRevision: minimumRevision))
                ?? (try? store.loadForMonotonicFallback(minimumRevision: minimumRevision))
            let now = Date()
            lock.lock()
            isRefreshing = false
            if let loaded, loaded.revision >= cached.revision,
               DesktopPolicyRestrictionEvaluator.canReplace(existing: cached, with: loaded, at: now) {
                let loaded = loaded.carryingForwardSessions(from: cached, at: now)
                let changed = loaded != cached
                cached = loaded
                lock.unlock()
                if changed { try? acceptedStore.save(loaded) }
                return
            }
            lock.unlock()
        }
    }

    private func persist(_ policy: DesktopEnforcementPolicy) {
        refreshQueue.async { [acceptedStore] in try? acceptedStore.save(policy) }
    }
}
