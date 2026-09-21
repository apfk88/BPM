import XCTest

final class LandscapeUITests: XCTestCase {
    @MainActor
    func testRotationKeepsWorkoutAndMovesControlsToTheRight() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        // Clear a simulator session left by an interrupted run of this test.
        if app.buttons["xmark"].waitForExistence(timeout: 3) {
            app.buttons["xmark"].tap()
            if app.alerts["Clear Workout"].waitForExistence(timeout: 1) {
                app.alerts["Clear Workout"].buttons["Clear"].tap()
            }
        }
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        attachScreenshot("Home portrait")

        rotate(.landscapeLeft, app: app)
        assertRightColumn(["Device", "Share", "Workout", "HRV"], app: app)
        attachScreenshot("Home landscape")
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        assertRightColumn(["Start", "Load Preset"], app: app)
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        assertRightColumn(["Pause", "End", "Cool", "Work Set", "Rest Set"], app: app)
        app.buttons["Work Set"].tap()
        app.buttons["Rest Set"].tap()
        attachScreenshot("Workout landscape")

        for page in ["bpm", "stats", "chart"] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
            XCTAssertTrue(app.otherElements["Timer view page: \(page)"].waitForExistence(timeout: 3))
            attachScreenshot("Workout \(page) landscape")
        }

        rotate(.landscapeRight, app: app)
        XCTAssertTrue(app.otherElements["Timer view page: chart"].exists)
        XCTAssertTrue(app.buttons["Pause"].isHittable)
        XCTAssertFalse(app.buttons["Rest Set"].isEnabled)
        app.buttons["Pause"].tap()
        rotate(.portrait, app: app)
        XCTAssertTrue(app.buttons["Start"].isHittable)
        XCTAssertFalse(app.buttons["Work Set"].isEnabled)
        attachScreenshot("Workout portrait after rotation")
        app.buttons["Start"].tap()
        rotate(.landscapeLeft, app: app)
        app.buttons["End"].tap()
        XCTAssertTrue(app.buttons["Save Workout"].waitForExistence(timeout: 5))
        assertRightColumn(["Save Workout", "Reset", "Share"], app: app)
        attachScreenshot("Completed workout landscape")

        // Clear only the workout created by this test.
        app.buttons["Reset"].tap()
        app.alerts["Reset Workout"].buttons["Reset"].tap()
        app.buttons["xmark"].tap()
        app.buttons["HRV"].tap()
        XCTAssertTrue(app.buttons["Measure HRV"].waitForExistence(timeout: 5))
        assertRightColumn(["Measure HRV"], app: app)
        attachScreenshot("HRV landscape")
        rotate(.portrait, app: app)
        XCTAssertTrue(app.buttons["Measure HRV"].isHittable)
        attachScreenshot("HRV portrait")
    }

    @MainActor
    private func rotate(_ orientation: UIDeviceOrientation, app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let predicate = NSPredicate { _, _ in
            let frame = app.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        expectation(for: predicate, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }

    @MainActor
    private func assertRightColumn(_ labels: [String], app: XCUIApplication) {
        var previousFrame: CGRect?
        for label in labels {
            let button = app.buttons[label]
            XCTAssertTrue(button.isHittable, "\(label) must be visible")
            XCTAssertGreaterThan(button.frame.minX, app.frame.width * 0.6, "\(label) must be on the right")
            if let previousFrame {
                XCTAssertGreaterThanOrEqual(button.frame.minY, previousFrame.maxY, "Controls must stack without overlap")
            }
            previousFrame = button.frame
        }
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
