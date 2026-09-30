import Foundation

enum CloudRuleBridge {
    static func cloudPreference(from rule: BlockingRule) -> CloudRulePreference {
        CloudRulePreference(
            id: rule.id,
            modifiedAt: rule.preferenceModifiedAt,
            name: rule.name,
            isEnabled: rule.isEnabled,
            enforcementMode: rule.enforcementMode.rawValue,
            windows: rule.windows.map {
                CloudTimeWindow(
                    id: $0.id,
                    weekdays: $0.weekdays,
                    startMinutes: $0.startMinutes,
                    endMinutes: $0.endMinutes
                )
            },
            usageLimitEnabled: rule.usageLimitEnabled,
            dailyUsageLimitMinutes: rule.dailyUsageLimitMinutes,
            domains: rule.classifiedDomains.map {
                CloudDomainPreference(
                    domain: $0.domain,
                    category: $0.category.rawValue,
                    source: $0.source.rawValue
                )
            },
            websiteCategories: Set(rule.websiteCategories.map(\.rawValue)),
            lockdown: CloudRuleLockdownPreference(
                severity: rule.lockdownPolicy.severity.rawValue,
                unlockDelayDays: rule.lockdownPolicy.unlockDelayDays,
                passageWordCount: rule.lockdownPolicy.passageWordCount,
                confirmationWindowHours: rule.lockdownPolicy.confirmationWindowHours,
                editWindowHours: rule.lockdownPolicy.editWindowHours,
                allowsTimeExtensions: rule.lockdownPolicy.allowsTimeExtensions,
                maximumTimeExtensionHours: rule.lockdownPolicy.maximumTimeExtensionHours,
                temporaryAllowanceResetDays: rule.lockdownPolicy.temporaryAllowanceResetDays,
                temporaryAccessPassageWordCount: rule.lockdownPolicy.temporaryAccessPassageWordCount
            ),
            deviceLocalSelectionCount: rule.selectedItemCount
        )
    }

    /// Applies portable preferences while retaining the iPhone's opaque
    /// FamilyControls tokens. Those tokens cannot be reconstructed on macOS.
    static func applying(_ cloud: CloudRulePreference, to existing: BlockingRule?) -> BlockingRule {
        var rule = existing ?? BlockingRule()
        rule.id = cloud.id
        rule.preferenceModifiedAt = cloud.modifiedAt
        rule.name = cloud.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.isEnabled = cloud.isEnabled
        rule.enforcementMode = EnforcementMode(rawValue: cloud.enforcementMode) ?? .blockList
        rule.windows = cloud.windows.map {
            TimeWindow(
                id: $0.id,
                weekdays: Set($0.weekdays.filter { 1...7 ~= $0 }),
                startMinutes: max(0, min(1439, $0.startMinutes)),
                endMinutes: max(0, min(1440, $0.endMinutes))
            )
        }
        rule.usageLimitEnabled = cloud.usageLimitEnabled
        rule.dailyUsageLimitMinutes = max(1, min(1440, cloud.dailyUsageLimitMinutes))
        rule.classifiedDomains = cloud.domains.compactMap { value in
            guard let category = WebsiteCategory(rawValue: value.category) else { return nil }
            let source = ClassificationSource(rawValue: value.source) ?? .user
            return ClassifiedDomain(domain: value.domain, category: category, source: source)
        }
        rule.websiteCategories = Set(cloud.websiteCategories.compactMap(WebsiteCategory.init(rawValue:)))
        rule.lockdownPolicy = RuleLockdownPolicy(
            severity: RuleLockdownSeverity(rawValue: cloud.lockdown.severity) ?? .appDefault,
            unlockDelayDays: max(0, min(365, cloud.lockdown.unlockDelayDays)),
            passageWordCount: max(20, min(300, cloud.lockdown.passageWordCount)),
            confirmationWindowHours: max(1, min(48, cloud.lockdown.confirmationWindowHours)),
            editWindowHours: max(1, min(72, cloud.lockdown.editWindowHours)),
            allowsTimeExtensions: cloud.lockdown.allowsTimeExtensions,
            maximumTimeExtensionHours: max(1, min(8, cloud.lockdown.maximumTimeExtensionHours)),
            temporaryAllowanceResetDays: cloud.lockdown.temporaryAllowanceResetDays,
            temporaryAccessPassageWordCount: cloud.lockdown.temporaryAccessPassageWordCount
        )
        return rule
    }
}

enum CloudTombstonePersistence {
    private static let key = "cloud.rule-tombstones.v1"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedConfiguration.appGroupIdentifier) ?? .standard
    }

    static func load() -> [CloudRuleTombstone] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([CloudRuleTombstone].self, from: data)
        else { return [] }
        return values
    }

    static func save(_ values: [CloudRuleTombstone]) {
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
}
