import Foundation

struct DesktopLockdownCancellationAuthorization: Codable, Equatable {
    var sessionIDs: Set<UUID>
    var expiresAt: Date

    private enum CodingKeys: String, CodingKey { case sessionIDs, expiresAt }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .sessionIDs)
        try values.encode(expiresAt, forKey: .expiresAt)
    }
}

/// A time-boxed commitment that forces existing block lists on.
///
/// The normal rule model is schedule-driven: a rule blocks inside its weekly
/// windows and is dormant outside them. A session is the other shape — "hold
/// these lists on, continuously, until this moment passes" — and it deliberately
/// overrides both the rule's windows and its enabled flag, because the point is
/// to commit ahead of time rather than to rely on the state of a toggle later.
///
/// Ending one early goes through the same passage the rest of the app uses for
/// weakening, and the filter carries an unexpired session forward across policy
/// updates so that simply republishing without it does not end it.
struct DesktopLockdownSession: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// Existing rules to hold on. Rules are referenced rather than copied so a
    /// session cannot drift from the list the user actually curates.
    var ruleIDs: Set<UUID>
    var startedAt: Date
    var endsAt: Date
    /// The same lock settings a rule carries, so a session behaves like a
    /// normal locked block list rather than inventing a second vocabulary.
    var lockdown: DesktopLockdownPolicy
    /// Fixed at creation so it cannot be re-rolled for a shorter one later.
    var earlyExitPassage: String
    /// Preserve selected targets if a group is edited, deleted, or its retreat ends.
    var ruleSnapshots: [DesktopEnforcementRule]? = nil

    func isActive(at date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(date))
    }

    func cloudSession(currentRules: [CloudRulePreference]) -> CloudLockdownSession {
        let portable = ruleIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> CloudRulePreference? in
            guard let snapshot = ruleSnapshots?.first(where: { $0.id == id }) else {
                return currentRules.first { $0.id == id }
            }
            var rule = currentRules.first { $0.id == id } ?? CloudRulePreference(id: id, name: snapshot.name)
            rule.enforcementMode = snapshot.enforcementMode.rawValue
            rule.domains = snapshot.domains.sorted().map { CloudDomainPreference(domain: $0, category: "other", source: "user") }
            // Snapshot domains already include category expansion at creation.
            rule.websiteCategories = []
            rule.macApplicationIdentifiers = snapshot.macApplicationIdentifiers
            return rule
        }
        return CloudLockdownSession(id: id, rules: portable, startedAt: startedAt, endsAt: endsAt,
            exitPolicy: CloudLockdownExitPolicy(severity: lockdown.severity,
                unlockDelayDays: lockdown.unlockDelayDays, passageWordCount: lockdown.passageWordCount,
                confirmationWindowHours: lockdown.confirmationWindowHours, editWindowHours: lockdown.editWindowHours),
            earlyExitPassage: earlyExitPassage)
    }

    static func fromCloud(_ session: CloudLockdownSession) -> Self {
        let policy = session.exitPolicy
        return Self(id: session.id, ruleIDs: session.ruleIDs, startedAt: session.startedAt, endsAt: session.endsAt,
            lockdown: DesktopLockdownPolicy(severity: policy.severity, unlockDelayDays: policy.unlockDelayDays,
                passageWordCount: policy.passageWordCount, confirmationWindowHours: policy.confirmationWindowHours,
                editWindowHours: policy.editWindowHours, allowsTimeExtensions: false, maximumTimeExtensionHours: 1),
            earlyExitPassage: session.earlyExitPassage,
            ruleSnapshots: DesktopBlockProfile(cloudRules: session.rules).rules)
    }
}

extension DesktopEnforcementPolicy {
    /// Sessions currently holding rules on.
    func activeSessions(at date: Date = Date()) -> [DesktopLockdownSession] {
        (lockdownSessions ?? []).filter { $0.isActive(at: date) }
    }

    /// Rules a session is holding on, regardless of their schedule or their
    /// enabled flag.
    func sessionForcedRuleIDs(at date: Date = Date()) -> Set<UUID> {
        activeSessions(at: date).reduce(into: Set<UUID>()) { $0.formUnion($1.ruleIDs) }
    }

