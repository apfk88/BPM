import XCTest

final class MaxHeartRateSuggestionUITests: XCTestCase {
    @MainActor
    func testAcceptingNewMaxIsQuietUpdatesBothSettingsAndPreservesCustomZones() {
        let app = launchSuggestionFixture()
        defer { app.terminate() }
        assertPendingSettingsBadge(in: app)

        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["workoutHome"].waitForExistence(timeout: 5))
        assertPendingSettingsBadge(in: app)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["acceptNewMaxHR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["New max detected: 198 BPM"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Quiet max heart rate suggestion in Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["acceptNewMaxHR"].tap()
        XCTAssertTrue(app.buttons["acceptNewMaxHR"].waitForNonExistence(timeout: 3))
        verifyZones(maximum: "198", in: app)
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertNotEqual(app.buttons["settingsButton"].value as? String, "New max HR detected")

        relaunchWithoutFixture(app)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.buttons["settingsButton"].value as? String, "New max HR detected")
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["acceptNewMaxHR"].exists)
        verifyZones(maximum: "198", in: app)
        verifyCalorieMaximum("198", in: app)
    }

    @MainActor
    func testDismissingNewMaxKeepsExistingValuesAndDoesNotReturnOnRelaunch() {
        let app = launchSuggestionFixture()
        defer { app.terminate() }
        assertPendingSettingsBadge(in: app)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["dismissNewMaxHR"].waitForExistence(timeout: 5))
        app.buttons["dismissNewMaxHR"].tap()
        XCTAssertTrue(app.buttons["dismissNewMaxHR"].waitForNonExistence(timeout: 3))
        verifyZones(maximum: "195", in: app)
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertNotEqual(app.buttons["settingsButton"].value as? String, "New max HR detected")

        relaunchWithoutFixture(app)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.buttons["settingsButton"].value as? String, "New max HR detected")
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dismissNewMaxHR"].exists)
        verifyZones(maximum: "195", in: app)
        verifyCalorieMaximum("195", in: app)
    }

    @MainActor
    private func launchSuggestionFixture() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--calorie-setup-ui-test", "--reset-calorie-setup", "--max-hr-suggestion-fixture",
            "-BPM_FriendCode", ""
        ]
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func relaunchWithoutFixture(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--calorie-setup-ui-test", "-BPM_FriendCode", ""]
        app.launch()
    }

    @MainActor
    private func assertPendingSettingsBadge(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "New max HR detected")
        XCTAssertEqual(app.alerts.count, 0, "Max heart rate suggestions must not interrupt with a popup")
    }

    @MainActor
    private func verifyZones(maximum: String, in app: XCUIApplication) {
        let zones = app.buttons["Zone Settings"]
        reveal(zones, in: app)
        zones.tap()
        XCTAssertTrue(app.textFields["zoneMaxHeartRate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["zoneMaxHeartRate"].value as? String, maximum)
        XCTAssertEqual(app.textFields["zone1Minimum"].value as? String, "90")
        XCTAssertEqual(app.textFields["zone1Maximum"].value as? String, "112")
        app.buttons["cancelZones"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func verifyCalorieMaximum(_ maximum: String, in app: XCUIApplication) {
        let calories = app.buttons["calorieSettingsLink"]
        reveal(calories, in: app)
        calories.tap()
        XCTAssertTrue(app.navigationBars["Calorie Settings"].waitForExistence(timeout: 5))
        let field = app.textFields["Max HR"]
        reveal(field, in: app)
        XCTAssertEqual(field.value as? String, maximum)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists, element.isHittable,
               element.frame.minY >= app.frame.minY + 80,
               element.frame.maxY <= app.frame.maxY - 40 { break }
            if element.exists, element.frame.minY < app.frame.minY + 80 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }
}
