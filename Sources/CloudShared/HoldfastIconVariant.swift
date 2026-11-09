import Foundation

enum HoldfastIconVariant {
    static let themes = ["light", "dark"]
    static let highlights = [
        "themeDefault",
        "signalYellow",
        "phosphorGreen",
        "electricBlue",
        "warningOrange",
        "hotMagenta",
        "terminalViolet"
    ]

    /// The catalog's primary `AppIcon` holds this variant, so it is the one
    /// iOS shows before the app has ever run.
    static let primaryTheme = "light"
    static let primaryHighlight = "themeDefault"

    static var primaryAssetName: String {
        assetName(theme: primaryTheme, highlight: primaryHighlight)
    }

    /// Whether `theme` and `highlight` resolve to the primary icon rather than
    /// to an alternate that has to be installed at runtime.
    static func isPrimary(theme: String, highlight: String) -> Bool {
        assetName(theme: theme, highlight: highlight) == primaryAssetName
    }

    static func assetName(theme: String, highlight: String) -> String {
        let normalizedTheme = theme == "dark" ? "Dark" : "Light"
        let normalizedHighlight = highlights.contains(highlight) ? highlight : "themeDefault"
        return "HoldfastIcon\(normalizedTheme)\(normalizedHighlight.uppercasingFirstCharacter)"
    }

    static var allAssetNames: [String] {
        themes.flatMap { theme in
            highlights.map { assetName(theme: theme, highlight: $0) }
        }
    }
}

private extension String {
    var uppercasingFirstCharacter: String {
        guard let first else { return self }
        return first.uppercased() + String(dropFirst())
    }
}
