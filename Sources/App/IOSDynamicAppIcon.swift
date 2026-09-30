import UIKit

@MainActor
enum IOSDynamicAppIcon {
    static func synchronize(theme: String, highlight: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        // The primary AppIcon already holds the light/theme-default variant.
        // Installing it again as an alternate would change nothing except to
        // trigger the system's "you have changed the icon" alert on every
        // fresh install.
        let requested = HoldfastIconVariant.isPrimary(theme: theme, highlight: highlight)
            ? nil
            : HoldfastIconVariant.assetName(theme: theme, highlight: highlight)
        guard UIApplication.shared.alternateIconName != requested else { return }
        UIApplication.shared.setAlternateIconName(requested) { error in
            #if DEBUG
            if let error {
                print("Unable to update Holdfast app icon to \(requested ?? "the primary icon"): \(error.localizedDescription)")
            }
            #endif
        }
    }
}
