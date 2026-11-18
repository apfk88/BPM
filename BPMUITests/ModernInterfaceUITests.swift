import XCTest

final class ModernInterfaceUITests: XCTestCase {
    @MainActor
    func testViewerSetBellsSettingPersistsAcrossLaunches() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let bells = app.switches["Viewer Set Bells"].firstMatch
        func openSetting() {
            launchHome(app)
            app.buttons["settingsButton"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            for _ in 0..<5 where !bells.isHittable || bells.frame.maxY > app.frame.maxY - 40 {
                app.swipeUp()
            }
            XCTAssertTrue(bells.isHittable)
        }

        openSetting()
        let initial = try XCTUnwrap(bells.value as? String)
        let toggled = initial == "1" ? "0" : "1"
        // SwiftUI exposes the whole settings row as a switch.
        let switchPosition = CGVector(dx: 0.9, dy: 0.5)
        bells.coordinate(withNormalizedOffset: switchPosition).tap()
        XCTAssertEqual(bells.value as? String, toggled)
        app.terminate()
        openSetting()
        XCTAssertEqual(bells.value as? String, toggled)
        bells.coordinate(withNormalizedOffset: switchPosition).tap()
        XCTAssertEqual(bells.value as? String, initial)
        app.terminate()
    }

    @MainActor
    func testHostSetRowsShowTenthsForSetTimeAndWholeSecondsForTotal() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launchHome(app)
        defer { app.terminate() }
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 2) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }

        func assertTimes(in identifier: String) {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let label = row.label
            XCTAssertNotNil(label.range(of: #"\d+:\d{2}\.\d\b.*\b\d+:\d{2}$"#, options: .regularExpression), label)
        }

        assertTimes(in: "activeWorkoutSet")
        app.buttons["Rest Set"].tap()
        assertTimes(in: "completedWorkoutSet")
        assertTimes(in: "activeWorkoutSet")
    }

    @MainActor
    func testTripleTapUndoesASetOnlyOnTheWorkoutTable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launchHome(app)
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        let start = app.alerts["Start Workout"].buttons["Start from now"]
        if start.waitForExistence(timeout: 2) { start.tap() }

        let table = app.scrollViews["workoutSetsTable"]
        let alert = app.alerts["Undo current set?"]
        table.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(alert.exists)
        let rest = app.buttons["Rest Set"]
        rest.tap()
        XCTAssertFalse(rest.isEnabled)
        table.doubleTap()
        XCTAssertFalse(alert.exists)
        table.swipeLeft()
        XCTAssertTrue(app.otherElements["Timer view page: bpm"].waitForExistence(timeout: 3))
        app.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(alert.exists)
        app.swipeRight()
        XCTAssertTrue(app.otherElements["Timer view page: table"].waitForExistence(timeout: 3))

        let activeRow = app.descendants(matching: .any).matching(identifier: "activeWorkoutSet").firstMatch
        activeRow.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertFalse(rest.isEnabled)
        let bpmColumn = app.staticTexts["workoutSetBPMColumn"]
        bpmColumn.tap()
        XCTAssertTrue(bpmColumn.wait(for: \.label, toEqual: "Max BPM", timeout: 3))
        bpmColumn.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Undo Set"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertEqual(bpmColumn.label, "Max BPM")
        XCTAssertTrue(rest.isEnabled)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "completedWorkoutSet").count, 0)
        XCTAssertTrue(app.buttons["Pause"].isEnabled)
        app.resetWorkoutAndReturnHome()
    }

    @MainActor
    func testNewWorkAndRestSetsScrollIntoView() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", ""]
        launchHome(app)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 2) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        let table = app.scrollViews["workoutSetsTable"]
        let active = app.descendants(matching: .any).matching(identifier: "activeWorkoutSet").firstMatch
        func assertActiveSetVisible() {
            let visible = NSPredicate { _, _ in
                active.exists && active.isHittable && active.frame.minY >= table.frame.minY + 30
                    && active.frame.maxY <= table.frame.maxY + 1
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5), .completed)
        }
        for _ in 0..<14 {
            app.buttons["Rest Set"].tap()
            assertActiveSetVisible()
            app.buttons["Work Set"].tap()
            assertActiveSetVisible()
        }
        // Work-to-work keeps the same active-row ID, but still needs a scroll.
        app.buttons["Work Set"].tap()
        assertActiveSetVisible()
        screenshot("Active work set below a full portrait table")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["Rest Set"].tap()
        assertActiveSetVisible()
        app.buttons["Work Set"].tap()
        assertActiveSetVisible()
        screenshot("Active work set below a full landscape table")
    }

    @MainActor
    func testDeviceCodeEntryAndNavigationAtAccessibilityTextSize() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchHome(app)
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 5))
        for label in ["Device", "Workout", "HRV", "Settings"] {
            assertVisible(app.buttons[label], in: app)
        }
        screenshot("Home with accessibility text")

        app.buttons["Device"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        let friendDisclosure = app.buttons["View a Friend's BPM"]
        for _ in 0..<4 where !friendDisclosure.isHittable || friendDisclosure.frame.maxY > app.frame.maxY - 40 {
            app.swipeUp()
        }
        friendDisclosure.tap()
        let codeField = app.textFields["Friend code"]
        for _ in 0..<4 where !codeField.isHittable { app.swipeUp() }
        XCTAssertTrue(codeField.waitForExistence(timeout: 3))
        codeField.tap()
        codeField.typeText("12345")
        XCTAssertFalse(app.buttons["Connect"].isEnabled)
        codeField.typeText("6")
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        screenshot("Accessible friend code entry")
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.exists && hideKeyboard.isHittable {
            hideKeyboard.tap()
        }
        app.navigationBars["Select Device"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        let settings = app.buttons["Settings"]
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: settings)
        waitForExpectations(timeout: 5)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let calorieSettings = app.buttons["calorieSettingsLink"]
        let settingsList = app.collectionViews.firstMatch
        for _ in 0..<12 where !calorieSettings.isHittable {
            settingsList.swipeUp()
        }
        XCTAssertTrue(calorieSettings.isHittable)
        calorieSettings.tap()
        XCTAssertTrue(app.navigationBars["Calorie Settings"].waitForExistence(timeout: 5))
        screenshot("Settings navigation with accessibility text")
    }

    @MainActor
    func testSaveCancellationAndAdaptiveChart() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launchHome(app)
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 5))
        app.buttons["Device"].tap()
        let monitor = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator HR Monitor")).firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        screenshot("Home with simulated heart rate")
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 2) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Work Set"].waitForExistence(timeout: 5))
        app.buttons["Work Set"].tap()
        app.buttons["Rest Set"].tap()
        // Record long enough for the chart to offer a meaningful zoom range.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "0:12")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["End"].tap()
        XCTAssertTrue(app.buttons["resumeEndedWorkout"].waitForExistence(timeout: 5))
        app.buttons["resumeEndedWorkout"].tap()
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save Workout"].exists)
        app.buttons["End"].tap()
        XCTAssertTrue(app.buttons["Save Workout"].waitForExistence(timeout: 5))
        app.buttons["Save Workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout Type"].waitForExistence(timeout: 5))
        app.buttons["Functional Strength"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Save Workout"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save Workout"].waitForExistence(timeout: 5))

        app.buttons["Save Workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout Type"].waitForExistence(timeout: 5))
        app.buttons["Functional Strength"].firstMatch.tap()
        let title = "UI review \(UUID().uuidString.prefix(6))"
        let titleField = app.textFields["Title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.textViews["Workout description"].tap()
        app.textViews["Workout description"].typeText("Steady effort after resuming.")
        app.buttons["Save"].tap()
        // Decline Apple Health access on the isolated simulator.
        if app.navigationBars["Health Access"].waitForExistence(timeout: 10) {
            for _ in 0..<4 where !app.buttons["UIA.Health.DoNotAllow.Button"].isHittable { app.swipeUp() }
            app.buttons["UIA.Health.DoNotAllow.Button"].tap()
            XCTAssertTrue(app.navigationBars["Health Access"].waitForNonExistence(timeout: 5))
        }
        if app.alerts["Health Access"].waitForExistence(timeout: 3) {
            app.alerts["Health Access"].buttons["OK"].tap()
        }
        let savedCard = app.buttons["openSavedWorkout"]
        XCTAssertTrue(savedCard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workout saved"].exists)
        XCTAssertTrue(savedCard.label.contains(title))
        XCTAssertFalse(app.buttons["closeWorkoutShareDrawer"].exists)
        XCTAssertFalse(app.buttons["shareSelectedWorkoutFormat"].exists)
        screenshot("Workout saved chart card")
        savedCard.tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editSavedWorkout"].exists)
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
        app.navigationBars["Workout"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let healthDeny = app.buttons["UIA.Health.DoNotAllow.Button"]
        if healthDeny.waitForExistence(timeout: 5) {
            healthDeny.tap()
            XCTAssertTrue(healthDeny.waitForNonExistence(timeout: 5))
            app.buttons["Settings"].tap()
        }
        app.swipeUp()
        app.buttons["Workout History"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        let expand = app.buttons["Expand heart rate chart"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(app.buttons["Close chart"].waitForExistence(timeout: 5))
        for label in ["Close chart", "Peak labels", "Zoom in", "Zoom out", "Reset zoom"] {
            assertVisible(app.buttons[label], in: app)
        }
        screenshot("Expanded chart portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        screenshot("Expanded chart landscape before interaction")
        for label in ["Close chart", "Peak labels", "Zoom in", "Zoom out", "Reset zoom"] {
            assertVisible(app.buttons[label], in: app)
        }
        app.buttons["Peak labels"].tap()
        XCTAssertEqual(app.buttons["Peak labels"].value as? String, "On")
        screenshot("Expanded chart landscape")
        app.buttons["Close chart"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launchHome(_ app: XCUIApplication) {
        // A previous sharing test may leave a persisted viewer code behind.
        app.launchArguments += ["-BPM_FriendCode", ""]
        app.launch()
        app.resetWorkoutAndReturnHome()
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists, "\(element.label) must exist")
        if element.isEnabled {
            XCTAssertTrue(element.isHittable, "\(element.label) must be reachable")
        }
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(element.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
