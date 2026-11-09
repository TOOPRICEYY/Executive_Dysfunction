import Foundation

extension CloudPreferencesDocument {
    /// A Retreat group together with the planned interval in which it applies.
    struct ScheduledRetreatRule: Equatable {
        var rule: CloudRulePreference
        var start: Date
        var end: Date
    }

    /// Rules of Retreats that are running now or start within `horizon`, each
    /// with its planned interval.
    ///
    /// The live projection (`compiledRules(at:)`) only contains Retreats that
    /// are active at the moment of compilation, so a Retreat used to start or
    /// end only when the app happened to recompile. Publishing the interval
    /// with the rule lets the enforcer switch it on and off by itself.
    func scheduledRetreatRules(
        from now: Date = Date(),
        horizon: TimeInterval = 14 * 86_400
    ) -> [ScheduledRetreatRule] {
        var result: [ScheduledRetreatRule] = []
        for retreat in retreats {
            guard retreat.state == .scheduled || retreat.state == .active,
                  retreat.plannedEnd > now,
                  retreat.plannedStart < now.addingTimeInterval(horizon),
                  retreat.plannedStart < retreat.plannedEnd,
                  let version = retreat.currentVersion else { continue }
            let evaluationDate = max(retreat.plannedStart, now)
            let ids = Set(version.blockingGroups.map(\.id))
            for rule in compiledRules(at: evaluationDate) where ids.contains(rule.id) {
                result.append(ScheduledRetreatRule(rule: rule, start: retreat.plannedStart, end: retreat.plannedEnd))
            }
        }
        return result
    }
}
