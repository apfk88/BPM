import XCTest

final class CalorieSetupUITests: XCTestCase {
    @MainActor
    func testSkippingSetupKeepsSettingsReminderAndDoesNotRepeatPrompt() {
        let app = launchFreshCalorieSetup()
        defer { app.terminate() }

        connectSimulator(in: app)
        XCTAssertTrue(app.buttons["setUpCalories"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Calorie setup needed")
        app.buttons["dismissCalorieSetupPrompt"].tap()
        XCTAssertTrue(app.buttons["setUpCalories"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Calorie setup needed")

        disconnectSimulator(in: app)
        connectSimulator(in: app)
        XCTAssertFalse(app.buttons["setUpCalories"].exists)
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Calorie setup needed")

        app.terminate()
        app.launchArguments = ["--calorie-setup-ui-test", "-BPM_FriendCode", ""]
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setUpCalories"].exists)
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Calorie setup needed")

        app.buttons["settingsButton"].tap()
        let calorieSettings = app.buttons["calorieSettingsLink"]
        reveal(calorieSettings, in: app)
        XCTAssertEqual(calorieSettings.value as? String, "Not set up")
        calorieSettings.tap()
        XCTAssertTrue(app.navigationBars["Calorie Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Weight"].exists)
        XCTAssertTrue(app.textFields["Age"].exists)
        attachScreenshot("Calorie setup remains discoverable after skipping")
    }

    @MainActor
    func testFirstWorkoutPromptsWithoutMonitorAndKeepsWorkoutRunning() {
        let app = launchFreshCalorieSetup()
        defer {
            app.resetWorkoutAndReturnHome()
            app.terminate()
        }

        XCTAssertEqual(app.buttons["deviceConnectionMenu"].value as? String, "Not connected")
        app.buttons["Workout"].tap()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setUpCalories"].exists)
        start.tap()
        let confirmation = app.alerts["Start Workout"]
        if confirmation.waitForExistence(timeout: 1) {
            confirmation.buttons["Start from now"].tap()
        }

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["setUpCalories"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].isEnabled)
        XCTAssertEqual(app.buttons["deviceConnectionMenu"].value as? String, "Not connected")
        attachScreenshot("First workout offers calorie setup while remaining active")
        app.buttons["dismissCalorieSetupPrompt"].tap()
        XCTAssertTrue(app.buttons["setUpCalories"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pause"].exists)
    }

    @MainActor
    func testEssentialDetailsEnableCaloriesAndPersistAcrossLaunches() {
        let app = launchFreshCalorieSetup()
        defer { app.terminate() }
        openFirstUseSetup(in: app)

        enter("180", in: app.textFields["Weight"], app: app)
        expectSetupStatus("Setup incomplete", in: app)
        enter("37", in: app.textFields["Age"], app: app)
        app.buttons["Male"].tap()
        expectSetupStatus("Basic", in: app)
        XCTAssertFalse(app.textFields["Height feet"].exists)
        XCTAssertTrue(app.staticTexts["Optional"].exists)
        XCTAssertFalse(app.buttons["Optional details"].exists)
        XCTAssertFalse(app.switches["Medication affects heart rate"].exists)
        attachScreenshot("Essential calorie details complete")

        app.navigationBars["Calorie Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Basic")
        XCTAssertFalse(app.buttons["setUpCalories"].exists)

        app.terminate()
        app.launchArguments = ["--calorie-setup-ui-test", "-BPM_FriendCode", ""]
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Basic")
        app.buttons["settingsButton"].tap()
        let calorieSettings = app.buttons["calorieSettingsLink"]
        reveal(calorieSettings, in: app)
        XCTAssertEqual(calorieSettings.value as? String, "Basic")
    }

    @MainActor
    func testOptionalFitnessDetailsUpdateSetupLevelWithoutBecomingRequired() {
        let app = launchFreshCalorieSetup()
        defer { app.terminate() }
        openFirstUseSetup(in: app)
        enter("180", in: app.textFields["Weight"], app: app)
        enter("37", in: app.textFields["Age"], app: app)
        app.buttons["Male"].tap()
        expectSetupStatus("Basic", in: app)

        XCTAssertFalse(app.buttons["Optional details"].exists)
        let restingHeartRate = app.textFields["Resting HR"]
        reveal(restingHeartRate, in: app)
        enter("60", in: restingHeartRate, app: app)
        let maxHeartRate = app.textFields["Max HR"]
        reveal(maxHeartRate, in: app)
        enter("195", in: maxHeartRate, app: app)
        expectSetupStatus("Basic", in: app)
        let vo2Max = app.textFields["VO2max"]
        reveal(vo2Max, in: app)
        enter("50", in: vo2Max, app: app)
        expectSetupStatus("Personalized", in: app)
        let restingEnergy = app.textFields["Resting energy"]
        reveal(restingEnergy, in: app)
        enter("1800", in: restingEnergy, app: app)

        app.navigationBars["Calorie Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Complete")
        app.buttons["settingsButton"].tap()
        let calorieSettings = app.buttons["calorieSettingsLink"]
        reveal(calorieSettings, in: app)
        XCTAssertEqual(calorieSettings.value as? String, "Complete")
        attachScreenshot("Complete calorie setup in main Settings")
    }

    @MainActor
    func testMetricWeightAcceptsDecimalCommaAndSurvivesUnitSwitchingAndRelaunch() {
        let app = launchFreshCalorieSetup()
        defer { app.terminate() }
        openFirstUseSetup(in: app)
        let weight = app.textFields["Weight"]
        enter("180", in: weight, app: app)
        enter("37", in: app.textFields["Age"], app: app)
        app.buttons["Male"].tap()

        selectWeightUnit("kg", in: app)
        XCTAssertEqual(weight.value as? String, "81.6")
        weight.doubleTap()
        weight.typeText("70,5")
        app.buttons["dismissCalorieKeyboard"].tap()
        XCTAssertEqual(weight.value as? String, "70.5")
        selectWeightUnit("lb", in: app)
        XCTAssertEqual(weight.value as? String, "155.4")
        selectWeightUnit("kg", in: app)
        XCTAssertEqual(weight.value as? String, "70.5")
        app.navigationBars["Calorie Settings"].buttons["Done"].tap()

        app.terminate()
        app.launchArguments = ["--calorie-setup-ui-test", "-BPM_FriendCode", ""]
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.buttons["settingsButton"].tap()
        reveal(app.buttons["calorieSettingsLink"], in: app)
        app.buttons["calorieSettingsLink"].tap()
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertEqual(weight.value as? String, "70.5")
        let unit = weightUnitButton(in: app)
        XCTAssertTrue(unit.label.contains("kg") || (unit.value as? String)?.contains("kg") == true)
        attachScreenshot("Metric calorie weight persists after unit switching")
    }

    @MainActor
    func testFirstUsePromptActionsRemainReachableAtLargestAccessibilityTextSize() {
        let app = launchFreshCalorieSetup(additionalArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { app.terminate() }
        connectSimulator(in: app)

        for identifier in ["setUpCalories", "dismissCalorieSetupPrompt", "settingsButton"] {
            let button = app.buttons[identifier]
            reveal(button, in: app)
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable, "\(identifier) must be reachable at accessibility text size")
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY)
        }
        app.swipeDown()
        app.swipeDown()
        attachScreenshot("First-use calorie prompt with largest accessibility text")
        reveal(app.buttons["dismissCalorieSetupPrompt"], in: app)
        app.buttons["dismissCalorieSetupPrompt"].tap()
        XCTAssertTrue(app.buttons["setUpCalories"].waitForNonExistence(timeout: 3))
        reveal(app.buttons["settingsButton"], in: app)
        app.buttons["settingsButton"].tap()
        let calorieSettings = app.buttons["calorieSettingsLink"]
        reveal(calorieSettings, in: app)
        XCTAssertTrue(calorieSettings.isHittable)
    }

    @MainActor
    private func launchFreshCalorieSetup(additionalArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Bluetooth permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        let app = XCUIApplication()
        // Reset only calorie preferences, once. Later launches exercise persistence.
        // NSArgumentDomain overrides would mask writes made through @AppStorage.
        app.launchArguments = ["--calorie-setup-ui-test", "--reset-calorie-setup", "-BPM_FriendCode", ""] + additionalArguments
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setUpCalories"].exists, "Fresh launch should not prompt before connecting or starting a workout")
        XCTAssertEqual(app.buttons["settingsButton"].value as? String, "Calorie setup needed")
        return app
    }

    @MainActor
    private func connectSimulator(in app: XCUIApplication) {
        let device = app.buttons["deviceConnectionMenu"]
        reveal(device, in: app)
        device.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        let monitor = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator HR Monitor")).firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        reveal(monitor, in: app)
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(device.value as? String, "Monitor connected")
    }

    @MainActor
    private func disconnectSimulator(in app: XCUIApplication) {
        let device = app.buttons["deviceConnectionMenu"]
        reveal(device, in: app)
        device.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        let disconnect = app.buttons["Disconnect Monitor"]
        reveal(disconnect, in: app)
        disconnect.tap()
        app.navigationBars["Select Device"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(device.value as? String, "Not connected")
    }

    @MainActor
    private func selectWeightUnit(_ symbol: String, in app: XCUIApplication) {
        let picker = weightUnitButton(in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let option = app.buttons[symbol]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
    }

    @MainActor
    private func weightUnitButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weight unit")).firstMatch
    }

    @MainActor
    private func openFirstUseSetup(in app: XCUIApplication) {
        connectSimulator(in: app)
        let setup = app.buttons["setUpCalories"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Calorie Settings"].waitForExistence(timeout: 5))
        expectSetupStatus("Not set up", in: app)
    }

    @MainActor
    private func expectSetupStatus(_ value: String, in app: XCUIApplication) {
        let status = app.descendants(matching: .any)["calorieSetupStatus"]
        reveal(status, in: app)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    @MainActor
    private func enter(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(text)
        let dismissKeyboard = app.buttons["dismissCalorieKeyboard"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3))
        dismissKeyboard.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scrollContainer: XCUIElement = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : (app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch : app)
        for _ in 0..<12 {
            if element.exists, element.isHittable,
               element.frame.minY >= app.frame.minY + 60,
               element.frame.maxY <= app.frame.maxY - 24 { break }
            if element.exists, element.frame.minY < app.frame.minY + 60 {
                scrollContainer.swipeDown()
            } else {
                scrollContainer.swipeUp()
            }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
