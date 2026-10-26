import XCTest
import UIKit

final class WorkoutShareCardUITests: XCTestCase {
    @MainActor func testShareGalleryCardEditingAndNativeExports() {
        let app = launchWorkout()
        XCTAssertFalse(app.segmentedControls["workoutDetailTabs"].exists)
        XCTAssertTrue(app.buttons["editSavedWorkout"].exists)
        app.buttons["openWorkoutShareDrawer"].tap()
        let carousel = app.scrollViews["workoutShareCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutShareFormat"].label, "Chart Card")
        capture("Workout share drawer chart")
        app.buttons["shareSelectedWorkoutFormat"].tap()

        XCTAssertTrue(app.navigationBars["Chart Card"].waitForExistence(timeout: 5))
        let editor = app.scrollViews["workoutCardEditorScroll"]
        let title = app.textFields["workoutCardTitleField"]
        reveal(title, in: editor)
        replaceText(title, with: "Tempo session")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shareWorkoutImage"].exists)
        capture("Card editor keyboard without share button")
        title.typeText("\n")
        XCTAssertTrue(app.buttons["shareWorkoutImage"].waitForExistence(timeout: 5))
        let start = app.sliders["workoutRangeStart"]
        let end = app.sliders["workoutRangeEnd"]
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(end.isHittable)
        XCTAssertLessThan(end.frame.maxY, app.buttons["shareWorkoutImage"].frame.minY)
        start.adjust(toNormalizedSliderPosition: 0.15)
        XCTAssertNotEqual(start.value as? String, "0:00")
        reveal(end, in: editor)
        if end.frame.maxY > app.buttons["shareWorkoutImage"].frame.minY - 12 { editor.swipeUp() }
        end.adjust(toNormalizedSliderPosition: 0.85)
        XCTAssertNotEqual(end.value as? String, "42:00")
        XCTAssertNotEqual(app.staticTexts["selectedWorkoutDuration"].label, "42:00")
        XCTAssertTrue(app.buttons["resetWorkoutCard"].isEnabled)
        capture("Chart card editor title and range")
        app.buttons["shareWorkoutImage"].tap()
        copyFromNativeSheet(app, expectsImage: true)
        app.buttons["resetWorkoutCard"].tap()
        XCTAssertFalse(app.buttons["resetWorkoutCard"].isEnabled)
        XCTAssertEqual(title.value as? String, "Morning intervals")
        XCTAssertEqual(app.sliders["workoutRangeStart"].value as? String, "0:00")
        XCTAssertEqual(app.sliders["workoutRangeEnd"].value as? String, "42:00")
        app.buttons["closeWorkoutCardEditor"].tap()

