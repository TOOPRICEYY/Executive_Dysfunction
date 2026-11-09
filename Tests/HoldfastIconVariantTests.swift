import XCTest
#if !DESKTOP_HOSTLESS_TESTS
@testable import Holdfast
#endif

final class HoldfastIconVariantTests: XCTestCase {
    func testEveryThemeAndHighlightMapsToAUniqueAsset() {
        let names = HoldfastIconVariant.allAssetNames

        XCTAssertEqual(names.count, 14)
        XCTAssertEqual(Set(names).count, 14)
        XCTAssertTrue(names.contains("HoldfastIconLightElectricBlue"))
        XCTAssertTrue(names.contains("HoldfastIconDarkThemeDefault"))
    }

    func testUnknownValuesFallBackToLightThemeDefault() {
        XCTAssertEqual(
            HoldfastIconVariant.assetName(theme: "system", highlight: "unknown"),
            "HoldfastIconLightThemeDefault"
        )
    }
}

extension HoldfastIconVariantTests {
    /// The catalog's primary AppIcon holds the light/theme-default variant. If
    /// the app asked for that variant by name it would install an identical
    /// alternate and make iOS report an icon change on every fresh install.
    func testDefaultAppearanceResolvesToThePrimaryIcon() {
        XCTAssertTrue(HoldfastIconVariant.isPrimary(theme: "light", highlight: "themeDefault"))
        XCTAssertEqual(HoldfastIconVariant.primaryAssetName, "HoldfastIconLightThemeDefault")
    }

    func testNonDefaultAppearancesRequireAnAlternateIcon() {
        XCTAssertFalse(HoldfastIconVariant.isPrimary(theme: "dark", highlight: "themeDefault"))
        XCTAssertFalse(HoldfastIconVariant.isPrimary(theme: "light", highlight: "hotMagenta"))
    }

    /// An unrecognised highlight falls back to the theme default, so a light
    /// theme with unusable stored state still resolves to the primary icon.
    func testUnknownHighlightOnLightThemeStillResolvesToThePrimaryIcon() {
        XCTAssertTrue(HoldfastIconVariant.isPrimary(theme: "light", highlight: "notAColor"))
    }

    func testEveryGeneratedVariantIsNamedInTheAllAssetNamesList() {
        XCTAssertTrue(HoldfastIconVariant.allAssetNames.contains(HoldfastIconVariant.primaryAssetName))
        XCTAssertEqual(HoldfastIconVariant.allAssetNames.count, 14)
    }
}
