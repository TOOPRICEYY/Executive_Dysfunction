import Foundation
import ManagedSettings

final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        handle(
            action: action,
            eligibleRuleIDs: ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
                forApplication: application,
                rules: rules
            ),
            completionHandler: completionHandler
        )
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        handle(
            action: action,
            eligibleRuleIDs: ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
                forWebDomain: webDomain,
                rules: rules
            ),
            completionHandler: completionHandler
        )
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        handle(
            action: action,
            eligibleRuleIDs: ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
                forCategory: category,
                rules: rules
            ),
            completionHandler: completionHandler
        )
    }

    private func handle(
        action: ShieldAction,
        eligibleRuleIDs: [UUID],
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        guard action != .primaryButtonPressed else {
            completionHandler(.close)
            return
        }
        guard !eligibleRuleIDs.isEmpty else {
            completionHandler(.close)
            return
        }

        let duration = duration(for: action)
        guard action == .secondaryButtonPressed || duration != nil else {
            completionHandler(.none)
            return
        }

        ShieldTemporaryAccessCoordinator.savePendingRequest(
            eligibleRuleIDs: eligibleRuleIDs,
            duration: duration,
            now: Date()
        )
        completionHandler(.defer)
    }

    private func duration(for action: ShieldAction) -> TemporaryAccessDuration? {
        guard #available(iOS 26.4, *) else { return nil }
        switch action {
        case .firstSecondarySubmenuItemPressed: return .tenMinutes
        case .secondSecondarySubmenuItemPressed: return .thirtyMinutes
        case .thirdSecondarySubmenuItemPressed: return .sixtyMinutes
        default: return nil
        }
    }
}
