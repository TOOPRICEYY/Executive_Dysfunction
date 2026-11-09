import Foundation
import FamilyControls

enum RuleRestrictionChange: Equatable {
    case strictlyMoreRestrictive
    case equivalent
    case requiresUnlock
}

enum RuleRestrictionEvaluator {
    /// Keep admission and its error list in agreement for rebuilt projections.
    static func requiresArchitectureUnlock(
        existing: BlockingRule, proposed: BlockingRule,
        portableDefinitionUnchanged: Bool,
        portableTargetsSameOrStricter: Bool = true,
        appDefaultLockdown: LockdownConfiguration
    ) -> Bool {
        guard portableTargetsSameOrStricter else { return true }
        if existing == proposed { return false }
        switch compare(existing: existing, proposed: proposed, appDefaultLockdown: appDefaultLockdown) {
        case .strictlyMoreRestrictive: return false
        case .equivalent: return false
        case .requiresUnlock: return true
        }
    }

    static func compare(
        existing: BlockingRule,
        proposed: BlockingRule,
        appDefaultLockdown: LockdownConfiguration
    ) -> RuleRestrictionChange {
        guard existing.id == proposed.id,
              existing.enforcementMode == proposed.enforcementMode
        else { return .requiresUnlock }

        var relations: [ComponentRelation] = []
        relations.append(booleanRelation(old: existing.isEnabled, new: proposed.isEnabled))
        relations.append(selectionRelation(existing: existing, proposed: proposed))
        relations.append(domainRelation(existing: existing, proposed: proposed))
        relations.append(coverageRelation(existing: existing, proposed: proposed))
        relations.append(usageRelation(existing: existing, proposed: proposed))
        relations.append(lockdownRelation(
            old: existing.lockdownPolicy.configuration(appDefault: appDefaultLockdown),
            new: proposed.lockdownPolicy.configuration(appDefault: appDefaultLockdown)
        ))
        relations.append(timeExtensionRelation(old: existing.lockdownPolicy, new: proposed.lockdownPolicy))

        if relations.contains(.weakerOrIncomparable) { return .requiresUnlock }
        return relations.contains(.stricter) ? .strictlyMoreRestrictive : .equivalent
    }

