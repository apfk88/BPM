import XCTest

final class ColdStartUITests: XCTestCase {
    @MainActor
    func testColdLaunchOpensPausedAndRunningWorkout() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--calorie-setup-ui-test",
            "-BPM_FriendCode", "",
            "-BPM_Calories_SetupPromptDismissed", "YES"
        ]
        app.launch()
        defer {
            app.resetWorkoutAndReturnHome()
            app.terminate()
        }
        app.resetWorkoutAndReturnHome()

        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        app.buttons["Start"].tap()
        let startConfirmation = app.alerts["Start Workout"]
        if startConfirmation.waitForExistence(timeout: 1) {
            startConfirmation.buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Work Set"].tap()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        assertWorkoutIsOpen(in: app)
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5), "The paused workout must survive relaunch")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        assertWorkoutIsOpen(in: app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), "The running workout must survive relaunch")

        app.resetWorkoutAndReturnHome()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workoutHome"].exists)
        XCTAssertEqual(app.buttons["Workout"].value as? String, "No active workout")
    }

    @MainActor
    func testForegroundReturnOpensActiveWorkoutFromHomeAndSettings() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--calorie-setup-ui-test",
            "-BPM_FriendCode", "",
            "-BPM_Calories_SetupPromptDismissed", "YES"
        ]
        app.launch()
        defer {
            app.resetWorkoutAndReturnHome()
            app.terminate()
        }
        app.resetWorkoutAndReturnHome()
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        let startConfirmation = app.alerts["Start Workout"]
        if startConfirmation.waitForExistence(timeout: 1) {
            startConfirmation.buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        app.buttons["workoutHome"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        reopen(app)
        assertWorkoutIsOpen(in: app)
        XCTAssertTrue(app.buttons["Pause"].exists)

        app.buttons["Pause"].tap()
        app.buttons["workoutHome"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        reopen(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        assertWorkoutIsOpen(in: app)
        XCTAssertTrue(app.buttons["Start"].exists, "Reopening must not resume a paused workout")

        app.resetWorkoutAndReturnHome()
        reopen(app)
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workoutHome"].exists, "An idle session should stay on Home")
    }

    @MainActor
    private func reopen(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
    }

    @MainActor
    private func assertWorkoutIsOpen(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["workoutHome"].waitForExistence(timeout: 5), "Opening the app must land on the active workout")
    }
}