        XCTAssertTrue(carousel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Tempo session"].exists)
        carousel.swipeLeft()
        let statsSelected = NSPredicate(format: "label == %@", "Stats Card")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: statsSelected,
                         object: app.staticTexts["workoutShareFormat"])], timeout: 5), .completed)
        capture("Workout share drawer stats")
        app.buttons["openStatsCard"].tap()
        XCTAssertTrue(app.navigationBars["Stats Card"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["workoutCardTitleField"].value as? String, "Morning intervals")
        XCTAssertFalse(app.segmentedControls["workoutCardStyle"].exists)
        capture("Stats card editor")
        app.buttons["shareWorkoutImage"].tap()
        copyFromNativeSheet(app, expectsImage: true)
        app.buttons["closeWorkoutCardEditor"].tap()

        app.buttons["shareFormat2"].tap()
        let summary = app.staticTexts["workoutTextSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Morning intervals"))
        XCTAssertTrue(summary.label.contains("42:00"))
        capture("Workout share drawer plain text")
        app.buttons["shareSelectedWorkoutFormat"].tap()
        copyFromNativeSheet(app, expectsImage: false)
        app.buttons["shareFormat3"].tap()
        capture("Workout share drawer logs")
        app.buttons["shareSelectedWorkoutFormat"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        capture("JSON logs in native share sheet")
    }

    @MainActor func testSavedWorkoutDetailsPersistAndCardTitleStaysTemporary() {
        let app = launchWorkout()
        app.buttons["editSavedWorkout"].tap()
        let savedTitle = app.textFields["savedWorkoutTitle"]
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 5))
        replaceText(savedTitle, with: "Saved tempo workout")
        let description = app.textViews["savedWorkoutDescription"]
        description.tap()
        description.typeText("Steady effort. Strong finish.")
        let editedDescription = description.value as? String ?? ""
        XCTAssertTrue(editedDescription.contains("Steady effort. Strong finish."))
        capture("Edit saved workout title and description")
        app.buttons["saveWorkoutDetails"].tap()
        XCTAssertTrue(savedTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved tempo workout"].waitForExistence(timeout: 5))
        let log = app.descendants(matching: .any).matching(identifier: "workoutLogTab").firstMatch
        let savedDescription = app.staticTexts[editedDescription]
        // Wait for the saved log to update before scrolling its summary.
        capture("Saved workout log after edit")
        for _ in 0..<6 where !savedDescription.exists { log.swipeUp() }
        XCTAssertTrue(savedDescription.exists)
        XCTAssertTrue(app.staticTexts["Saved tempo workout"].exists)

        // Cancel must not overwrite the saved record.
        app.buttons["editSavedWorkout"].tap()
        replaceText(savedTitle, with: "Discarded edit")
        app.navigationBars["Edit Workout"].buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Saved tempo workout"].waitForExistence(timeout: 5))
        app.navigationBars["Workout"].buttons.element(boundBy: 0).tap()
        let historyCard = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved tempo workout, Workout")).firstMatch
        XCTAssertTrue(historyCard.waitForExistence(timeout: 5))
        historyCard.tap()
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["openChartCard"].tap()
        let editor = app.scrollViews["workoutCardEditorScroll"]
        let temporaryTitle = app.textFields["workoutCardTitleField"]
        reveal(temporaryTitle, in: editor)
        XCTAssertEqual(temporaryTitle.value as? String, "Saved tempo workout")
        replaceText(temporaryTitle, with: "Temporary card title")
        temporaryTitle.typeText("\n")
        app.buttons["closeWorkoutCardEditor"].tap()
        app.buttons["openChartCard"].tap()
        XCTAssertTrue(temporaryTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(temporaryTitle.value as? String, "Saved tempo workout")
        XCTAssertFalse(app.staticTexts["Temporary card title"].exists)
        app.buttons["closeWorkoutCardEditor"].tap()
        app.buttons["closeWorkoutShareDrawer"].tap()
        app.buttons["editSavedWorkout"].tap()
        XCTAssertEqual(savedTitle.value as? String, "Saved tempo workout")
        XCTAssertEqual(description.value as? String, editedDescription)
    }

    @MainActor func testCardControlsRemainUsableInLandscapeAndLargerText() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchWorkout(largeText: true)
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["openChartCard"].tap()
        let end = app.sliders["workoutRangeEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        capture("Landscape card editor before scrolling")
        revealInLandscape(end, app: app)
        capture("Landscape end slider ready")
        XCTAssertTrue(end.isHittable)
        end.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertNotEqual(end.value as? String, "42:00")
        XCTAssertTrue(app.buttons["closeWorkoutCardEditor"].isHittable)
        revealInLandscape(app.buttons["shareWorkoutImage"], app: app)
        XCTAssertTrue(app.buttons["shareWorkoutImage"].isHittable)
        capture("Landscape card editor with accessibility text")
        app.buttons["closeWorkoutCardEditor"].tap()
    }

    @MainActor private func revealInLandscape(_ element: XCUIElement, app: XCUIApplication) {
        let top = app.navigationBars["Chart Card"].frame.maxY + 12
        let bottom = app.frame.maxY - 20
        let middle = (top + bottom) / 2
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<14 {
            if element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            let distance = max(-80, min(80, element.frame.midY - middle))
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: middle + distance / 2))
            let finish = origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: middle - distance / 2))
            start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    @MainActor private func launchWorkout(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        if !largeText { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--workout-share-ui-test", "-UIPreferredContentSizeCategoryName",
                               largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        let workout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Morning intervals, Workout")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 10))
        workout.tap()
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let oldValue = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + text)
    }

    @MainActor private func reveal(_ element: XCUIElement, in scroll: XCUIElement, upward: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<8 where !element.isHittable {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.65 : 0.2))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.2 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if !element.isHittable { capture("Control could not be revealed") }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }

    @MainActor private func copyFromNativeSheet(_ app: XCUIApplication, expectsImage: Bool) {
        let copy = app.cells["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        let copyIcon = app.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "activityImageView", "copy")).firstMatch
        XCTAssertTrue(copyIcon.waitForExistence(timeout: 20))
        capture(expectsImage ? "Image in native share sheet" : "Text in native share sheet")
        let previousChange = UIPasteboard.general.changeCount
        copyIcon.tap()
        let copied = NSPredicate { _, _ in
            UIPasteboard.general.changeCount > previousChange &&
            (expectsImage ? UIPasteboard.general.hasImages : UIPasteboard.general.hasStrings)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: copied, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
