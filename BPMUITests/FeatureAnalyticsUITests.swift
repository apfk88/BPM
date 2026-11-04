import XCTest

/// Exercises real bindings and navigation. Inspect the Analytics debug log alongside
/// this test to verify the emitted payloads; no health values belong in that log.
final class FeatureAnalyticsUITests: XCTestCase {
    @MainActor func testCalorieEditsAndHistoryNavigation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["Calorie Settings"].tap()
        let age = app.textFields["Age"]
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        let original = ProcessInfo.processInfo.environment["BPM_ANALYTICS_RESTORE_AGE"] ?? (age.value as? String ?? "")
        let replacement = original == "31" ? "32" : "31"
        replace(age, with: replacement)
        XCTAssertEqual(age.value as? String, replacement)
        app.navigationBars["Calorie Settings"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // Restore the simulator's original profile through the same binding.
        app.buttons["Calorie Settings"].tap()
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        replace(age, with: original)
        app.navigationBars["Calorie Settings"].buttons["Settings"].tap()

        for title in ["Workout History", "HRV History"] {
            let links = app.buttons.matching(NSPredicate(format: "label == %@", title))
            var visible = links.allElementsBoundByIndex.first(where: { $0.isHittable })
            for _ in 0..<4 where visible == nil {
                app.swipeUp()
                visible = links.allElementsBoundByIndex.first(where: { $0.isHittable })
            }
            XCTAssertNotNil(visible)
            visible?.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            app.navigationBars[title].buttons["Settings"].tap()
        }
        app.navigationBars["Settings"].buttons["Done"].tap()
    }

    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        field.doubleTap()
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }
}
