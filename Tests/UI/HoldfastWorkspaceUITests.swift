import XCTest

/// Simulator smoke coverage for the iOS workspace shell.
///
/// Screen Time authorization is unavailable in a simulator, so nothing here can
/// assert enforcement. What it can assert is the class of failure a unit test
/// never sees: a tab that does not exist, a sheet that traps on a missing
/// environment object, or a primary action that the tab bar covers.
@MainActor
final class HoldfastWorkspaceUITests: XCTestCase {
    func testBypassHistoryOpensAndOffersConfigurableFilters() {
        app.tabBars.buttons["Dashboard"].tap()
        // Bypass statistics are folded below the fold; expand them first.
        let section = app.buttons["section-bypasses"]
        for _ in 0..<8 where !section.isHittable { app.swipeUp() }
        XCTAssertTrue(section.isHittable)
        if section.value as? String != "Expanded" { section.tap() }
        let entry = app.buttons["open-bypass-history"]
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        attach(named: "bypass-status-panel")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Bypass history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bypass-intent-filter"].exists)
        app.buttons["bypass-intent-filter"].tap()
        XCTAssertTrue(app.buttons["e-dulgance"].waitForExistence(timeout: 3))
        app.buttons["e-dulgance"].tap()
        let indulgence = expectation(for: NSPredicate(format: "value == %@", "e-dulgance"),
            evaluatedWith: app.buttons["bypass-intent-filter"])
        XCTAssertEqual(XCTWaiter.wait(for: [indulgence], timeout: 5), .completed)
        app.buttons["bypass-intent-filter"].tap()
        XCTAssertTrue(app.buttons["Conscious intervention"].waitForExistence(timeout: 3))
        app.buttons["Conscious intervention"].tap()
        let selected = expectation(for: NSPredicate(format: "value == %@", "Conscious intervention"),
            evaluatedWith: app.buttons["bypass-intent-filter"])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        attach(named: "bypass-history-detail")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Dashboard"].waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Bypass history"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["bypass-intent-filter"].value as? String, "Conscious intervention")
        app.buttons["Done"].tap()
    }
    func testTimedLockdownHasClearScopeAndCannotStartWithoutScreenTime() {
        app.tabBars.buttons["Dashboard"].tap()
        let entry = app.buttons["manage-timed-lockdown"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Lockdown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "across all your devices")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "roughly timed Screen Time window")).firstMatch.exists)
        let start = app.buttons["confirm-timed-lockdown"]
        for _ in 0..<4 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "A simulator without Screen Time must not pretend to start enforcement")
        attach(named: "timed-lockdown-setup")
        app.buttons["Done"].tap()
    }
    func testOptionalPassageBackoffSettingsAppearWithoutSaving() {
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        let allow = app.switches["Allow temporary access"]
        for _ in 0..<12 where !allow.isHittable { app.swipeUp() }
        XCTAssertTrue(allow.isHittable)
        if allow.value as? String == "0" { allow.tap() }
        let backoff = app.switches["Passage backoff"]
        for _ in 0..<3 where !backoff.isHittable { app.swipeUp() }
        XCTAssertTrue(backoff.isHittable)
        XCTAssertEqual(backoff.value as? String, "0")
        app.swipeUp()
        attach(named: "backoff-before-enable")
        backoff.tap()
        let enabled = expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: backoff)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
        attach(named: "backoff-after-enable")
        let reset = app.descendants(matching: .any)["allowance-backoff-reset-days"].firstMatch
        for _ in 0..<3 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.exists)
        attach(named: "optional-passage-backoff")
        XCTAssertTrue(app.staticTexts["TEMPORARY ACCESS POLICY"].exists)
        XCTAssertTrue(app.staticTexts["CHANGE PROTECTION"].exists)
        let warning = app.descendants(matching: .any)["change-policy-warning"].firstMatch
        for _ in 0..<4 where !warning.isHittable { app.swipeUp() }
        XCTAssertTrue(warning.exists, "An unlocked/equally easy change policy must warn about bypassing temporary access")
        app.swipeUp() // Include the complete multiline warning in the artifact.
        attach(named: "separate-change-and-access-policies")
        app.buttons["Cancel"].tap()
    }

    func testBlockingScheduleSummaryIsVisibleAboveEditableFields() {
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        XCTAssertTrue(app.navigationBars["BLOCKING GROUP"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["blocking-schedule-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.isHittable, "Weekly summary should be visible without scrolling")
        let name = app.textFields["Blocking Group name"]
        XCTAssertLessThan(preview.frame.maxY, name.frame.minY)
        attach(named: "blocking-group-top-schedule")
        let compactHeight = preview.frame.height
        XCTAssertLessThan(compactHeight, 120)
        let toggle = app.buttons["blocking-schedule-toggle"]
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertGreaterThan(preview.frame.height, compactHeight + 80)
        attach(named: "blocking-group-expanded-schedule")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertEqual(preview.frame.height, compactHeight, accuracy: 1)
        app.buttons["Cancel"].tap()
    }

    func testBlockingGroupOwnsTargetsWithoutAnActivityGroupStep() {
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        XCTAssertTrue(app.navigationBars["BLOCKING GROUP"].waitForExistence(timeout: 10))
        let picker = app.buttons["choose-blocking-apps"]
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.exists)
        XCTAssertFalse(app.staticTexts["ACTIVITY GROUPS"].exists)
        XCTAssertFalse(app.switches["Social"].exists, "Advanced filters should start collapsed")
        let domains = app.textFields["blocking-website-input"]
        for _ in 0..<3 where !domains.isHittable { app.swipeUp() }
        XCTAssertTrue(domains.exists)
        domains.tap()
        domains.typeText("https://example.com/path,example.org")
        app.buttons["Add websites"].tap()
        XCTAssertTrue(app.staticTexts["example.com"].exists)
        XCTAssertTrue(app.staticTexts["example.org"].exists)
        attach(named: "compact-blocking-group-targets")
        app.buttons["Remove example.org"].tap()
        XCTAssertFalse(app.staticTexts["example.org"].exists)
        domains.tap()
        domains.typeText("example.com,invalid")
        app.buttons["Add websites"].tap()
        XCTAssertEqual(domains.value as? String, "invalid")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "already in this group")).firstMatch.exists)
        app.buttons["Cancel"].tap()
    }

    private var app: XCUIApplication!

    func testRetreatReviewDoesNotStartUntilExplicitConfirmation() {
        // A disabled, simulator-only group provides a selectable fixture.
        let name = "Review fixture " + UUID().uuidString.prefix(6)
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        let nameField = app.textFields["Blocking Group name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        let current = nameField.value as? String ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + name)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.tabBars.buttons["Retreats"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Retreats"].tap()
        app.buttons["New"].tap()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        for _ in 0..<4 where !group.isHittable { app.swipeUp() }
        XCTAssertTrue(group.exists)
        group.tap()
        app.buttons["REVIEW & START"].tap()
        XCTAssertTrue(app.navigationBars["Review retreat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirm-retreat-start"].exists)
        attach(named: "retreat-review")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.navigationBars["RETREAT"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Active · Version 1"].exists)
    }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testEveryWorkspaceTabPresentsItsRoot() {
        XCTAssertFalse(app.tabBars.buttons["Activity Groups"].exists)
        for tab in ["Dashboard", "Retreats", "Settings"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing tab: \(tab)")
            button.tap()
            let title = app.staticTexts[tab.uppercased()]
            XCTAssertTrue(title.waitForExistence(timeout: 5), "\(tab) did not present its root screen")
            attach(named: "tab-\(tab)")
        }
    }

    /// `IOSSettingsHubView` presents `SettingsView` in a sheet. If the environment
    /// object does not reach the sheet, the app traps the moment it is presented.
    func testProtectionSettingsSheetPresents() {
        app.tabBars.buttons["Settings"].tap()
        let entry = app.buttons["PROTECTION & SYSTEM SETTINGS"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(
            app.staticTexts["Screen Time Access"].waitForExistence(timeout: 5),
            "Protection settings sheet did not present"
        )
        attach(named: "protection-settings")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testEditorSheetsPresentAndDismiss() {
        let cases: [(tab: String, open: String, title: String)] = [
            ("Retreats", "New", "RETREAT")
        ]
        for item in cases {
            app.tabBars.buttons[item.tab].tap()
            let add = app.buttons[item.open]
            XCTAssertTrue(add.waitForExistence(timeout: 10), "No \(item.open) button on \(item.tab)")
            add.tap()
            XCTAssertTrue(
                app.navigationBars[item.title].waitForExistence(timeout: 5),
                "\(item.title) editor did not present"
            )
            attach(named: "editor-\(item.title)")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.tabBars.buttons[item.tab].waitForExistence(timeout: 5))
        }
    }

    /// The dashboard's panels end in a primary call to action. Scrolled to the
    /// end, the last of them has to sit clear of the floating tab bar.
    func testDashboardScrollsItsLastActionClearOfTheTabBar() {
        app.tabBars.buttons["Dashboard"].tap()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))

        // The folded bypass section is the dashboard's last action.
        let newRetreat = app.buttons["section-bypasses"]
        XCTAssertTrue(newRetreat.waitForExistence(timeout: 5))

        var previous = CGRect.null
        for _ in 0..<12 {
            let frame = newRetreat.exists ? newRetreat.frame : .null
            if frame == previous { break }
            previous = frame
            scroll.swipeUp()
        }
        attach(named: "dashboard-scrolled-to-end")

        XCTAssertTrue(newRetreat.exists, "NEW RETREAT disappeared while scrolling")
        XCTAssertTrue(newRetreat.isHittable, "NEW RETREAT is not reachable")
        XCTAssertLessThanOrEqual(
            newRetreat.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "NEW RETREAT stays underneath the tab bar at the end of the scroll"
        )
    }

    /// A save the model rejects has to say so. The alert lives on the workspace
    /// root, which a sheet covers, so an editor that does not carry its own
    /// alert fails in silence and simply appears to ignore the button.
    func testRejectedRetreatSaveReportsWhyItFailed() {
        app.tabBars.buttons["Retreats"].tap()
        app.buttons["New"].tap()
        XCTAssertTrue(app.navigationBars["RETREAT"].waitForExistence(timeout: 10))

        app.buttons["SAVE DRAFT"].tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Saving an empty Retreat failed silently")
        attach(named: "rejected-retreat-save")
        XCTAssertTrue(
            alert.staticTexts["A Retreat must contain at least one Blocking Group."].exists,
            "The alert did not explain the rejection"
        )
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["RETREAT"].exists, "The editor should stay open after a rejection")
    }

    /// The schedule grid encodes to `CloudTimeWindow`s through the same codec
    /// the Mac painter uses. Painting the whole week has to collapse to a single
    /// window, which is what the Blocking Group summary reports.
    func testAllowanceScheduleRoundTripsThroughTheSharedCodec() {
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        XCTAssertTrue(app.navigationBars["BLOCKING GROUP"].waitForExistence(timeout: 10))

        let edit = app.buttons["EDIT"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        for _ in 0..<6 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        XCTAssertTrue(app.navigationBars["ALLOWANCE SCHEDULE"].waitForExistence(timeout: 5))
        app.buttons["SELECT ALL"].tap()
        attach(named: "allowance-schedule")
        app.buttons["Done"].tap()

        XCTAssertTrue(
            app.staticTexts["1 ALLOWANCE WINDOW"].waitForExistence(timeout: 5),
            "A fully painted week did not encode to one window"
        )
        let monday = app.descendants(matching: .any)["blocking-schedule-day-2"].firstMatch
        for _ in 0..<6 where !monday.isHittable { app.swipeDown() }
        XCTAssertEqual(monday.value as? String, "No scheduled blocking", "Preview must reflect unsaved allowance changes")
    }

    /// The diagnostics screen has to render its findings on the device. Needing
    /// to export a file before you can read the answer would make it useless in
    /// the moment it is wanted.
    func testDiagnosticsReportRendersAndCanBeOpenedInFull() {
        app.tabBars.buttons["Settings"].tap()
        app.buttons["PROTECTION & SYSTEM SETTINGS"].tap()

        // The row is a NavigationLink wrapping a LabeledContent, so its
        // accessibility label carries the trailing value too.
        let entry = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH %@", "Device Report")
        ).firstMatch
        // The settings list renders lazily, and the row sits below the fold.
        for _ in 0..<6 where !entry.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            entry.waitForExistence(timeout: 10),
            "No diagnostics row in protection settings. Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))"
        )
        entry.tap()

        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Findings"].waitForExistence(timeout: 10),
            "The report did not produce a findings section"
        )
        attach(named: "diagnostics-report")

        let viewFull = app.buttons["View full report"]
        for _ in 0..<8 where !viewFull.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(viewFull.isHittable, "The full-report button never scrolled into reach")
        viewFull.tap()
        attach(named: "diagnostics-after-tap")
        XCTAssertTrue(
            app.navigationBars["Full report"].waitForExistence(timeout: 10),
            "Tapping the full-report button presented nothing"
        )
        attach(named: "diagnostics-full-report")

        // What the rendering contains is asserted in the unit suite, where it is
        // cheap. Reading a report-sized accessibility label here costs minutes.
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
    }

    /// The pause lives in the Blocking Group detail. It must appear only for a
    /// saved, enabled group, since pausing changes enforcement rather than the
    /// draft being edited.
    func testTemporaryPauseIsAbsentFromAnUnsavedBlockingGroup() {
        app.tabBars.buttons["Dashboard"].tap()
        app.buttons["NEW BLOCKING GROUP"].tap()
        XCTAssertTrue(app.navigationBars["BLOCKING GROUP"].waitForExistence(timeout: 10))

        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 {
            scroll.swipeUp()
        }
        attach(named: "blocking-group-unsaved")

        XCTAssertFalse(
            app.staticTexts["DISABLE TEMPORARILY"].exists,
            "An unsaved Blocking Group is not enforcing anything, so it must not offer a pause"
        )
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
