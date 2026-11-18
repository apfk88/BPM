import XCTest
import UIKit

final class WorkoutSavedPageLinkUITests: XCTestCase {
    @MainActor
    func testPublishedLinkAppearsInHistoryAndDetailAndCanBeDeleted() {
        let app = launchHistory(page: "published")
        let row = app.buttons["savedWorkoutHistoryRow"].firstMatch
        XCTAssertEqual(row.value as? String, "Private link")
        capture("Workout history with private link")
        row.tap()

        let copy = app.buttons["copySavedWorkoutPageLink"]
        reveal(copy, app: app)
        let url = app.staticTexts["savedWorkoutPageURL"].label
        XCTAssertTrue(url.hasPrefix("https://bpm.example/w/"))
        XCTAssertTrue(app.buttons["openSavedWorkoutPage"].isHittable)
        copy.tap()
        XCTAssertEqual(copy.label, "Private workout link copied")
        let components = URLComponents(string: url)
        XCTAssertEqual(components?.fragment?.count, 43)
        XCTAssertEqual(components?.path.split(separator: "/").last?.count, 22)
        XCTAssertNil(components?.query)
        XCTAssertLessThan(url.count, 100)
        capture("Saved workout private link controls")
        assertCopiedURL(url, app: app)

        reveal(app.buttons["manageSavedWorkoutPage"], app: app)
        app.buttons["manageSavedWorkoutPage"].tap()
        XCTAssertTrue(app.navigationBars["Workout Page"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["managedWorkoutPageURL"].label, url)
        XCTAssertTrue(app.buttons["copySharedWorkoutLink"].exists)
        app.navigationBars["Workout Page"].buttons.element(boundBy: 0).tap()

        let delete = app.buttons["deleteSavedWorkoutPage"]
        reveal(delete, app: app)
        delete.tap()
        app.buttons["Delete Shared Page"].tap()
        XCTAssertTrue(app.staticTexts["savedWorkoutPageURL"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].exists)
        app.navigationBars["Workout"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertNotEqual(row.value as? String, "Private link")
    }

    @MainActor
    func testPendingPageHasNoUsableLinkUntilExplicitCreation() {
        let app = launchHistory(page: "pending")
        let row = app.buttons["savedWorkoutHistoryRow"].firstMatch
        XCTAssertEqual(row.value as? String, "Link pending")
        row.tap()
        let manage = app.buttons["manageSavedWorkoutPage"]
        reveal(manage, app: app)
        XCTAssertEqual(app.staticTexts["savedWorkoutPageStatus"].label, "Link not shared yet")
        assertNoUsableLink(app)
        manage.tap()
        let create = app.buttons["retrySharedWorkoutUpload"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["copySharedWorkoutLink"].exists)
        create.tap()
        XCTAssertTrue(app.staticTexts["managedWorkoutPageURL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["copySharedWorkoutLink"].exists)
        app.navigationBars["Workout Page"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["savedWorkoutPageURL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["copySavedWorkoutPageLink"].exists)
    }

    @MainActor
    func testPendingDeletionHidesLinkAndRetainsRetry() {
        let app = launchHistory(page: "deletion-pending")
        let row = app.buttons["savedWorkoutHistoryRow"].firstMatch
        XCTAssertEqual(row.value as? String, "Deletion pending")
        row.tap()
        let retry = app.buttons["deleteSavedWorkoutPage"]
        reveal(retry, app: app)
        XCTAssertEqual(app.staticTexts["savedWorkoutPageStatus"].label, "Deletion pending")
        XCTAssertEqual(retry.label, "Retry deleting shared page")
        assertNoUsableLink(app)
        retry.tap()
        app.buttons["Delete Shared Page"].tap()
        XCTAssertTrue(app.staticTexts["savedWorkoutPageStatus"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].exists)
    }

    @MainActor
    private func launchHistory(page: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workout-share-ui-test", "--workout-shared-page-\(page)",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["savedWorkoutHistoryRow"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertCopiedURL(_ url: String, app: XCUIApplication) {
        // Paste within the foreground app. iOS can deny clipboard contents to
        // the separate UI-test runner even after a successful copy action.
        app.buttons["editSavedWorkout"].tap()
        let title = app.textFields["savedWorkoutTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let old = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        title.press(forDuration: 1)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertEqual(title.value as? String, url)
        app.navigationBars["Edit Workout"].buttons["Cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertNoUsableLink(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["savedWorkoutPageURL"].exists)
        XCTAssertFalse(app.buttons["openSavedWorkoutPage"].exists)
        XCTAssertFalse(app.buttons["copySavedWorkoutPageLink"].exists)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let scroll = app.descendants(matching: .any).matching(identifier: "workoutLogTab").firstMatch
        let top = app.navigationBars["Workout"].frame.maxY + 12
        let bottom = app.frame.maxY - 32
        for _ in 0..<10 {
            if element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            let upward = element.frame.midY > (top + bottom) / 2
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.65 : 0.25))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.25 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("The link control could not be brought into view: \(element.debugDescription)")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
