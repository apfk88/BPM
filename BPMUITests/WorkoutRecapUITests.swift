import XCTest

final class WorkoutRecapUITests: XCTestCase {
    @MainActor func testRecoveryCancelAndRecapReviewSavePersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--workout-voice-ui-test"]
        app.launch()
        if app.buttons["xmark"].waitForExistence(timeout: 2) {
            app.buttons["xmark"].tap()
            if app.alerts["Clear Workout"].waitForExistence(timeout: 1) { app.alerts.buttons["Clear"].tap() }
        }
        app.buttons["Settings"].tap()
        let resetVoicePermission = app.buttons["Reset AI voice permission"]
        for _ in 0..<5 where !resetVoicePermission.isHittable { app.swipeUp() }
        XCTAssertTrue(resetVoicePermission.exists)
        if resetVoicePermission.isEnabled { resetVoicePermission.tap() }
        app.buttons["Done"].tap()
        app.buttons["Device"].tap()
        let monitor = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator HR Monitor")).firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        sleep(1)
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        // The simulator's synthetic monitor emits once per second.
        sleep(3)
        app.buttons["Start"].tap()
        let start = app.alerts["Start Workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Start"].exists)
        app.buttons["Start"].tap()
        start.buttons["Include previous measurements"].tap()
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 5))
        app.buttons["End"].tap()
        app.buttons["Save Workout"].tap()
        XCTAssertTrue(app.staticTexts["Favorites"].exists)
        XCTAssertTrue(app.buttons["Functional Strength"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Other…"].exists)
        for _ in 0..<6 where !app.buttons["Yoga"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Yoga"].isHittable)
        app.buttons["Yoga"].tap()
        XCTAssertTrue(app.navigationBars["Save Workout"].waitForExistence(timeout: 5))
        let title = "Recap check \(UUID().uuidString.prefix(6))"
        app.textFields["Title"].tap()
        let original = app.textFields["Title"].value as? String ?? ""
        app.textFields["Title"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + title)
        app.textViews["Workout description"].tap()
        app.textViews["Workout description"].typeText("Existing note.")
        app.buttons["Record workout with AI voice"].tap()
        let permissionUI = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = permissionUI.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Save Workout"].exists)
        XCTAssertFalse(app.navigationBars["Workout Recap"].exists)
        sleep(1)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertFalse(app.buttons["Discard recording"].exists)
        XCTAssertTrue(app.buttons["Record again"].exists)
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        let controls = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        controls.name = "Voice controls ready to send"
        controls.lifetime = .keepAlways
        add(controls)
        app.buttons["Record again"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        sleep(1)
        app.buttons["Send"].tap()
        let voiceConsent = app.alerts["Send recording to OpenAI?"]
        XCTAssertTrue(voiceConsent.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Loading title and description…"].exists)
        let consentScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        consentScreenshot.name = "Explicit OpenAI permission before upload"
        consentScreenshot.lifetime = .keepAlways
        add(consentScreenshot)
        voiceConsent.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Record again"].exists)
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        XCTAssertFalse(app.staticTexts["Loading title and description…"].exists)
        app.buttons["Send"].tap()
        XCTAssertTrue(voiceConsent.waitForExistence(timeout: 3))
        voiceConsent.buttons["Send recording to OpenAI"].tap()
        XCTAssertTrue(app.staticTexts["Loading title and description…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        app.buttons["Cancel request"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        app.buttons["Send"].tap()
        XCTAssertFalse(voiceConsent.exists)
        XCTAssertTrue(app.buttons["Undo AI changes"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Title"].value as? String, "Squats and push-ups")
        XCTAssertTrue((app.textViews["Workout description"].value as? String ?? "").contains("62.5 kg"))
        app.buttons["Undo AI changes"].tap()
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        app.buttons["Record workout with AI voice"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        sleep(1)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Undo AI changes"].waitForExistence(timeout: 10))
        app.textFields["Title"].tap()
        let generatedTitle = app.textFields["Title"].value as? String ?? ""
        app.textFields["Title"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generatedTitle.count) + title)
        app.textViews["Workout description"].tap()
        app.textViews["Workout description"].typeText(" Felt steady.")
        let editedWords = (app.textViews["Workout description"].value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(editedWords.contains("62.5 kg"))
        XCTAssertTrue(editedWords.contains("Felt steady."))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Inline editable workout voice result (stubbed AI)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Save"].tap()
        if app.navigationBars["Health Access"].waitForExistence(timeout: 10) {
            for _ in 0..<4 where !app.buttons["UIA.Health.DoNotAllow.Button"].isHittable { app.swipeUp() }
            app.buttons["UIA.Health.DoNotAllow.Button"].tap()
            XCTAssertTrue(app.navigationBars["Health Access"].waitForNonExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let healthDeny = app.buttons["UIA.Health.DoNotAllow.Button"]
        if healthDeny.waitForExistence(timeout: 5) {
            healthDeny.tap()
            XCTAssertTrue(healthDeny.waitForNonExistence(timeout: 5))
            app.buttons["Settings"].tap()
        }
        for _ in 0..<5 where !resetVoicePermission.isHittable { app.swipeUp() }
        XCTAssertTrue(resetVoicePermission.isEnabled)
        resetVoicePermission.tap()
        XCTAssertFalse(resetVoicePermission.isEnabled)
        XCTAssertTrue(app.staticTexts["Permission will be requested before a recording is sent to OpenAI. You can always enter workout notes manually."].exists)
        for _ in 0..<5 where !app.buttons["Workout History"].isHittable { app.swipeDown() }
        app.swipeUp()
        app.buttons["Workout History"].tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        XCTAssertTrue(app.staticTexts[editedWords].waitForExistence(timeout: 5))
    }
}