    /// Human-readable dimensions that require the rule's normal unlock flow.
    /// These are deliberately based on enforcement semantics rather than a
    /// raw field diff so a rejection can explain what protection would change.
    static func unlockRequirementReasons(
        existing: BlockingRule,
        proposed: BlockingRule,
        appDefaultLockdown: LockdownConfiguration
    ) -> [String] {
        guard existing.id == proposed.id else {
            return ["The Blocking Group identity would change."]
        }

        var reasons: [String] = []
        if existing.name != proposed.name {
            reasons.append("The name would change from “\(existing.name)” to “\(proposed.name)”.")
        }
        if existing.isEnabled && !proposed.isEnabled {
            reasons.append("Blocking would be disabled.")
        }
        if existing.enforcementMode != proposed.enforcementMode {
            reasons.append("The enforcement mode would change from \(existing.enforcementMode.title) to \(proposed.enforcementMode.title).")
        }

        appendSelectionReasons(existing: existing, proposed: proposed, to: &reasons)
        appendDomainReasons(existing: existing, proposed: proposed, to: &reasons)

        let oldCoverage = weeklyCoverage(of: existing.windows)
        let newCoverage = weeklyCoverage(of: proposed.windows)
        let removedCoverage = oldCoverage.subtracting(newCoverage)
        let removedMinutes = removedCoverage.count
        if removedMinutes > 0 {
            let gaps = scheduleGapDescription(removedCoverage)
            reasons.append(
                "The blocked schedule would lose \(durationDescription(minutes: removedMinutes)) per week. No longer blocked: \(gaps)."
            )
        }

        switch (existing.usageLimitEnabled, proposed.usageLimitEnabled) {
        case (true, false):
            reasons.append("The daily usage budget would be removed.")
        case (true, true) where proposed.dailyUsageLimitMinutes > existing.dailyUsageLimitMinutes:
            reasons.append("The daily usage budget would increase from \(existing.dailyUsageLimitMinutes) to \(proposed.dailyUsageLimitMinutes) minutes.")
        default:
            break
        }

        appendLockdownReasons(
            old: existing.lockdownPolicy.configuration(appDefault: appDefaultLockdown),
            new: proposed.lockdownPolicy.configuration(appDefault: appDefaultLockdown),
            to: &reasons
        )
        if !existing.lockdownPolicy.allowsTimeExtensions,
           proposed.lockdownPolicy.allowsTimeExtensions {
            reasons.append("Temporary access would be enabled.")
        } else if existing.lockdownPolicy.allowsTimeExtensions,
                  proposed.lockdownPolicy.allowsTimeExtensions,
                  proposed.lockdownPolicy.maximumTimeExtensionHours
                    > existing.lockdownPolicy.maximumTimeExtensionHours {
            reasons.append("Maximum temporary access would increase from \(existing.lockdownPolicy.maximumTimeExtensionHours) to \(proposed.lockdownPolicy.maximumTimeExtensionHours) hours.")
        }

        if existing.lockdownPolicy.temporaryAllowanceResetDays != proposed.lockdownPolicy.temporaryAllowanceResetDays {
            let oldDays = existing.lockdownPolicy.temporaryAllowanceResetDays ?? 0
            let newDays = proposed.lockdownPolicy.temporaryAllowanceResetDays ?? 0
            if newDays < oldDays { reasons.append("The temporary-access passage backoff would be removed or reset sooner.") }
        }
        if existing.lockdownPolicy.allowsTimeExtensions, proposed.lockdownPolicy.allowsTimeExtensions,
           proposed.lockdownPolicy.effectiveTemporaryAccessPassageWordCount < existing.lockdownPolicy.effectiveTemporaryAccessPassageWordCount {
            reasons.append("The temporary-access passage would become shorter.")
        }
        if reasons.isEmpty, existing != proposed {
            if existing.windows != proposed.windows {
                reasons.append("The stored schedule definition would be rewritten, although its effective blocked coverage is unchanged.")
            }
            if existing.selectionData != proposed.selectionData {
                reasons.append("The stored app, category, or website selection would be rewritten, although its effective selected targets appear unchanged.")
            }
            if existing.classifiedDomains != proposed.classifiedDomains
                || existing.websiteCategories != proposed.websiteCategories {
                reasons.append("Website classification data would change outside the currently enforced domain set.")
            }
            if reasons.isEmpty {
                reasons.append("Only protected rule metadata would change; no effective enforcement dimension is less restrictive.")
            }
        }
        return reasons
    }

    private static func appendSelectionReasons(
        existing: BlockingRule,
        proposed: BlockingRule,
        to reasons: inout [String]
    ) {
        let old = existing.selection
        let new = proposed.selection
        guard old.applicationTokens != new.applicationTokens
                || old.categoryTokens != new.categoryTokens
                || old.webDomainTokens != new.webDomainTokens
        else { return }

        switch existing.enforcementMode {
        case .blockList:
            appendRemovedTargetCount(
                old.applicationTokens.subtracting(new.applicationTokens).count,
                kind: "app",
                to: &reasons
            )
            appendRemovedTargetCount(
                old.categoryTokens.subtracting(new.categoryTokens).count,
                kind: "Apple category",
                to: &reasons
            )
            appendRemovedTargetCount(
                old.webDomainTokens.subtracting(new.webDomainTokens).count,
                kind: "website",
                to: &reasons
            )
        case .fortressAllowList:
            if existing.usageLimitEnabled || proposed.usageLimitEnabled {
                appendSelectionCountChanges(old: old, new: new, to: &reasons)
                reasons.append("These target changes affect both fortress exceptions and usage measurement, so they are not strictly stronger in every dimension.")
            } else {
                appendAddedExceptionCount(
                    new.applicationTokens.subtracting(old.applicationTokens).count,
                    kind: "app",
                    to: &reasons
                )
                appendAddedExceptionCount(
                    new.webDomainTokens.subtracting(old.webDomainTokens).count,
                    kind: "website",
                    to: &reasons
                )
                if old.categoryTokens != new.categoryTokens {
                    reasons.append("Apple category targets would change from \(old.categoryTokens.count) to \(new.categoryTokens.count) under fortress enforcement.")
                }
            }
        }
    }

