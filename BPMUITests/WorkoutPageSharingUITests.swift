import XCTest

final class WorkoutPageSharingUITests: XCTestCase {
    @MainActor
    func testPageChoiceKeepsDrawerAndCardLayoutFixed() {
        let app = launchWorkout()
        app.buttons["openWorkoutShareDrawer"].tap()
        let option = app.buttons["includeWorkoutPage"]
        let disclosure = app.staticTexts["workoutPageDisclosure"]
        let chart = app.buttons["openChartCard"]
        let share = app.buttons["shareSelectedWorkoutFormat"]
        let customize = app.buttons["customizeWorkoutCard"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertEqual(option.value as? String, "Off")
        XCTAssertEqual(disclosure.label, "Anyone with the link can view and download your workout until you delete it.")
        XCTAssertFalse(app.buttons["reviewWorkoutPage"].exists)
        let chartBefore = chart.frame
        // The card uses 260 layout points. UIKit scales a compact sheet slightly
        // below its full-width presentation, including its accessibility frames.
        XCTAssertGreaterThanOrEqual(chartBefore.width, 245)
        XCTAssertLessThanOrEqual(chartBefore.width, 261)
        let shareBefore = share.frame
        let customizeBefore = customize.frame
        let disclosureBefore = disclosure.frame

        option.tap()
        XCTAssertEqual(option.value as? String, "On")
        XCTAssertFalse(app.buttons["reviewWorkoutPage"].exists)
        XCTAssertTrue(share.isEnabled)
        assertSameFrame(chart.frame, chartBefore)
        assertSameFrame(share.frame, shareBefore)
        assertSameFrame(customize.frame, customizeBefore)
        assertSameFrame(disclosure.frame, disclosureBefore)
        capture("Workout link enabled without drawer layout changes")

        customize.tap()
        XCTAssertTrue(app.navigationBars["Chart Card"].waitForExistence(timeout: 5))
        let editor = app.scrollViews["workoutCardEditorScroll"]
        let cardTitle = app.textFields["workoutCardTitleField"]
        reveal(cardTitle, in: editor, above: app.buttons["shareWorkoutImage"])
        XCTAssertEqual(cardTitle.value as? String, "Morning intervals")
        let cardOption = editor.buttons["includeWorkoutPage"]
        reveal(cardOption, in: editor, above: app.buttons["shareWorkoutImage"])
        XCTAssertEqual(cardOption.value as? String, "On")
        let cardDisclosure = editor.staticTexts["workoutPageDisclosure"]
        XCTAssertTrue(cardDisclosure.exists)
        XCTAssertFalse(app.buttons["reviewWorkoutPage"].exists)
        let preview = editor.descendants(matching: .any).matching(identifier: "workoutSharePreview").firstMatch
        let previewBefore = preview.frame
        let editorOptionBefore = cardOption.frame
        let cardShareBefore = app.buttons["shareWorkoutImage"].frame
        cardOption.tap()
        XCTAssertEqual(cardOption.value as? String, "Off")
        assertSameFrame(preview.frame, previewBefore)
        assertSameFrame(cardOption.frame, editorOptionBefore)
        assertSameFrame(app.buttons["shareWorkoutImage"].frame, cardShareBefore)
        XCTAssertTrue(cardDisclosure.exists)
        cardOption.tap()
        XCTAssertEqual(cardOption.value as? String, "On")
        assertSameFrame(preview.frame, previewBefore)
        assertSameFrame(cardOption.frame, editorOptionBefore)
        capture("Workout link enabled without card layout changes")
        app.buttons["closeWorkoutCardEditor"].tap()
        app.buttons["closeWorkoutShareDrawer"].tap()

        app.buttons["openWorkoutShareDrawer"].tap()
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertEqual(option.value as? String, "Off")
        XCTAssertTrue(disclosure.exists)
    }

    @MainActor
    func testChoosingFormatsKeepsConsentWithinDrawer() {
        let app = launchWorkout()
        app.buttons["openWorkoutShareDrawer"].tap()
        let option = app.buttons["includeWorkoutPage"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        for format in [2, 3, 1, 0] {
            app.buttons["shareFormat\(format)"].tap()
            XCTAssertEqual(option.value as? String, "On")
            XCTAssertEqual(app.buttons["customizeWorkoutCard"].exists, format < 2)
        }
        option.tap()
        XCTAssertEqual(option.value as? String, "Off")
        XCTAssertTrue(app.staticTexts["workoutPageDisclosure"].exists)
        XCTAssertFalse(app.buttons["reviewWorkoutPage"].exists)
    }

    @MainActor
    func testDirectCardShareCreatesOptionalLinkWithoutOpeningEditor() {
        let app = launchWorkout()
        app.buttons["openWorkoutShareDrawer"].tap()
        app.buttons["includeWorkoutPage"].tap()
        app.buttons["shareSelectedWorkoutFormat"].tap()
        let copy = app.cells["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["closeWorkoutCardEditor"].exists)
        XCTAssertFalse(app.textFields["workoutCardTitleField"].exists)
        capture("Direct card share with private workout link")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeWorkoutShareDrawer"].waitForNonExistence(timeout: 5))
        let url = app.staticTexts["savedWorkoutPageURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertTrue(url.label.hasPrefix("https://bpm.example/w/"))
        let components = URLComponents(string: url.label)
        XCTAssertEqual(components?.path.split(separator: "/").last?.count, 22)
        XCTAssertEqual(components?.fragment?.count, 43)
        XCTAssertNil(components?.query)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchWorkout() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workout-share-ui-test", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let workout = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Morning intervals, Workout")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 10))
        workout.tap()
        XCTAssertTrue(app.buttons["openWorkoutShareDrawer"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, above footer: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let top = scroll.frame.minY + 8
        let bottom = min(scroll.frame.maxY, footer.frame.minY - 12)
        for _ in 0..<10 {
            if element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            let upward = element.frame.midY > (top + bottom) / 2
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.65 : 0.25))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: upward ? 0.25 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("The control was not fully visible above the Share button: \(element.debugDescription)")
    }
}
