import Foundation

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

    func isActive(at date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }

    func remaining(at date: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(date))
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
            if let proposed = proposedByID[original.id] {
                // Present, but its end may have been pulled in. Only a later
                // end is accepted without authorization; extending a commitment
                // is always allowed.
                if proposed.endsAt < original.endsAt,
                   let index = sessions.firstIndex(where: { $0.id == original.id }) {
                    sessions[index].endsAt = original.endsAt
                }
            } else {
                sessions.append(original)
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
        ("Rest of today", 12 * 3_600),
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