    private static func appendRemovedTargetCount(
        _ count: Int,
        kind: String,
        to reasons: inout [String]
    ) {
        guard count > 0 else { return }
        reasons.append("\(count) selected \(kind) target\(count == 1 ? "" : "s") would be removed from blocking.")
    }

    private static func appendAddedExceptionCount(
        _ count: Int,
        kind: String,
        to reasons: inout [String]
    ) {
        guard count > 0 else { return }
        reasons.append("\(count) new \(kind) exception\(count == 1 ? "" : "s") would be added to the fortress allow-list.")
    }

    private static func appendSelectionCountChanges(
        old: FamilyActivitySelection,
        new: FamilyActivitySelection,
        to reasons: inout [String]
    ) {
        let changes = [
            ("app", old.applicationTokens.count, new.applicationTokens.count),
            ("Apple category", old.categoryTokens.count, new.categoryTokens.count),
            ("website", old.webDomainTokens.count, new.webDomainTokens.count)
        ]
        for (kind, oldCount, newCount) in changes where oldCount != newCount {
            reasons.append("Selected \(kind) targets would change from \(oldCount) to \(newCount).")
        }
    }

    private static func appendDomainReasons(
        existing: BlockingRule,
        proposed: BlockingRule,
        to reasons: inout [String]
    ) {
        let changedDomains: Set<String>
        let prefix: String
        switch existing.enforcementMode {
        case .blockList:
            changedDomains = existing.enforcedDomains.subtracting(proposed.enforcedDomains)
            prefix = "Blocked domains would be removed"
        case .fortressAllowList:
            changedDomains = proposed.enforcedDomains.subtracting(existing.enforcedDomains)
            prefix = "New domain exceptions would be added"
        }
        guard !changedDomains.isEmpty else { return }
        let shown = changedDomains.sorted().prefix(3).joined(separator: ", ")
        let remainder = changedDomains.count - min(3, changedDomains.count)
        reasons.append("\(prefix): \(shown)\(remainder > 0 ? " (+\(remainder) more)" : "").")
    }

    private static func appendLockdownReasons(
        old: LockdownConfiguration,
        new: LockdownConfiguration,
        to reasons: inout [String]
    ) {
        if old.isEnabled && !new.isEnabled {
            reasons.append("The modification lock would be removed.")
            return
        }
        guard old.isEnabled, new.isEnabled else { return }
        if new.unlockDelayDays < old.unlockDelayDays {
            reasons.append("The unlock delay would fall from \(old.unlockDelayDays) to \(new.unlockDelayDays) days.")
        }
        if new.passageWordCount < old.passageWordCount {
            reasons.append("The confirmation passage would fall from \(old.passageWordCount) to \(new.passageWordCount) words.")
        }
        if new.editWindowHours > old.editWindowHours {
            reasons.append("The unlocked editing window would grow from \(old.editWindowHours) to \(new.editWindowHours) hours.")
        }
        if old.repeatConfirmations && !new.repeatConfirmations {
            reasons.append("Repeated confirmations would be removed.")
        } else if old.repeatConfirmations,
                  new.repeatConfirmations,
                  new.confirmationWindowHours > old.confirmationWindowHours {
            reasons.append("The confirmation window would grow from \(old.confirmationWindowHours) to \(new.confirmationWindowHours) hours.")
        }
    }

