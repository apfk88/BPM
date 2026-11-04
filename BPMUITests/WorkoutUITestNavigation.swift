import XCTest

extension XCUIApplication {
    /// Leaving Workout now preserves it, so isolated tests reset explicitly.
    @MainActor
    func resetWorkoutAndReturnHome() {
        guard buttons["workoutHome"].waitForExistence(timeout: 2) else { return }
        let end = buttons["End"]
        if end.exists && end.isEnabled { end.tap() }
        let reset = buttons["Reset"]
        if reset.waitForExistence(timeout: 1) && reset.isEnabled {
            reset.tap()
            let confirmation = alerts["Reset Workout"].buttons["Reset"]
            if confirmation.waitForExistence(timeout: 1) { confirmation.tap() }
        }
        buttons["workoutHome"].tap()
    }
}
