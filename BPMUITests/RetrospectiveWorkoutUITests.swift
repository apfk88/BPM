import XCTest

final class RetrospectiveWorkoutUITests: XCTestCase {
    @MainActor
    func testRecoverCapturedReadingsAndOpenSavedHistoryAfterRelaunch() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BPM_RECOVERY_TEST_ID"] = UUID().uuidString
        app.launchArguments = [
            "--calorie-setup-ui-test", "-BPM_FriendCode", "",
            "-BPM_Calories_SetupPromptDismissed", "YES", "-AppleLocale", "en_US",
            "--seed-recovery-readings"
        ]
        app.launch()
        openSettings(in: app)
        openSettingsRow("recoverWorkoutLink", in: app)
        let window = app.buttons["recoveryWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Relaunch without synthetic input to recover from the actual on-disk archive.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--seed-recovery-readings" }
        app.launch()
        openSettings(in: app)
        openSettingsRow("recoverWorkoutLink", in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.tap()

        let review = app.navigationBars["Review Workout"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let start = app.datePickers["recoveryStart"]
        XCTAssertTrue(start.exists)
        XCTAssertTrue(app.datePickers["recoveryEnd"].exists)
        start.tap()
        let minutes = app.pickerWheels.element(boundBy: 1)
        XCTAssertTrue(minutes.waitForExistence(timeout: 5))
        minutes.adjust(toPickerWheelValue: "01")
        review.staticTexts["Review Workout"].tap()

        let save = app.buttons["saveRecoveredWorkout"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        assertTrimmedWorkout(in: app)

        app.terminate()
        app.launch()
        openSettings(in: app)
        openSettingsRow("Workout History", in: app)
        let records = app.buttons.matching(identifier: "savedWorkoutHistoryRow")
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(records.count, 1)
        records.firstMatch.tap()
        assertTrimmedWorkout(in: app)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let home = app.buttons["workoutHome"]
        if home.exists { home.tap() }
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openSettingsRow(_ identifier: String, in app: XCUIApplication) {
        let row = app.buttons[identifier]
        for _ in 0..<10 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
    }

    @MainActor
    private func assertTrimmedWorkout(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Expand heart rate chart"].exists)
        for metric in ["TOTAL TIME, 2:00", "AVG BPM, 140", "MAX BPM, 140"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", metric)
            ).firstMatch.exists, metric)
        }
    }
}