    private static func durationDescription(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) minute\(remainder == 1 ? "" : "s")" }
        if remainder == 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours) hour\(hours == 1 ? "" : "s") \(remainder) minutes"
    }

    private static func scheduleGapDescription(_ removedCoverage: Set<Int>) -> String {
        let weekdayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        var ranges: [String] = []
        for weekday in 1...7 {
            var minute = 0
            while minute < 1_440 {
                let weeklyMinute = (weekday - 1) * 1_440 + minute
                guard removedCoverage.contains(weeklyMinute) else {
                    minute += 1
                    continue
                }
                let start = minute
                while minute < 1_440,
                      removedCoverage.contains((weekday - 1) * 1_440 + minute) {
                    minute += 1
                }
                ranges.append(
                    "\(weekdayNames[weekday - 1]) \(clockDescription(start))–\(clockDescription(minute))"
                )
            }
        }
        let shown = ranges.prefix(5).joined(separator: ", ")
        let remainder = ranges.count - min(5, ranges.count)
        return shown + (remainder > 0 ? " (+\(remainder) more ranges)" : "")
    }

    private static func clockDescription(_ minutes: Int) -> String {
        if minutes == 1_440 { return "24:00" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private enum ComponentRelation: Equatable {
        case same
        case stricter
        case weakerOrIncomparable
    }

    /// Enabling an existing rule is stricter; disabling it is weaker.
    private static func booleanRelation(old: Bool, new: Bool) -> ComponentRelation {
        if old == new { return .same }
        return new ? .stricter : .weakerOrIncomparable
    }

    private static func selectionRelation(
        existing: BlockingRule,
        proposed: BlockingRule
    ) -> ComponentRelation {
        let old = existing.selection
        let new = proposed.selection

        switch existing.enforcementMode {
        case .blockList:
            return combine([
                supersetRelation(old: old.applicationTokens, new: new.applicationTokens),
                supersetRelation(old: old.categoryTokens, new: new.categoryTokens),
                supersetRelation(old: old.webDomainTokens, new: new.webDomainTokens)
            ])
        case .fortressAllowList:
            // Fewer individual exceptions means a stricter fortress. Category
            // tokens are not allow-list exceptions. When a usage limit is
            // enabled, all opaque selections also define measured activity;
            // changing them can tighten shielding while weakening measurement,
            // so that mixed edit requires a normal unlock.
            if existing.usageLimitEnabled || proposed.usageLimitEnabled {
                return old.applicationTokens == new.applicationTokens
                    && old.categoryTokens == new.categoryTokens
                    && old.webDomainTokens == new.webDomainTokens
                    ? .same
                    : .weakerOrIncomparable
            }
            let categoryRelation: ComponentRelation = old.categoryTokens == new.categoryTokens
                ? .same
                : .weakerOrIncomparable
            return combine([
                subsetRelation(old: old.applicationTokens, new: new.applicationTokens),
                categoryRelation,
                subsetRelation(old: old.webDomainTokens, new: new.webDomainTokens)
            ])
        }
    }

    private static func domainRelation(
        existing: BlockingRule,
        proposed: BlockingRule
    ) -> ComponentRelation {
        switch existing.enforcementMode {
        case .blockList:
            supersetRelation(old: existing.enforcedDomains, new: proposed.enforcedDomains)
        case .fortressAllowList:
            subsetRelation(old: existing.enforcedDomains, new: proposed.enforcedDomains)
        }
    }

    private static func coverageRelation(
        existing: BlockingRule,
        proposed: BlockingRule
    ) -> ComponentRelation {
        supersetRelation(
            old: weeklyCoverage(of: existing.windows),
            new: weeklyCoverage(of: proposed.windows)
        )
    }

    private static func usageRelation(
        existing: BlockingRule,
        proposed: BlockingRule
    ) -> ComponentRelation {
        switch (existing.usageLimitEnabled, proposed.usageLimitEnabled) {
        case (false, false): return .same
        case (false, true): return .stricter
        case (true, false): return .weakerOrIncomparable
        case (true, true):
            if proposed.dailyUsageLimitMinutes == existing.dailyUsageLimitMinutes { return .same }
            return proposed.dailyUsageLimitMinutes < existing.dailyUsageLimitMinutes
                ? .stricter
                : .weakerOrIncomparable
        }
    }

    private static func lockdownRelation(
        old: LockdownConfiguration,
        new: LockdownConfiguration
    ) -> ComponentRelation {
        if old.isEnabled != new.isEnabled {
            return new.isEnabled ? .stricter : .weakerOrIncomparable
        }
        guard old.isEnabled else { return .same }

        var relations: [ComponentRelation] = [
            higherIsStricter(old: old.unlockDelayDays, new: new.unlockDelayDays),
            higherIsStricter(old: old.passageWordCount, new: new.passageWordCount),
            lowerIsStricter(old: old.editWindowHours, new: new.editWindowHours)
        ]
        if old.repeatConfirmations != new.repeatConfirmations {
            relations.append(new.repeatConfirmations ? .stricter : .weakerOrIncomparable)
        } else if old.repeatConfirmations {
            relations.append(lowerIsStricter(
                old: old.confirmationWindowHours,
                new: new.confirmationWindowHours
            ))
        }
        return combine(relations)
    }

    private static func timeExtensionRelation(
        old: RuleLockdownPolicy,
        new: RuleLockdownPolicy
    ) -> ComponentRelation {
        if old.allowsTimeExtensions != new.allowsTimeExtensions {
            // Removing an escape path is stricter; adding one needs an unlock.
            return new.allowsTimeExtensions ? .weakerOrIncomparable : .stricter
        }
        guard old.allowsTimeExtensions else { return .same }
        if old.temporaryAllowanceResetDays != new.temporaryAllowanceResetDays {
            guard let newDays = new.temporaryAllowanceResetDays,
                  newDays >= (old.temporaryAllowanceResetDays ?? 0) else {
                return .weakerOrIncomparable
            }
        }
        return combine([
            lowerIsStricter(old: old.maximumTimeExtensionHours, new: new.maximumTimeExtensionHours),
            higherIsStricter(old: old.effectiveTemporaryAccessPassageWordCount, new: new.effectiveTemporaryAccessPassageWordCount),
            higherIsStricter(old: old.temporaryAllowanceResetDays ?? 0, new: new.temporaryAllowanceResetDays ?? 0)
        ])
    }

    private static func higherIsStricter(old: Int, new: Int) -> ComponentRelation {
        if old == new { return .same }
        return new > old ? .stricter : .weakerOrIncomparable
    }

    private static func lowerIsStricter(old: Int, new: Int) -> ComponentRelation {
        if old == new { return .same }
        return new < old ? .stricter : .weakerOrIncomparable
    }

    private static func supersetRelation<Element: Hashable>(
        old: Set<Element>,
        new: Set<Element>
    ) -> ComponentRelation {
        if old == new { return .same }
        return new.isSuperset(of: old) ? .stricter : .weakerOrIncomparable
    }

    private static func subsetRelation<Element: Hashable>(
        old: Set<Element>,
        new: Set<Element>
    ) -> ComponentRelation {
        if old == new { return .same }
        return new.isSubset(of: old) ? .stricter : .weakerOrIncomparable
    }

    private static func combine(_ relations: [ComponentRelation]) -> ComponentRelation {
        if relations.contains(.weakerOrIncomparable) { return .weakerOrIncomparable }
        return relations.contains(.stricter) ? .stricter : .same
    }

    /// Minute-resolution union across a repeating Sunday-through-Saturday week.
    private static func weeklyCoverage(of windows: [TimeWindow]) -> Set<Int> {
        let minutesPerDay = 1_440
        let minutesPerWeek = 7 * minutesPerDay
        var result: Set<Int> = []

        for window in windows {
            let duration: Int
            if window.startMinutes < window.endMinutes {
                duration = window.endMinutes - window.startMinutes
            } else {
                duration = minutesPerDay - window.startMinutes + window.endMinutes
            }
            for weekday in window.weekdays {
                let start = (weekday - 1) * minutesPerDay + window.startMinutes
                for offset in 0..<duration {
                    result.insert((start + offset) % minutesPerWeek)
                }
            }
        }
        return result
    }
}
