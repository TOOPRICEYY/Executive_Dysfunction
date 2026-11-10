import XCTest

/// Simulator smoke coverage for the iOS shell: the shared web interface and the
/// native sheets it opens.
///
/// Screen Time authorization is unavailable in a simulator, so nothing here can
/// assert enforcement. What it can assert is what a unit test never sees: a
/// page that does not load, a status that claims blocking the device cannot
/// deliver, a sheet that traps on a missing environment object, or a sheet
/// with two competing dismiss buttons.
@MainActor
final class HoldfastWorkspaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(tab("Dashboard").waitForExistence(timeout: 30), "The shared interface did not load")
    }

    func testEveryTabPresentsItsPage() {
        let pages: [(tab: String, marker: String)] = [
            ("Retreats", "Live retreats"),
            ("History", "Past retreats"),
            ("Settings", "Device connection"),
            ("Dashboard", "Blocking Groups"),
        ]
        for page in pages {
            tab(page.tab).tap()
            XCTAssertTrue(text(page.marker).waitForExistence(timeout: 5), "\(page.tab) did not present its page")
            attach(named: "tab-\(page.tab)")
        }
    }

    /// The simulator cannot grant Screen Time access, which makes it the exact
    /// state the dashboard must be honest about: a schedule may be due, but
    /// nothing is enforced.
    func testDashboardNeverClaimsBlockingWithoutScreenTime() {
        XCTAssertTrue(text("Nothing is being blocked").waitForExistence(timeout: 5))
        XCTAssertTrue(button("Allow Screen Time access").isHittable, "The way to start blocking must not be hidden")
        addWorkHoursPresetIfMissing()
        XCTAssertTrue(button("Edit Work hours").waitForExistence(timeout: 5))
        XCTAssertFalse(text(containing: "Blocking now").exists, "A group claims to block while Screen Time access is off")
        XCTAssertFalse(text(containing: "Blocked until").exists, "A group claims to block while Screen Time access is off")
        attach(named: "dashboard-not-enforced")
    }

    /// The page draws edge to edge and pads for the status bar itself. Its title
    /// has to stay below the status bar and its tabs above the home indicator.
    func testPageKeepsClearOfTheStatusBarAndHomeIndicator() {
        let title = text("Dashboard")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(title.frame.minY, 44, "The page title sits under the status bar")
        XCTAssertLessThanOrEqual(tab("Settings").frame.maxY, screen.maxY - 16, "The tabs sit under the home indicator")
        XCTAssertTrue(tab("Settings").isHittable)
    }

    func testGroupEditorOpensAtItsTopAndCloses() {
        addWorkHoursPresetIfMissing()
        button("Edit Work hours").tap()
        let close = button("Close dialog")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The group editor did not open")
        XCTAssertTrue(close.isHittable, "The editor opened scrolled away from its title bar")
        attach(named: "group-editor")
        close.tap()
        XCTAssertTrue(waitForDisappearance(of: close), "The group editor did not close")
        XCTAssertTrue(tab("Dashboard").isHittable)
    }

    /// Starting a lockdown is part of the shared interface now. No native
    /// sheet opens, and nothing can start before a group is chosen.
    func testLockdownOpensInTheSharedInterfaceAndCannotStartEmpty() {
        button("Lockdown").tap()
        XCTAssertTrue(text("Start a lockdown").waitForExistence(timeout: 5), "The lockdown dialog did not open")
        XCTAssertFalse(app.navigationBars["Lockdown"].exists, "The native lockdown sheet opened as well")
        let start = button("Start lockdown")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "A lockdown must not start with no group selected")
        attach(named: "lockdown-dialog")
        button("Cancel").tap()
        XCTAssertTrue(waitForDisappearance(of: start), "The lockdown dialog did not close")
        XCTAssertTrue(tab("Dashboard").isHittable)
    }

    /// The report is built by the device and shown by the shared interface.
    /// It has to arrive with real content, not an empty dialog.
    func testDiagnosticsReportRendersInTheSharedInterface() {
        tab("Settings").tap()
        let open = button("Open diagnostics")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(text("Diagnostic report").waitForExistence(timeout: 10), "The diagnostics dialog did not open")
        XCTAssertFalse(app.navigationBars["Diagnostics"].exists, "The native diagnostics sheet opened as well")
        let copy = button("Copy report")
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: copy)], timeout: 15), .completed,
            "The device did not return a report")
        XCTAssertTrue(text(containing: "finding").exists || text(containing: "No inconsistencies").exists,
            "The report has no findings summary")
        attach(named: "diagnostics-report")
        button("Close").tap()
        XCTAssertTrue(waitForDisappearance(of: copy), "The diagnostics dialog did not close")
        XCTAssertTrue(tab("Settings").isHittable)
    }

    /// The native editors are reached through a sheet. If the environment object
    /// does not reach it, the app traps the moment it is presented.
    func testAdvancedControlsSheetPresentsAndCloses() {
        tab("Settings").tap()
        let open = button("Advanced native controls")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.staticTexts["Advanced native controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Dashboard"].waitForExistence(timeout: 5), "The native workspace did not present")
        XCTAssertEqual(app.state, .runningForeground)
        attach(named: "advanced-controls")
        app.buttons["Close"].tap()
        XCTAssertTrue(tab("Settings").waitForExistence(timeout: 5))
    }

    func testRetreatEditorPresentsAndDismisses() {
        tab("Retreats").tap()
        let new = button("New retreat")
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        XCTAssertTrue(app.navigationBars["RETREAT"].waitForExistence(timeout: 5), "The retreat editor did not present")
        XCTAssertFalse(app.buttons["Close"].exists, "The sheet has a second dismiss button above its own")
        attach(named: "retreat-editor")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(tab("Retreats").waitForExistence(timeout: 5))
    }

    /// A refused or unavailable Screen Time request has to say so in plain words
    /// and leave the dashboard honest, rather than fail in silence.
    func testRefusedScreenTimeAccessIsReportedAndNothingClaimsToBlock() {
        let allow = button("Allow Screen Time access")
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        // The system may show its own permission prompt first.
        let prompt = app.alerts.firstMatch
        if prompt.waitForExistence(timeout: 3) {
            let refuse = prompt.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch
            (refuse.exists ? refuse : prompt.buttons.firstMatch).tap()
        }
        XCTAssertTrue(text(containing: "Screen Time access was not granted").waitForExistence(timeout: 15),
            "A failed Screen Time request was not explained")
        XCTAssertTrue(text("Nothing is being blocked").exists)
        XCTAssertTrue(allow.exists, "The request must stay available to try again")
        attach(named: "screen-time-refused")
    }

    // MARK: Web content

    private func tab(_ name: String) -> XCUIElement { button(name) }

    /// Buttons rendered by the shared interface. CSS may change the case a label
    /// is drawn in, so labels are matched without regard to it.
    private func button(_ label: String) -> XCUIElement {
        app.webViews.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    /// Gives the dashboard one scheduled group, so there is a row whose state
    /// can be read and whose editor can be opened. Kept across runs.
    private func addWorkHoursPresetIfMissing() {
        let row = button("Edit Work hours")
        if row.waitForExistence(timeout: 2) { return }
        button("Add").tap()
        let preset = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Work hours")).firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "The add menu offers no Work hours preset")
        preset.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The Work hours preset was not added")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
