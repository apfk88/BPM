import XCTest

final class LiveActivityLifecycleUITests: XCTestCase {
    @MainActor
    func testLocalHeartRateEndsAsSoonAsReadingsStop() {
        let app = launchFixture()
        defer { app.terminate() }

        perform("Local 220", in: app)
        assertActivityCount(1, in: app)
        assertDetailsContain("BPM 220", in: app)

        perform("No reading", in: app)
        assertActivityCount(0, in: app)
    }

    @MainActor
    func testFriendActivityEndsOnMissingReadingsAndStopViewing() {
        let app = launchFixture()
        defer { app.terminate() }

        perform("Friend 188", in: app)
        assertActivityCount(1, in: app)
        assertDetailsContain("BPM 188", in: app)
        assertDetailsContain("viewing true", in: app)

        perform("No reading", in: app)
        assertActivityCount(0, in: app)

        perform("Friend 188", in: app)
        assertActivityCount(1, in: app)
        perform("Stop viewing", in: app)
        assertActivityCount(0, in: app)
    }

    @MainActor
    func testTimerOnlyActivitySurvivesMissingHeartRateAndEndsWithWorkout() {
        let app = launchFixture()
        defer { app.terminate() }

        perform("Timer only", in: app)
        assertActivityCount(1, in: app)
        assertDetailsContain("BPM none, timer 3661", in: app)

        perform("No reading", in: app)
        assertActivityCount(1, in: app)
        assertDetailsContain("BPM none, timer 3661", in: app)
        captureScreenshot("Timer-only Live Activity fixture")

        perform("End workout", in: app)
        assertActivityCount(0, in: app)
    }

    @MainActor
    func testConcurrentActivitiesProvideConstrainedIslandScreenshot() {
        let app = launchFixture()
        defer { app.terminate() }

        perform("Local 220", in: app)
        assertActivityCount(1, in: app)
        perform("Second activity", in: app)
        assertActivityCount(2, in: app)
        assertDetailsContain("Comparison: BPM 99", in: app)

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        // SpringBoard becomes foreground before the Home/Island animation finishes.
        // Allow that animation to settle before recording the visual artifact.
        let rendered = expectation(description: "Dynamic Island rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { rendered.fulfill() }
        wait(for: [rendered], timeout: 5)
        captureScreenshot("Concurrent Live Activities on Dynamic Island")

        app.activate()
        perform("Refresh count", in: app)
        assertActivityCount(2, in: app)
        perform("End all", in: app)
        assertActivityCount(0, in: app)
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--live-activity-ui-test", "-BPM_FriendCode", ""]
        app.launch()
        XCTAssertTrue(app.navigationBars["Live Activity check"].waitForExistence(timeout: 10))
        assertActivityCount(0, in: app)
        return app
    }

    @MainActor
    private func perform(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        for _ in 0..<5 {
            if button.exists && button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing fixture action: \(title)")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        wait(for: [enabled], timeout: 5)
        XCTAssertTrue(button.isHittable, "Fixture action must be tappable: \(title)")
        button.tap()

        scrollToState(in: app)
        let action = app.staticTexts["live-activity-action"]
        let performed = expectation(for: NSPredicate(format: "label == %@", title), evaluatedWith: action)
        wait(for: [performed], timeout: 5)
    }

    @MainActor
    private func assertActivityCount(_ count: Int, in app: XCUIApplication) {
        scrollToState(in: app)
        let state = app.staticTexts["live-activity-count"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let matches = expectation(
            for: NSPredicate(format: "label == %@", "Activities: \(count)"), evaluatedWith: state
        )
        wait(for: [matches], timeout: 5)
    }

    @MainActor
    private func assertDetailsContain(_ text: String, in app: XCUIApplication) {
        let details = app.staticTexts["live-activity-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(details.label.contains(text), "Expected \(text) in \(details.label)")
    }

    @MainActor
    private func scrollToState(in app: XCUIApplication) {
        let state = app.staticTexts["live-activity-count"]
        for _ in 0..<5 {
            if state.exists && state.isHittable { break }
            app.swipeDown()
        }
    }

    @MainActor
    private func captureScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
