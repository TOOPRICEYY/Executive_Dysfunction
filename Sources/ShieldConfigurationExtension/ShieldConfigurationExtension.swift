import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private var shield: ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor.systemIndigo.withAlphaComponent(0.72),
            icon: UIImage(systemName: "lock.shield.fill"),
            title: .init(text: "This activity is protected", color: .white),
            subtitle: .init(
                text: "A focus schedule or usage limit is active. Open Executive Dysfunction to review the rule.",
                color: UIColor.white.withAlphaComponent(0.82)
            ),
            primaryButtonLabel: .init(text: "Close", color: .white),
            primaryButtonBackgroundColor: .systemIndigo
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration { shield }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration { shield }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { shield }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration { shield }
}

