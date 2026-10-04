import XCTest

final class ModernInterfaceUITests: XCTestCase {
    @MainActor
    func testDeviceCodeEntryAndNavigationAtAccessibilityTextSize() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchHome(app)
        XCTAssertTrue(app.buttons["Device"].waitForExistence(timeout: 5))
        for label in ["Device", "Share", "Workout", "HRV", "Settings"] {
            assertVisible(app.buttons[label], in: app)
        }
        screenshot("Home with accessibility text")

        app.buttons["Device"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        app.buttons["View a Friend's BPM"].tap()
        let codeField = app.textFields["Friend code"]
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
        app.buttons["Calorie Settings"].tap()
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
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        screenshot("Home with simulated heart rate")
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Work Set"].waitForExistence(timeout: 5))
        app.buttons["Work Set"].tap()
        app.buttons["Rest Set"].tap()
        // Record long enough for the chart to offer a meaningful zoom range.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "0:12")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["End"].tap()
        app.buttons["Save Workout"].tap()
        app.buttons["Functional Strength"].tap()
        XCTAssertTrue(app.navigationBars["Save Workout"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save Workout"].waitForExistence(timeout: 5))

        app.buttons["Save Workout"].tap()
        app.buttons["Functional Strength"].tap()
        let title = "UI review \(UUID().uuidString.prefix(6))"
        let titleField = app.textFields["Title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["Save"].tap()
        // Decline Apple Health access on the isolated simulator.
        if app.buttons["UIA.Health.DoNotAllow.Button"].waitForExistence(timeout: 10) {
            app.buttons["UIA.Health.DoNotAllow.Button"].tap()
            XCTAssertTrue(app.buttons["UIA.Health.DoNotAllow.Button"].waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.swipeUp()
        app.buttons["Workout History"].tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
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
        app.launch()
        // Recover only the isolated simulator session from an interrupted test.
        if app.buttons["xmark"].waitForExistence(timeout: 2) {
            app.buttons["xmark"].tap()
            if app.alerts["Clear Workout"].waitForExistence(timeout: 1) {
                app.alerts["Clear Workout"].buttons["Clear"].tap()
            }
        }
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