    /// Preserves unexpired sessions that a newer policy dropped, and restores a
    /// session whose end was pulled forward without authorization.
    ///
    /// Without this, ending a session early would require nothing more than
    /// publishing the next revision — which the app does routinely, on every
    /// refresh. The commitment has to live in the filter, not in the UI that
    /// asked for it.
    ///
    /// Rules named by a surviving session are carried forward too; a session
    /// pointing at a deleted rule would otherwise hold nothing.
    func carryingForwardSessions(
        from previous: DesktopEnforcementPolicy,
        at now: Date = Date()
    ) -> DesktopEnforcementPolicy {
        let previousActive = previous.activeSessions(at: now)
        guard !previousActive.isEmpty else { return self }

        // An authenticated weakening window is the one sanctioned way to end a
        // session early; it is covered by the policy HMAC.
        let isAuthorized = weakeningAuthorizationExpiresAt.map { now < $0 } ?? false
        if isAuthorized { return self }

        var result = self
        var sessions = result.lockdownSessions ?? []
        let proposedByID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for original in previousActive {
            if let authorization = lockdownCancellationAuthorization,
               now < authorization.expiresAt, authorization.sessionIDs.contains(original.id) { continue }
            if let proposed = proposedByID[original.id] {
                // Present, but its end may have been pulled in. Only a later
                // end is accepted without authorization; extending a commitment
                // is always allowed.
                if let index = sessions.firstIndex(where: { $0.id == original.id }) {
                    sessions[index].endsAt = max(proposed.endsAt, original.endsAt)
                    sessions[index].startedAt = min(proposed.startedAt, original.startedAt)
                    sessions[index].ruleIDs.formUnion(original.ruleIDs)
                    sessions[index].lockdown = original.lockdown
                    sessions[index].earlyExitPassage = original.earlyExitPassage
                    sessions[index].ruleSnapshots = original.ruleSnapshots ?? previous.rules.filter { original.ruleIDs.contains($0.id) }
                }
            } else {
                var retained = original
                retained.ruleSnapshots = original.ruleSnapshots ?? previous.rules.filter { original.ruleIDs.contains($0.id) }
                sessions.append(retained)
            }
        }
        result.lockdownSessions = sessions

        // Restore any rule a surviving session depends on.
        let needed = sessions
            .filter { $0.isActive(at: now) }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.ruleIDs) }
        let present = Set(result.rules.map(\.id))
        for ruleID in needed.subtracting(present) {
            if let rule = previous.rules.first(where: { $0.id == ruleID }) {
                result.rules.append(rule)
            }
        }
        return result
    }
}

/// Starting and ending sessions. Pure, so the rules about what a session may do
/// are testable without a filter or a UI.
enum DesktopLockdownSessionGate {
    /// Durations offered in the UI. Multi-day is the intended use.
    static let offeredDurations: [(label: String, seconds: TimeInterval)] = [
        ("1 hour", 3_600),
        ("4 hours", 4 * 3_600),
        ("12 hours", 12 * 3_600),
        ("24 hours", 86_400),
        ("3 days", 3 * 86_400),
        ("7 days", 7 * 86_400),
        ("30 days", 30 * 86_400)
    ]

    static func makeSession(
        ruleIDs: Set<UUID>,
        duration: TimeInterval,
        lockdown: DesktopLockdownPolicy,
        at now: Date = Date(),
        id: UUID = UUID()
    ) -> DesktopLockdownSession {
        DesktopLockdownSession(
            id: id,
            ruleIDs: ruleIDs,
            startedAt: now,
            endsAt: now.addingTimeInterval(max(60, duration)),
            lockdown: lockdown,
            earlyExitPassage: DesktopRemovalGate.passage(
                wordCount: max(0, lockdown.passageWordCount),
                seed: id
            )
        )
    }

    static func passageMatches(_ typed: String, session: DesktopLockdownSession) -> Bool {
        func words(_ value: String) -> [String] {
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let required = words(session.earlyExitPassage)
        guard !required.isEmpty else { return true }
        return words(typed) == required
    }

    /// Formats a remaining duration for display.
    static func remainingDescription(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(1, minutes))m"
    }
}
