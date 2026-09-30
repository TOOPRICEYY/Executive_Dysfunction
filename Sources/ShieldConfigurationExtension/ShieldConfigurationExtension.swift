import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        shield(for: eligibleRuleIDs(for: application))
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        shield(for: eligibleRuleIDs(for: application, in: category))
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        shield(for: eligibleRuleIDs(for: webDomain))
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        shield(for: eligibleRuleIDs(for: webDomain, in: category))
    }

    private func shield(for eligibleRuleIDs: [UUID]) -> ShieldConfiguration {
        let pendingRequest = ShieldTemporaryAccessCoordinator.loadPendingRequest(now: Date())
        let requestMatchesShield = pendingRequest.map {
            !Set($0.eligibleRuleIDs).isDisjoint(with: eligibleRuleIDs)
        } ?? false

        let subtitle: String
        if requestMatchesShield {
            subtitle = "Open Holdfast and type the confirmation passage to continue."
        } else if eligibleRuleIDs.isEmpty {
            subtitle = "A focus schedule or usage limit is active. Open Holdfast to review the rule."
        } else {
            subtitle = "A focus rule is active. Temporary access is available after a confirmation passage."
        }

        if #available(iOS 26.4, *), !eligibleRuleIDs.isEmpty, !requestMatchesShield {
            return ShieldConfiguration(
                backgroundBlurStyle: .systemMaterialDark,
                backgroundColor: UIColor.systemIndigo.withAlphaComponent(0.72),
                icon: UIImage(systemName: "lock.shield.fill"),
                title: .init(text: "This activity is protected", color: .white),
                subtitle: .init(text: subtitle, color: UIColor.white.withAlphaComponent(0.82)),
                primaryButtonLabel: .init(text: "Close", color: .white),
                primaryButtonBackgroundColor: .systemIndigo,
                secondaryButtonLabel: .init(text: "Temporarily Disable Filter", color: .white),
                secondaryButtonSubmenuItems: ["10 minutes", "30 minutes", "60 minutes"]
            )
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor.systemIndigo.withAlphaComponent(0.72),
            icon: UIImage(systemName: "lock.shield.fill"),
            title: .init(text: "This activity is protected", color: .white),
            subtitle: .init(text: subtitle, color: UIColor.white.withAlphaComponent(0.82)),
            primaryButtonLabel: .init(text: "Close", color: .white),
            primaryButtonBackgroundColor: .systemIndigo,
            secondaryButtonLabel: eligibleRuleIDs.isEmpty || requestMatchesShield
                ? nil
                : .init(text: "Request Temporary Access", color: .white)
        )
    }

    private func eligibleRuleIDs(for application: Application) -> [UUID] {
        guard let token = application.token else { return [] }
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        return ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            forApplication: token,
            rules: rules
        )
    }

    private func eligibleRuleIDs(
        for _: Application,
        in category: ActivityCategory
    ) -> [UUID] {
        guard let token = category.token else { return [] }
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        return ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            forCategory: token,
            rules: rules
        )
    }

    private func eligibleRuleIDs(for webDomain: WebDomain) -> [UUID] {
        guard let token = webDomain.token else { return [] }
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        return ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            forWebDomain: token,
            rules: rules
        )
    }

    private func eligibleRuleIDs(
        for _: WebDomain,
        in category: ActivityCategory
    ) -> [UUID] {
        guard let token = category.token else { return [] }
        let rules = ShieldTemporaryAccessCoordinator.loadRules()
        return ShieldTemporaryAccessCoordinator.eligibleRuleIDs(
            forCategory: token,
            rules: rules
        )
    }
}
