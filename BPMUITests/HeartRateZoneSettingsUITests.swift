import XCTest

final class HeartRateZoneSettingsUITests: XCTestCase {
    @MainActor
    func testCustomZonesSurviveMaxChangesRecalculationCancellationAndRelaunch() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--calorie-setup-ui-test", "-BPM_FriendCode", ""]
        app.launch()
        defer { app.terminate() }
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.buttons["settingsButton"].tap()
        openZones(in: app)

        // Start from known ranges, then save a deliberately custom Zone 1.
        let reset = app.buttons["resetZones"]
        reveal(reset, in: app)
        reset.tap()
        let resetSheet = app.sheets.firstMatch
        XCTAssertTrue(resetSheet.waitForExistence(timeout: 3))
        resetSheet.buttons["Reset Defaults"].tap()
        replace("90", in: app.textFields["zone1Minimum"], app: app)
        replace("112", in: app.textFields["zone1Maximum"], app: app)
        XCTAssertTrue(app.buttons["saveZones"].isEnabled)
        app.buttons["saveZones"].tap()
        openZones(in: app)
        XCTAssertEqual(app.textFields["zoneMaxHeartRate"].value as? String, "190")
        assertCustomRange(in: app)

        replace("200", in: app.textFields["zoneMaxHeartRate"], app: app)
        assertCustomRange(in: app)
        app.buttons["recalculateZones"].tap()
        let recalculateSheet = app.sheets.firstMatch
        XCTAssertTrue(recalculateSheet.waitForExistence(timeout: 3))
        let popoverDismissRegion = app.otherElements["PopoverDismissRegion"]
        if popoverDismissRegion.exists {
            // iOS 26 uses a popover that cancels when its surrounding area is tapped.
            popoverDismissRegion.tap()
        } else {
            recalculateSheet.buttons["Cancel"].tap()
        }
        XCTAssertTrue(recalculateSheet.waitForNonExistence(timeout: 3))
        assertCustomRange(in: app)

        app.buttons["recalculateZones"].tap()
        XCTAssertTrue(recalculateSheet.waitForExistence(timeout: 3))
        recalculateSheet.buttons["Recalculate Zones"].tap()
        XCTAssertEqual(app.textFields["zone1Minimum"].value as? String, "100")
        XCTAssertEqual(app.textFields["zone1Maximum"].value as? String, "120")
        // Even confirmed recalculation is discarded when the editor is cancelled.
        app.buttons["cancelZones"].tap()
        openZones(in: app)
        XCTAssertEqual(app.textFields["zoneMaxHeartRate"].value as? String, "190")
        assertCustomRange(in: app)

        replace("200", in: app.textFields["zoneMaxHeartRate"], app: app)
        XCTAssertTrue(app.buttons["saveZones"].isEnabled)
        app.buttons["saveZones"].tap()
        openZones(in: app)
        XCTAssertEqual(app.textFields["zoneMaxHeartRate"].value as? String, "200")
        assertCustomRange(in: app)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Custom zones preserved after max HR change"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["cancelZones"].tap()
        app.navigationBars["Settings"].buttons["Done"].tap()

        app.terminate()
        app.launch()
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.buttons["settingsButton"].tap()
        openZones(in: app)
        XCTAssertEqual(app.textFields["zoneMaxHeartRate"].value as? String, "200")
        assertCustomRange(in: app)
    }

    @MainActor
    private func openZones(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let zones = app.buttons["Zone Settings"]
        XCTAssertTrue(zones.waitForExistence(timeout: 3))
        zones.tap()
        XCTAssertTrue(app.navigationBars["Zone Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertCustomRange(in app: XCUIApplication) {
        XCTAssertEqual(app.textFields["zone1Minimum"].value as? String, "90")
        XCTAssertEqual(app.textFields["zone1Maximum"].value as? String, "112")
    }

    @MainActor
    private func replace(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        reveal(field, in: app)
        field.tap()
        // Each numeric value is one token. Select it instead of assuming the
        // first tap places the insertion point after its final digit.
        field.doubleTap()
        field.typeText(text)
        let done = app.buttons["dismissZoneKeyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        XCTAssertEqual(field.value as? String, text)
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
