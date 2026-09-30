import CryptoKit
import Foundation
import OSLog
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
    /// Shared cancellation cannot authorize unrelated rule weakening.
    var lockdownCancellationAuthorization: DesktopLockdownCancellationAuthorization? = nil

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
            let matchesIdentifier = rule.matchesApplication(identifier)
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
    /// Whether two policies say the same thing, ignoring revision and issue
    /// time.
    ///
    /// Saving the filter configuration restarts the provider and causes a brief
    /// measured startup interruption. Republishing unchanged policy must
    /// therefore be a no-op rather than a new revision.
    func hasSameContent(as other: DesktopEnforcementPolicy) -> Bool {
        rules == other.rules
            && (lockdownSessions ?? []) == (other.lockdownSessions ?? [])
            && weakeningAuthorizationExpiresAt == other.weakeningAuthorizationExpiresAt
            && lockdownCancellationAuthorization == other.lockdownCancellationAuthorization
    }

    /// Rules in force at `date`. When the filter's clock guard has detected a
    /// wall-clock change, rules in force at the corresponding trusted instant
    /// are added: tampering can only make enforcement stricter.
    func activeRules(at date: Date, calendar: Calendar = .current) -> [DesktopEnforcementRule] {
        var result = activeRulesAtWallTime(date, calendar: calendar)
        if let trusted = ClockTamperGuard.shared.alternateDate(for: date) {
            for rule in activeRulesAtWallTime(trusted, calendar: calendar) where !result.contains(rule) {
                result.append(rule)
            }
        }
        return result
    }

    private func activeRulesAtWallTime(_ date: Date, calendar: Calendar) -> [DesktopEnforcementRule] {
        let forced = sessionForcedRuleIDs(at: date)
        var active = rules.filter { rule in
            // A lockdown session is a commitment that a pause must not undo, so
            // the forced check deliberately comes first.
            if forced.contains(rule.id) { return true }
            if rule.isPaused(at: date) { return false }
            guard rule.isWithinPlannedInterval(at: date) else { return false }
            return rule.isEnabled && rule.windows.contains { $0.isActive(at: date, calendar: calendar) }
        }
        // Additive: edits can strengthen a live group, but cannot erase the
        // targets committed to at the start of a lockdown.
        for session in activeSessions(at: date) {
            for rule in session.ruleSnapshots ?? [] where !active.contains(rule) {
                active.append(rule)
            }
        }
        return active
    }

    /// Returns the same authenticated policy with only the locally-authorized
    /// temporary pauses removed from enforcement. The revision intentionally
    /// does not change: a pause is an expiring runtime exception to the signed
    /// policy, not a replacement policy that the app may later accept as the
    /// newest configuration.
    func excludingTemporarilyPausedRules(_ ruleIDs: Set<UUID>, at now: Date = Date()) -> DesktopEnforcementPolicy {
        guard !ruleIDs.isEmpty else { return self }
        var effective = self
        let forced = sessionForcedRuleIDs(at: now)
        effective.rules.removeAll { ruleIDs.contains($0.id) && !forced.contains($0.id) }
        return effective
    }

    /// Binds a block-page authorization to both the accepted policy revision
    /// and one exact rule. A policy edit changes the revision and therefore
    /// invalidates every outstanding pause, even if a rule ID is reused.
    func temporaryPauseFingerprint(for ruleID: UUID) -> String {
        let value = "\(revision):\(ruleID.uuidString.lowercased())"
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func hasActiveFortress(at date: Date = Date()) -> Bool {
        activeRules(at: date).contains { $0.enforcementMode == .fortressAllowList }
    }

    func hasActiveWebRestrictions(at date: Date = Date()) -> Bool {
        activeRules(at: date).contains {
            $0.enforcementMode == .fortressAllowList || !$0.domains.isEmpty
        }
    }

    /// Whether evaluating a new flow can possibly need the source process's
    /// signing identity. Resolving an audit token invokes synchronous Security
    /// APIs on Network Extension's verdict path, so doing it for domain-only
    /// policies can starve otherwise-allowed traffic during a process storm.
    func hasActiveMacApplicationRestrictions(at date: Date = Date()) -> Bool {
        activeRules(at: date).contains {
            $0.enforcementMode == .blockList && !$0.macApplicationIdentifiers.isEmpty
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
    /// A locally authorized pause on this rule. Optional so policies written
    /// before pauses existed still decode, and absent means "not paused", so an
    /// unreadable or missing value fails closed rather than releasing a block.
    var pausedUntil: Date?
    /// Set only by the filter, never by the app: when the filter first saw the
    /// current uninterrupted pause. Lets it cap a pause session at the rule's
    /// maximum no matter how often the app republishes a later expiry.
    var pauseSessionStartedAt: Date?
    /// Planned interval for a Retreat's group, so the filter starts and ends
    /// the Retreat on time even when the app is not running. Nil for Baseline
    /// groups, which have no boundary.
    var activeFrom: Date?
    var activeUntil: Date?

    func isWithinPlannedInterval(at date: Date) -> Bool {
        if let activeFrom, date < activeFrom { return false }
        if let activeUntil, date >= activeUntil { return false }
        return true
    }

    /// Exact signing identifier, or a family written as `com.vendor.*`, which
    /// also covers helpers and network extensions the vendor ships under its
    /// own prefix (a VPN's tunnel provider, for example).
    func matchesApplication(_ identifier: String) -> Bool {
        let identifier = identifier.lowercased()
        guard !identifier.isEmpty else { return false }
        if macApplicationIdentifiers.contains(identifier) { return true }
        return macApplicationIdentifiers.contains { entry in
            guard entry.hasSuffix(".*") else { return false }
            let prefix = String(entry.dropLast(1))
            return prefix.count > 1 && identifier.hasPrefix(prefix)
        }
    }

    func isPaused(at date: Date) -> Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > date
    }
}

struct DesktopLockdownPolicy: Codable, Equatable {
    var severity: String
    var unlockDelayDays: Int
    var passageWordCount: Int
    var confirmationWindowHours: Int
    var editWindowHours: Int
    var allowsTimeExtensions: Bool
    var maximumTimeExtensionHours: Int
    var temporaryAllowanceResetDays: Int? = nil
    var requiresNativeTemporaryAccess: Bool? = nil
    var temporaryAccessPassageWordCount: Int? = nil

    var effectiveTemporaryAccessPassageWordCount: Int {
        min(300, max(20, temporaryAccessPassageWordCount ?? passageWordCount))
    }

    var needsNativeTemporaryAccess: Bool {
        temporaryAllowanceResetDays != nil
            || effectiveTemporaryAccessPassageWordCount != min(300, max(20, passageWordCount))
    }

    var permitsAnyTemporaryAccess: Bool {
        allowsTimeExtensions || requiresNativeTemporaryAccess == true
    }
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

/// The fully accumulated, normalized block profile used to construct a signed
/// enforcement policy. Baseline and active Retreat rules are additive inputs.
/// Building this once avoids repeating domain/path normalization for the
/// content-comparison candidate and the revisioned policy publication.
struct DesktopBlockProfile: Equatable {
    var rules: [DesktopEnforcementRule]

    init(
        cloudRules: [CloudRulePreference],
        temporaryPauses: [UUID: Date] = [:],
        now: Date = Date()
    ) {
        rules = cloudRules.map { rule in
            var desktop = Self.desktopRule(rule)
            // Only a rule that opted into temporary access can carry a pause,
            // so a stale or hand-edited record cannot weaken a rule that never
            // allowed one.
            if desktop.lockdown.allowsTimeExtensions {
                desktop.pausedUntil = Self.clampedPause(
                    temporaryPauses[rule.id],
                    maximumHours: desktop.lockdown.maximumTimeExtensionHours,
                    now: now
                )
            }
            return desktop
        }
    }

    /// The pause ledger lives in preferences the device owner can edit, and the
    /// grant-time checks (passage, session maximum, backoff) never see a record
    /// written by hand. Whatever is stored, a published pause may therefore end
    /// no later than the rule's own session maximum from now; an expired or
    /// nonsensical value publishes no pause at all.
    static func clampedPause(_ expiry: Date?, maximumHours: Int, now: Date) -> Date? {
        guard let expiry, expiry > now, maximumHours > 0 else { return nil }
        let ceiling = now.addingTimeInterval(TimeInterval(maximumHours) * 3_600)
        return min(expiry, ceiling)
    }

    private static func desktopRule(_ rule: CloudRulePreference) -> DesktopEnforcementRule {
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
                maximumTimeExtensionHours: rule.lockdown.maximumTimeExtensionHours,
                temporaryAllowanceResetDays: rule.lockdown.temporaryAllowanceResetDays,
                temporaryAccessPassageWordCount: rule.lockdown.temporaryAccessPassageWordCount
            )
        )
    }
}

