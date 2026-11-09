#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import Holdfast

final class IOSPassageInputTests: XCTestCase {
    @MainActor
    func testBulkEntryIsRejectedButIndividualCharactersAndDeletionWork() {
        let coordinator = IOSPassageInput(text: .constant("")).makeCoordinator()
        let view = DirectTypingUITextView()
        let range = NSRange(location: 0, length: 0)
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: range, replacementText: "pasted passage"))
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: "a"))
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: " "))
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: ""))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.text = "typed"
        view.paste(nil)
        XCTAssertEqual(view.text, "typed")
    }
}
#endif
