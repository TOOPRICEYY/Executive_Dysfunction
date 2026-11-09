import XCTest

final class DesktopNetworkExtensionRemovalAuthorizationTests: XCTestCase {
    func testFixedPassageHasEightyWordsAndNamesTheConsequences() {
        let passage = DesktopNetworkExtensionRemovalGate.requiredPassage

        XCTAssertEqual(DesktopNetworkExtensionRemovalGate.requiredWordCount, 80)
        XCTAssertEqual(passage.split(whereSeparator: { $0.isWhitespace }).count, 80)
        XCTAssertTrue(passage.contains("will stop filtering on this Mac"))
        XCTAssertTrue(passage.contains("administrator password or approval"))
        XCTAssertTrue(passage.contains("until this Mac restarts"))
        XCTAssertTrue(passage.contains("installed and approved again"))
    }

    func testOnlyTheExactDisplayedPassageAuthorizesRemoval() {
        let passage = DesktopNetworkExtensionRemovalGate.requiredPassage

        XCTAssertEqual(
            DesktopNetworkExtensionRemovalGate.validate(typedPassage: passage),
            .authorized
        )
        XCTAssertEqual(
            DesktopNetworkExtensionRemovalGate.validate(typedPassage: passage.uppercased()),
            .passageMismatch
        )
        XCTAssertEqual(
            DesktopNetworkExtensionRemovalGate.validate(typedPassage: " \(passage)"),
            .passageMismatch
        )
        XCTAssertEqual(
            DesktopNetworkExtensionRemovalGate.validate(typedPassage: String(passage.dropLast())),
            .passageMismatch
        )
        XCTAssertEqual(
            DesktopNetworkExtensionRemovalGate.validate(typedPassage: ""),
            .passageMismatch
        )
    }
}
