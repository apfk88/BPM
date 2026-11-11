import XCTest

final class WorkoutRecapUITests: XCTestCase {
    @MainActor func testShortHistoryStartsImmediatelyAndRecapReviewSavePersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--workout-voice-ui-test"]
        app.launch()
        app.resetWorkoutAndReturnHome()
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
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Start Workout"].exists)
        app.buttons["End"].tap()
        app.buttons["Save Workout"].tap()
        XCTAssertTrue(app.staticTexts["Favorites"].exists)
        XCTAssertTrue(app.buttons["Functional Strength"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Other…"].exists)
        for _ in 0..<6 where !app.buttons["Yoga"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Yoga"].isHittable)
        app.buttons["Yoga"].tap()
        XCTAssertTrue(app.navigationBars["Save Workout"].waitForExistence(timeout: 5))
        let voiceAction = app.buttons["voiceCaptureAction"]
        func waitForVoiceState(_ label: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
            let state = app.buttons.matching(identifier: "voiceCaptureAction")
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: timeout), "Expected voice state: \(label)", file: file, line: line)
        }
        func captureVoiceState(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        waitForVoiceState("Record workout notes")
        XCTAssertTrue(voiceAction.isEnabled)
        let idleVoiceFrame = voiceAction.frame
        func assertStableVoiceFrame(file: StaticString = #filePath, line: UInt = #line) {
            let frame = voiceAction.frame
            XCTAssertEqual(frame.minX, idleVoiceFrame.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.minY, idleVoiceFrame.minY, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.width, idleVoiceFrame.width, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.height, idleVoiceFrame.height, accuracy: 1, file: file, line: line)
        }
        captureVoiceState("Voice button idle")
        let title = "Recap check \(UUID().uuidString.prefix(6))"
        app.textFields["Title"].tap()
        let original = app.textFields["Title"].value as? String ?? ""
        app.textFields["Title"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + title)
        app.textViews["Workout description"].tap()
        app.textViews["Workout description"].typeText("Existing note.")
        voiceAction.tap()
        let permissionUI = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = permissionUI.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        waitForVoiceState("Recording…")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Save Workout"].exists)
        XCTAssertFalse(app.navigationBars["Workout Recap"].exists)
        sleep(1)
        XCTAssertTrue(voiceAction.isEnabled)
        assertStableVoiceFrame()
        captureVoiceState("Voice button recording")
        app.buttons["Stop"].tap()
        waitForVoiceState("Send recording")
        XCTAssertTrue(voiceAction.isEnabled)
        assertStableVoiceFrame()
        XCTAssertFalse(app.buttons["Discard recording"].exists)
        XCTAssertTrue(app.buttons["Record again"].exists)
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        captureVoiceState("Voice button ready to send")
        app.buttons["Record again"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        waitForVoiceState("Recording…")
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        sleep(1)
        voiceAction.tap()
        let voiceConsent = app.alerts["Send recording?"]
        XCTAssertTrue(voiceConsent.waitForExistence(timeout: 3))
        XCTAssertTrue(voiceConsent.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "OpenAI", "health details")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Processing…"].exists)
        let consentScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        consentScreenshot.name = "Voice permission before upload"
        consentScreenshot.lifetime = .keepAlways
        add(consentScreenshot)
        voiceConsent.buttons["Cancel"].tap()
        waitForVoiceState("Send recording")
        XCTAssertTrue(app.buttons["Record again"].exists)
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        XCTAssertFalse(app.buttons["Processing…"].exists)
        voiceAction.tap()
        XCTAssertTrue(voiceConsent.waitForExistence(timeout: 3))
        voiceConsent.buttons["Allow & Send"].tap()
        waitForVoiceState("Processing…", timeout: 2)
        XCTAssertFalse(voiceAction.isEnabled)
        assertStableVoiceFrame()
        captureVoiceState("Voice button processing")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        app.buttons["Cancel request"].tap()
        waitForVoiceState("Send recording", timeout: 3)
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        voiceAction.tap()
        XCTAssertFalse(voiceConsent.exists)
        XCTAssertTrue(app.buttons["Undo AI changes"].waitForExistence(timeout: 10))
        waitForVoiceState("Notes ready")
        XCTAssertTrue(voiceAction.isEnabled)
        assertStableVoiceFrame()
        captureVoiceState("Voice button notes ready")
        XCTAssertEqual(app.textFields["Title"].value as? String, "Squats and push-ups")
        XCTAssertTrue((app.textViews["Workout description"].value as? String ?? "").contains("62.5 kg"))
        app.buttons["Undo AI changes"].tap()
        waitForVoiceState("Record workout notes")
        assertStableVoiceFrame()
        XCTAssertEqual(app.textFields["Title"].value as? String, title)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, "Existing note.")
        voiceAction.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        sleep(1)
        voiceAction.tap()
        XCTAssertTrue(app.buttons["Undo AI changes"].waitForExistence(timeout: 10))
        waitForVoiceState("Notes ready")
        let completedTitle = app.textFields["Title"].value as? String
        let completedNotes = app.textViews["Workout description"].value as? String
        // A completed result keeps the same button available to record another note.
        voiceAction.tap()
        waitForVoiceState("Recording…")
        XCTAssertTrue(app.buttons["Stop"].exists)
        XCTAssertEqual(app.textFields["Title"].value as? String, completedTitle)
        XCTAssertEqual(app.textViews["Workout description"].value as? String, completedNotes)
        sleep(1)
        assertStableVoiceFrame()
        voiceAction.tap()
        waitForVoiceState("Processing…", timeout: 2)
        XCTAssertFalse(voiceAction.isEnabled)
        waitForVoiceState("Notes ready", timeout: 10)
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
        for _ in 0..<5 where !app.buttons["Workout History"].isHittable { app.swipeDown() }
        app.swipeUp()
        app.buttons["Workout History"].tap()
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        XCTAssertTrue(app.staticTexts[editedWords].waitForExistence(timeout: 5))
    }
}
