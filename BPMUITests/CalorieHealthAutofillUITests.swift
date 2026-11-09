import XCTest

final class CalorieHealthAutofillUITests: XCTestCase {
    @MainActor
    func testReviewsBeforeApplyingAndPreservesExistingEntries() {
        let app = launchFixture(empty: false)
        defer { app.terminate() }
        openCalorieSettings(in: app)

        let weight = app.textFields["Weight"]
        reveal(weight, in: app)
        weight.tap()
        weight.typeText("180")
        app.buttons["dismissCalorieKeyboard"].tap()

        openHealthReview(in: app)
        XCTAssertTrue(app.staticTexts["Keep your existing entry"].waitForExistence(timeout: 3))
        app.navigationBars["Apple Health"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForNonExistence(timeout: 3))
        reveal(app.textFields["Age"], in: app)
        expectValue("", of: app.textFields["Age"])
        expectValue("180", of: weight)

        openHealthReview(in: app)
        app.buttons["applyCalorieHealthAutofill"].tap()
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForNonExistence(timeout: 3))
        reveal(weight, in: app)
        expectValue("180", of: weight)
        reveal(app.textFields["Age"], in: app)
        expectValue("37", of: app.textFields["Age"])
        reveal(app.buttons["Male"], in: app)
        XCTAssertTrue(app.buttons["Male"].isSelected)

        let resting = app.textFields["Resting HR"]
        reveal(resting, in: app)
        expectValue("60", of: resting)
        let vo2Max = app.textFields["VO2max"]
        reveal(vo2Max, in: app)
        expectValue("50", of: vo2Max)

        app.navigationBars["Calorie Settings"].buttons["Settings"].tap()
        let calorieLink = app.buttons["calorieSettingsLink"]
        reveal(calorieLink, in: app)
        expectValue("Personalized", of: calorieLink)
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 3))
        expectValue("Personalized", of: app.buttons["settingsButton"])
        XCTAssertFalse(app.buttons["setUpCalories"].exists)
        attachScreenshot("Imported health details enable personalized calories")
    }

    @MainActor
    func testEmptyHealthReadExplainsMissingDataWithoutClaimingPermissionState() {
        let app = launchFixture(empty: true)
        defer { app.terminate() }
        openCalorieSettings(in: app)

        let autofill = app.buttons["autofillCaloriesFromHealth"]
        reveal(autofill, in: app)
        autofill.tap()
        let message = app.staticTexts["calorieHealthAutofillMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("No shared data"))
        XCTAssertFalse(message.label.lowercased().contains("connected"))
        XCTAssertFalse(message.label.lowercased().contains("denied"))
        XCTAssertFalse(app.navigationBars["Apple Health"].exists)
        reveal(app.textFields["Age"], in: app)
        expectValue("", of: app.textFields["Age"])
        attachScreenshot("Empty health read keeps manual setup available")
    }

    @MainActor
    private func launchFixture(empty: Bool) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Bluetooth permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "--calorie-setup-ui-test", "--reset-calorie-setup",
            empty ? "--calorie-health-autofill-empty-fixture" : "--calorie-health-autofill-fixture",
            "-BPM_FriendCode", ""
        ]
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openCalorieSettings(in app: XCUIApplication) {
        app.buttons["settingsButton"].tap()
        let link = app.buttons["calorieSettingsLink"]
        reveal(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars["Calorie Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openHealthReview(in app: XCUIApplication) {
        let autofill = app.buttons["autofillCaloriesFromHealth"]
        reveal(autofill, in: app)
        autofill.tap()
        XCTAssertTrue(app.navigationBars["Apple Health"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["applyCalorieHealthAutofill"].exists)
    }

    @MainActor
    private func expectValue(_ value: String, of element: XCUIElement) {
        let predicate = value.isEmpty
            ? NSPredicate(format: "value == nil OR value == '' OR value == 'Add'")
            : NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
                       "Expected \(value), received \(String(describing: element.value)); \(element.debugDescription)")
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
