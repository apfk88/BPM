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
        app.buttons["customizeWorkoutCard"].tap()

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
        // This slider exposes elapsed time, so drag its thumb without interpreting the value as a percentage.
        let endThumb = end.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        let trimmedEnd = end.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        endThumb.press(forDuration: 0.1, thenDragTo: trimmedEnd)
        XCTAssertNotEqual(end.value as? String, "42:00")
        XCTAssertNotEqual(app.staticTexts["selectedWorkoutDuration"].label, "42:00")
        XCTAssertTrue(app.buttons["resetWorkoutCard"].isEnabled)
        capture("Chart card editor title and range")
        app.buttons["shareWorkoutImage"].tap()
        copyFromNativeSheet(app, expectsImage: true)
        assertSharingClosed(app)
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["openChartCard"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // A completed share discards the temporary card edits.
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
        app.buttons["customizeWorkoutCard"].tap()
        XCTAssertTrue(app.navigationBars["Stats Card"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["workoutCardTitleField"].value as? String, "Morning intervals")
        XCTAssertFalse(app.segmentedControls["workoutCardStyle"].exists)
        capture("Stats card editor")
        app.buttons["shareWorkoutImage"].tap()
        copyFromNativeSheet(app, expectsImage: true)
        assertSharingClosed(app)
        app.buttons["openWorkoutShareDrawer"].tap()

        app.buttons["shareFormat2"].tap()
        XCTAssertFalse(app.buttons["customizeWorkoutCard"].exists)
        let summary = app.staticTexts["workoutTextSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Morning intervals"))
        XCTAssertTrue(summary.label.contains("42:00"))
        capture("Workout share drawer plain text")
        app.buttons["shareSelectedWorkoutFormat"].tap()
        copyFromNativeSheet(app, expectsImage: false)
        assertSharingClosed(app)
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["shareFormat3"].tap()
        XCTAssertFalse(app.buttons["customizeWorkoutCard"].exists)
        capture("Workout share drawer logs")
        app.buttons["shareSelectedWorkoutFormat"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        capture("JSON logs in native share sheet")
        app.cells["Copy"].firstMatch.tap()
        assertSharingClosed(app)
    }

    @MainActor func testChartAndStatsShareDirectlyWithoutOpeningEditor() {
        let app = launchWorkout()
        for format in [0, 1] {
            app.buttons["openWorkoutShareDrawer"].tap()
            app.buttons["shareFormat\(format)"].tap()
            let customize = app.buttons["customizeWorkoutCard"]
            let share = app.buttons["shareSelectedWorkoutFormat"]
            XCTAssertTrue(customize.waitForExistence(timeout: 5))
            XCTAssertTrue(customize.isHittable)
            XCTAssertLessThan(customize.frame.width, share.frame.width)
            XCTAssertEqual(customize.frame.midY, share.frame.midY, accuracy: 2)
            capture(format == 0 ? "Chart direct share and customize actions" : "Stats direct share and customize actions")
            share.tap()
            XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["closeWorkoutCardEditor"].exists)
            XCTAssertFalse(app.textFields["workoutCardTitleField"].exists)
            copyFromNativeSheet(app, expectsImage: true)
            assertSharingClosed(app)
        }
    }

    @MainActor func testCancelingDirectShareKeepsSelectedFormatAndDrawer() {
        let app = launchWorkout()
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["shareFormat1"].tap()
        app.buttons["shareSelectedWorkoutFormat"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["closeWorkoutCardEditor"].exists)
        cancelNativeShare(app)
        XCTAssertTrue(app.buttons["closeWorkoutShareDrawer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workoutShareFormat"].label, "Stats Card")
        XCTAssertTrue(app.buttons["customizeWorkoutCard"].isHittable)
        XCTAssertTrue(app.buttons["shareSelectedWorkoutFormat"].isHittable)
        app.buttons["customizeWorkoutCard"].tap()
        XCTAssertTrue(app.navigationBars["Stats Card"].waitForExistence(timeout: 5))
    }

    @MainActor func testCancelingNativeSharePreservesCardEditsAndDrawer() {
        let app = launchWorkout()
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["openChartCard"].tap()
        let title = app.textFields["workoutCardTitleField"]
        reveal(title, in: app.scrollViews["workoutCardEditorScroll"])
        replaceText(title, with: "Keep this draft")
        title.typeText("\n")
        app.buttons["shareWorkoutImage"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        cancelNativeShare(app)
        XCTAssertTrue(app.buttons["shareWorkoutImage"].waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Keep this draft")
        app.buttons["closeWorkoutCardEditor"].tap()
        XCTAssertTrue(app.buttons["closeWorkoutShareDrawer"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertSharingClosed(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["closeWorkoutCardEditor"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeWorkoutShareDrawer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].isHittable)
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
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchWorkout(largeText: true)
        app.buttons["openWorkoutShareDrawer"].tap()
        revealDrawerActions(app, stacked: true)
        capture("Portrait share and customize actions with accessibility text")
        app.buttons["customizeWorkoutCard"].tap()
        XCTAssertTrue(app.navigationBars["Chart Card"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutCardEditor"].tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        revealDrawerActions(app, stacked: true)
        capture("Landscape share and customize actions with accessibility text")
        app.buttons["customizeWorkoutCard"].tap()
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
        revealDrawerActions(app, stacked: true)
        app.buttons["shareSelectedWorkoutFormat"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["closeWorkoutCardEditor"].exists)
        copyFromNativeSheet(app, expectsImage: true)
        assertSharingClosed(app)
    }

    @MainActor func testDrawerActionsRemainUsableInLandscape() {
        let app = launchWorkout()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        app.buttons["openWorkoutShareDrawer"].tap()
        revealDrawerActions(app, stacked: false)
        capture("Landscape share and customize actions")
        app.buttons["customizeWorkoutCard"].tap()
        XCTAssertTrue(app.navigationBars["Chart Card"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutCardEditor"].tap()
        revealDrawerActions(app, stacked: false)
        app.buttons["shareSelectedWorkoutFormat"].tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["closeWorkoutCardEditor"].exists)
        copyFromNativeSheet(app, expectsImage: true)
        assertSharingClosed(app)
    }

    @MainActor private func waitForLandscape(_ app: XCUIApplication) {
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)],
                                     timeout: 5), .completed)
    }

    @MainActor private func revealDrawerActions(_ app: XCUIApplication, stacked: Bool) {
        let share = app.buttons["shareSelectedWorkoutFormat"]
        let customize = app.buttons["customizeWorkoutCard"]
        let scroll = app.scrollViews.containing(.button, identifier: "shareSelectedWorkoutFormat").firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        XCTAssertTrue(scroll.exists)
        let visible = scroll.frame.intersection(app.frame).insetBy(dx: 0, dy: 4)
        for _ in 0..<10 {
            if share.isHittable && customize.isHittable &&
                visible.contains(share.frame) && visible.contains(customize.frame) { break }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(customize.isHittable)
        XCTAssertTrue(visible.contains(share.frame), "Share must be fully visible")
        XCTAssertTrue(visible.contains(customize.frame), "Customize must be fully visible")
        XCTAssertFalse(share.frame.intersects(customize.frame))
        XCTAssertEqual(share.label, "Share Chart")
        XCTAssertEqual(customize.label, "Customize")
        if stacked {
            XCTAssertLessThan(share.frame.maxY, customize.frame.minY)
        } else {
            XCTAssertLessThan(share.frame.maxX, customize.frame.minX)
            XCTAssertLessThan(customize.frame.width, share.frame.width)
            XCTAssertEqual(customize.frame.midY, share.frame.midY, accuracy: 2)
        }
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

    @MainActor private func cancelNativeShare(_ app: XCUIApplication) {
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        // Native sheet controls can become accessible while their presentation is
        // still moving. Target only its close button once its frame has settled.
        var previousFrame = CGRect.null
        var stableSince = Date()
        let settled = NSPredicate { _, _ in
            let frame = close.frame
            guard close.isHittable, frame == previousFrame else {
                previousFrame = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)],
                                     timeout: 5), .completed)
        capture("Native share sheet before cancel")
        close.tap()
        XCTAssertTrue(app.cells["Copy"].firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
