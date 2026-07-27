import Foundation

enum RuleRestrictionChange: Equatable {
    case strictlyMoreRestrictive
    case equivalent
    case requiresUnlock
}

enum RuleRestrictionEvaluator {
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
        return combine([
            lowerIsStricter(old: old.maximumTimeExtensionHours, new: new.maximumTimeExtensionHours),
            higherIsStricter(old: old.passageWordCount, new: new.passageWordCount)
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