extension DesktopEnforcementPolicy {
    init(
        cloudRules: [CloudRulePreference],
        revision: UInt64,
        issuedAt: Date = Date(),
        weakeningAuthorizationExpiresAt: Date? = nil,
        lockdownSessions: [DesktopLockdownSession]? = nil,
        temporaryPauses: [UUID: Date] = [:]
    ) {
        self.init(
            blockProfile: DesktopBlockProfile(cloudRules: cloudRules, temporaryPauses: temporaryPauses),
            revision: revision,
            issuedAt: issuedAt,
            weakeningAuthorizationExpiresAt: weakeningAuthorizationExpiresAt,
            lockdownSessions: lockdownSessions
        )
    }

    init(
        blockProfile: DesktopBlockProfile,
        revision: UInt64,
        issuedAt: Date = Date(),
        weakeningAuthorizationExpiresAt: Date? = nil,
        lockdownSessions: [DesktopLockdownSession]? = nil
    ) {
        self.init(
            revision: revision,
            issuedAt: issuedAt,
            rules: blockProfile.rules.map { original in
                var rule = original
                if rule.lockdown.allowsTimeExtensions, rule.lockdown.needsNativeTemporaryAccess {
                    // Older helpers/providers understand this existing opt-in
                    // bit. Turn off their browser path too, even if they ignore
                    // the newly added backoff fields during a staged upgrade.
                    rule.lockdown.allowsTimeExtensions = false
                    rule.lockdown.requiresNativeTemporaryAccess = true
                }
                return rule
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
        guard Set(proposed.rules.map(\.id)).count == proposed.rules.count else {
            return false
        }
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

    static func isSameOrStricter(old: DesktopEnforcementRule, new: DesktopEnforcementRule) -> Bool {
        guard old.enforcementMode == new.enforcementMode else { return false }
        if old.isEnabled && !new.isEnabled { return false }
        // A shorter planned interval (a Retreat pulled in) is weaker.
        if (new.activeUntil ?? .distantFuture) < (old.activeUntil ?? .distantFuture) { return false }
        if (new.activeFrom ?? .distantPast) > (old.activeFrom ?? .distantPast) { return false }
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
        if lockdownStrength(new) < lockdownStrength(old) { return false }
        let oldDelay = old.severity == "passageOnly" ? 0 : old.unlockDelayDays
        let newDelay = new.severity == "passageOnly" ? 0 : new.unlockDelayDays
        if newDelay < oldDelay { return false }
        if new.passageWordCount < old.passageWordCount { return false }
        if new.editWindowHours > old.editWindowHours { return false }
        if old.severity == "repeatedConfirmations",
           new.confirmationWindowHours > old.confirmationWindowHours { return false }
        if !old.permitsAnyTemporaryAccess && new.permitsAnyTemporaryAccess { return false }
        if old.permitsAnyTemporaryAccess && new.permitsAnyTemporaryAccess,
           new.maximumTimeExtensionHours > old.maximumTimeExtensionHours { return false }
        if old.permitsAnyTemporaryAccess && new.permitsAnyTemporaryAccess,
           new.effectiveTemporaryAccessPassageWordCount < old.effectiveTemporaryAccessPassageWordCount { return false }
        if old.permitsAnyTemporaryAccess && new.permitsAnyTemporaryAccess,
           old.temporaryAllowanceResetDays != new.temporaryAllowanceResetDays {
            // Backoff is additive over the existing session passage floor.
            guard let newDays = new.temporaryAllowanceResetDays,
                  newDays >= (old.temporaryAllowanceResetDays ?? 0) else { return false }
        }
        return true
    }

    private static func lockdownStrength(_ policy: DesktopLockdownPolicy) -> Int {
        switch policy.severity {
        case "none": return 0
        case "passageOnly": return 1
        case "delayed": return policy.unlockDelayDays > 0 ? 2 : 1
        case "appDefault": return 2
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
    private static let preparedRetryGuardsDataKey = "preparedRetryGuardsData"

    static func vendorConfiguration(
        for policy: DesktopEnforcementPolicy,
        preparedRetryGuards: MacFilterPreparedRetryGuardSnapshot? = nil
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var configuration: [String: Any] = [
            policyDataKey: try encoder.encode(policy),
            policyRevisionKey: NSNumber(value: policy.revision)
        ]
        if let preparedRetryGuards {
            configuration[preparedRetryGuardsDataKey] = try encoder.encode(preparedRetryGuards)
        }
        return configuration
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

    static func preparedRetryGuards(
        from vendorConfiguration: [String: Any]?
    ) -> MacFilterPreparedRetryGuardSnapshot? {
        guard let data = vendorConfiguration?[preparedRetryGuardsDataKey] as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(MacFilterPreparedRetryGuardSnapshot.self, from: data)
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
    /// On macOS an access group is ignored unless the item is in the
    /// data-protection Keychain; without `kSecUseDataProtectionKeychain` the key
    /// lands in the file-based login keychain, where the owner can reveal it in
    /// Keychain Access and sign a policy of their own. New keys therefore go to
    /// the data-protection Keychain, an existing legacy key is moved there once,
    /// and a context without that Keychain (no entitlement, or no user session)
    /// keeps using the legacy location so publishing never breaks.
    func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw DesktopPolicyError.keychain(status) }

        for protected in [true, false] {
            var query = baseQuery(dataProtection: protected)
            query[kSecValueData as String] = key
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus == errSecDuplicateItem, let existing = try load() { return existing }
            if addStatus == errSecSuccess { return key }
            if protected, Self.isDataProtectionUnavailable(addStatus) { continue }
            throw DesktopPolicyError.keychain(addStatus)
        }
        throw DesktopPolicyError.keychain(errSecNotAvailable)
    }

    func load() throws -> Data? {
        switch read(dataProtection: true) {
        case let .found(data):
            return data
        case .notFound, .unavailable:
            break
        case let .failed(status):
            throw DesktopPolicyError.keychain(status)
        }
        switch read(dataProtection: false) {
        case let .found(data):
            migrateToDataProtection(data)
            return data
        case .notFound, .unavailable:
            return nil
        case let .failed(status):
            throw DesktopPolicyError.keychain(status)
        }
    }

    private enum ReadResult {
        case found(Data)
        case notFound
        case unavailable
        case failed(OSStatus)
    }

    private func read(dataProtection: Bool) -> ReadResult {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return .found(data) }
        if status == errSecItemNotFound { return .notFound }
        if dataProtection, Self.isDataProtectionUnavailable(status) { return .unavailable }
        return .failed(status)
    }

    /// Same key bytes, new location, so policies signed earlier still verify.
    private func migrateToDataProtection(_ key: Data) {
        var add = baseQuery(dataProtection: true)
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return }
        SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
    }

    private static func isDataProtectionUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
            || status == errSecNotAvailable
            || status == errSecInteractionNotAllowed
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: DesktopEnforcementConstants.keychainService,
            kSecAttrAccount as String: DesktopEnforcementConstants.keychainAccount,
            kSecAttrAccessGroup as String: DesktopEnforcementConstants.keychainAccessGroup
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
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
protocol AcceptedPolicyPersisting: AnyObject, Sendable {
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
final class AcceptedDesktopPolicyStore: AcceptedPolicyPersisting, @unchecked Sendable {
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
private enum VendorPolicyDiagnosticOutcome: String, Equatable {
    case rollbackRejected = "rollback-rejected"
    case accepted
    case malformedRejected = "malformed-rejected"
    case missingRevision = "missing-revision"
}

private struct VendorPolicyDiagnosticKey: Equatable {
    var outcome: VendorPolicyDiagnosticOutcome
    var proposedRevision: UInt64?
    var cachedRevision: UInt64
}

final class ResilientDesktopPolicyLoader: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.GabrielPrice.ExecutiveDysfunction.WebFilter",
        category: "policy-loader"
    )
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
    private var lastVendorDiagnostic: VendorPolicyDiagnosticKey?
    private var lastSharedDiagnostic: String?

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
        ), proposedRevision != ingestedVendorRevision {
            if proposedRevision < cached.revision {
                logVendorTransitionLocked(
                    .rollbackRejected,
                    proposedRevision: proposedRevision,
                    cachedRevision: cached.revision
                )
            } else if let proposed = DesktopPolicyConfigurationTransport.policy(
                from: vendorConfiguration
            ), proposed.revision == proposedRevision {
                // Latched only on acceptance, so a proposal rejected for a
                // transient reason is retried rather than skipped forever.
                ingestedVendorRevision = proposedRevision
                // A running session outlives the policy that started it. The app
                // republishes on every refresh, so without this a commitment would
                // end at the next routine save rather than at the time promised.
                let merged = proposed
                    .carryingForwardSessions(from: cached, at: now)
                    .boundingPauses(from: cached, at: now)
                cached = merged
                logVendorTransitionLocked(
                    .accepted,
                    proposedRevision: proposedRevision,
                    cachedRevision: cached.revision
                )
                persist(merged)
            } else {
                logVendorTransitionLocked(
                    .malformedRejected,
                    proposedRevision: proposedRevision,
                    cachedRevision: cached.revision
                )
            }
        } else if vendorConfiguration != nil,
                  DesktopPolicyConfigurationTransport.revision(from: vendorConfiguration) == nil {
            logVendorTransitionLocked(
                .missingRevision,
                proposedRevision: nil,
                cachedRevision: cached.revision
            )
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
            let loaded: DesktopEnforcementPolicy?
            let source: String
            do {
                loaded = try store.loadVerified(minimumRevision: minimumRevision)
                source = "verified"
            } catch {
                do {
                    loaded = try store.loadForMonotonicFallback(minimumRevision: minimumRevision)
                    source = "monotonic-fallback"
                } catch {
                    loaded = nil
                    source = "unavailable"
                }
            }
            let now = Date()
            lock.lock()
            isRefreshing = false
            if let loaded, loaded.revision >= cached.revision,
               DesktopPolicyRestrictionEvaluator.canReplace(existing: cached, with: loaded, at: now) {
                let loaded = loaded
                    .carryingForwardSessions(from: cached, at: now)
                    .boundingPauses(from: cached, at: now)
                let changed = loaded != cached
                cached = loaded
                logSharedTransitionLocked(
                    changed ? "\(source)-accepted" : "\(source)-unchanged",
                    loadedRevision: loaded.revision,
                    cachedRevision: cached.revision
                )
                lock.unlock()
                if changed {
                    do {
                        try acceptedStore.save(loaded)
                    } catch {
                        let error = error as NSError
                        logger.error(
                            "policy_baseline_persist_failed revision=\(loaded.revision, privacy: .public) error_domain=\(error.domain, privacy: .public) error_code=\(error.code, privacy: .public) description=\(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
                return
            }
            logSharedTransitionLocked(
                loaded == nil ? source : "restriction-rejected",
                loadedRevision: loaded?.revision,
                cachedRevision: cached.revision
            )
            lock.unlock()
        }
    }

    private func persist(_ policy: DesktopEnforcementPolicy) {
        refreshQueue.async { [acceptedStore, logger] in
            do {
                try acceptedStore.save(policy)
            } catch {
                let error = error as NSError
                logger.error(
                    "policy_baseline_persist_failed revision=\(policy.revision, privacy: .public) error_domain=\(error.domain, privacy: .public) error_code=\(error.code, privacy: .public) description=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func logVendorTransitionLocked(
        _ outcome: VendorPolicyDiagnosticOutcome,
        proposedRevision: UInt64?,
        cachedRevision: UInt64
    ) {
        let key = VendorPolicyDiagnosticKey(
            outcome: outcome,
            proposedRevision: proposedRevision,
            cachedRevision: cachedRevision
        )
        guard key != lastVendorDiagnostic else { return }
        lastVendorDiagnostic = key
        logger.notice(
            "policy_vendor outcome=\(outcome.rawValue, privacy: .public) proposed_revision=\(proposedRevision ?? 0, privacy: .public) cached_revision=\(cachedRevision, privacy: .public)"
        )
    }

    private func logSharedTransitionLocked(
        _ outcome: String,
        loadedRevision: UInt64?,
        cachedRevision: UInt64
    ) {
        let key = "\(outcome):\(loadedRevision.map(String.init) ?? "none"):\(cachedRevision)"
        guard key != lastSharedDiagnostic else { return }
        lastSharedDiagnostic = key
        logger.notice(
            "policy_shared outcome=\(outcome, privacy: .public) loaded_revision=\(loadedRevision ?? 0, privacy: .public) cached_revision=\(cachedRevision, privacy: .public)"
        )
    }
}
