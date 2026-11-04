import Network
import XCTest

final class LiveHeartRateSharingUITests: XCTestCase {
    private let deviceIdentifier = "deviceConnectionMenu"
    private let startSharingIdentifier = "startLiveHeartRateSharing"
    private let stopSharingIdentifier = "stopLiveHeartRateSharing"
    private let statusIdentifier = "deviceSharingStatus"
    private let connectionMessage = "Connect a heart rate monitor to share."
    private let genericConnectionMessage = "No device connected. Tap Device to connect."

    @MainActor
    func testDisconnectedHomeSharingShowsOneStableConnectPrompt() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchHome()
        defer { app.terminate() }

        assertNoSharingChrome(in: app)
        openDeviceMenu(in: app)
        for _ in 0..<3 {
            app.buttons[startSharingIdentifier].tap()
            assertSingleConnectPrompt(in: app)
        }
        captureScreenshot("Device menu share requires a monitor")
        closeDeviceMenu(in: app)
        assertNoSharingChrome(in: app)

        openDeviceMenu(in: app)
        connectSimulator(in: app)
        assertNoSharingChrome(in: app)
        XCTAssertEqual(app.buttons[deviceIdentifier].value as? String, "Monitor connected")
        openDeviceMenu(in: app)
        XCTAssertFalse(app.staticTexts[connectionMessage].exists)
        XCTAssertTrue(app.buttons[startSharingIdentifier].exists)
        XCTAssertFalse(app.buttons[stopSharingIdentifier].exists)
        XCTAssertFalse(app.staticTexts["liveHeartRateShareCode"].exists)
        closeDeviceMenu(in: app)
    }

    @MainActor
    func testInvalidFriendCodeKeepsErrorInDeviceMenuAndAllowsRetry() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try LoopbackSharingServer()
        let baseURL = try server.start()
        defer { server.stop() }
        let app = launchHome(additionalArguments: ["-BPM_API_BASE_URL", baseURL.absoluteString])
        defer { app.terminate() }

        openDeviceMenu(in: app)
        app.buttons["View a Friend's BPM"].tap()
        let friendCode = app.textFields["friendShareCode"]
        XCTAssertTrue(friendCode.waitForExistence(timeout: 5))
        friendCode.tap()
        friendCode.typeText("654321")
        let connect = app.buttons["connectFriendShareCode"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        let status = app.staticTexts[statusIdentifier]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(app.staticTexts.matching(identifier: statusIdentifier).count, 1)
        XCTAssertTrue(app.navigationBars["Select Device"].exists)
        XCTAssertFalse(friendCode.isEnabled)
        XCTAssertGreaterThanOrEqual(server.requestCount(method: "GET", path: "/api/share/654321"), 1)
        let firstError = status.label
        captureScreenshot("Invalid friend code error remains in Device menu")

        closeDeviceMenu(in: app)
        assertNoSharingChrome(in: app)
        XCTAssertFalse(app.staticTexts[statusIdentifier].exists)
        XCTAssertFalse(app.staticTexts[firstError].exists)
        XCTAssertEqual(app.buttons["Workout"].value as? String, "No active workout")
        XCTAssertFalse(app.buttons["Workout"].isEnabled)
        XCTAssertTrue(app.buttons["HRV"].isEnabled)
        openDeviceMenu(in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        app.buttons["disconnectFriendShareCode"].tap()
        XCTAssertTrue(friendCode.isEnabled)
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        friendCode.tap()
        friendCode.typeText("123456")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(app.staticTexts.matching(identifier: statusIdentifier).count, 1)
        XCTAssertTrue(app.navigationBars["Select Device"].exists)
        XCTAssertGreaterThanOrEqual(server.requestCount(method: "GET", path: "/api/share/123456"), 1)
        app.buttons["disconnectFriendShareCode"].tap()
        XCTAssertTrue(friendCode.isEnabled)
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        closeDeviceMenu(in: app)
        assertNoSharingChrome(in: app)
    }

    @MainActor
    func testWorkoutSharingPromptPreservesWorkoutAndFitsBothOrientations() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchHome()
        defer {
            XCUIDevice.shared.orientation = .portrait
            clearWorkout(in: app)
            app.terminate()
        }

        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons[deviceIdentifier].waitForExistence(timeout: 5))
        assertWorkoutHeaderFits(in: app)
        assertNoSharingChrome(in: app)
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 1) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let initialElapsed = longestVisibleTime(in: app)

        openDeviceMenu(in: app)
        for _ in 0..<3 {
            app.buttons[startSharingIdentifier].tap()
            assertSingleConnectPrompt(in: app)
        }
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["End"].exists)
        XCTAssertFalse(app.buttons["Start"].exists)
        assertNoSharingChrome(in: app)
        let timerAdvances = NSPredicate { _, _ in
            self.longestVisibleTime(in: app) > initialElapsed
        }
        expectation(for: timerAdvances, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        captureScreenshot("Workout sharing controls stay in Device menu")

        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        assertWorkoutHeaderFits(in: app)
        openDeviceMenu(in: app)
        app.buttons[startSharingIdentifier].tap()
        assertSingleConnectPrompt(in: app)
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        assertNoSharingChrome(in: app)

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        let pausedElapsed = longestVisibleTime(in: app)
        openDeviceMenu(in: app)
        app.buttons[startSharingIdentifier].tap()
        assertSingleConnectPrompt(in: app)
        connectSimulator(in: app)
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertTrue(app.buttons["End"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertEqual(longestVisibleTime(in: app), pausedElapsed, accuracy: 0.1)
        assertNoSharingChrome(in: app)
        XCTAssertEqual(app.buttons[deviceIdentifier].value as? String, "Monitor connected")
    }

    @MainActor
    func testJoiningFriendConfirmsClearingCurrentWorkoutAndDisconnectsMonitor() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try LoopbackSharingServer()
        let baseURL = try server.start()
        defer { server.stop() }
        let app = launchHome(additionalArguments: ["-BPM_API_BASE_URL", baseURL.absoluteString])
        defer { app.terminate() }
        openDeviceMenu(in: app)
        connectSimulator(in: app)
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 1) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        openDeviceMenu(in: app)
        app.buttons["View a Friend's BPM"].tap()
        let friendCode = app.textFields["friendShareCode"]
        friendCode.tap()
        friendCode.typeText("123456")
        app.buttons["connectFriendShareCode"].tap()
        let confirmation = app.alerts["End Current Workout?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(friendCode.isEnabled)
        XCTAssertEqual(server.requestCount(method: "GET", path: "/api/share/123456"), 0)
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["End"].exists)
        app.buttons["workoutHome"].tap()
        app.buttons["HRV"].tap()
        XCTAssertTrue(app.buttons["xmark"].waitForExistence(timeout: 5))

        openDeviceMenu(in: app)
        app.buttons["View a Friend's BPM"].tap()
        friendCode.tap()
        friendCode.typeText("123456")
        app.buttons["connectFriendShareCode"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["End Workout and Connect"].tap()
        XCTAssertTrue(app.buttons["disconnectFriendShareCode"].waitForExistence(timeout: 5))
        // Viewing stops discovery, which removes a disconnected simulator row.
        XCTAssertTrue(app.buttons["Disconnect Monitor"].waitForNonExistence(timeout: 5))
        app.buttons["disconnectFriendShareCode"].tap()
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["xmark"].waitForExistence(timeout: 5))
        app.buttons["xmark"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[deviceIdentifier].value as? String, "Not connected")
        XCTAssertEqual(app.buttons["Workout"].value as? String, "No active workout")
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertFalse(app.buttons["Save Workout"].exists)
        XCTAssertFalse(app.buttons["resumeEndedWorkout"].exists)
        app.buttons["workoutHome"].tap()
    }

    @MainActor
    func testWorkoutCanStartAndStopLiveSharingWithoutInterruptingTimer() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try LoopbackSharingServer()
        let baseURL = try server.start()
        defer { server.stop() }
        let app = launchHome(additionalArguments: ["-BPM_API_BASE_URL", baseURL.absoluteString])
        defer {
            clearWorkout(in: app)
            app.terminate()
        }

        openDeviceMenu(in: app)
        connectSimulator(in: app)
        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 1) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let initialElapsed = longestVisibleTime(in: app)
        openDeviceMenu(in: app)
        app.buttons[startSharingIdentifier].tap()
        let stopSharing = app.buttons[stopSharingIdentifier]
        XCTAssertTrue(stopSharing.waitForExistence(timeout: 10))

        let code = app.staticTexts["liveHeartRateShareCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        let originalCode = code.label
        XCTAssertEqual(originalCode.filter(\.isNumber), "123456")
        XCTAssertTrue(app.buttons["shareLiveHeartRateInvite"].exists)
        XCTAssertFalse(app.buttons["View a Friend's BPM"].exists)
        XCTAssertFalse(app.textFields["friendShareCode"].exists)
        XCTAssertEqual(server.requestCount(method: "POST", path: "/api/share"), 1)
        let copy = app.buttons["copyLiveHeartRateShareCode"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: copy)
        waitForExpectations(timeout: 3)
        captureScreenshot("Live sharing code and controls in Device menu")
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        assertWorkoutHeaderFits(in: app)
        assertNoSharingChrome(in: app)
        expectation(for: NSPredicate { _, _ in
            self.longestVisibleTime(in: app) > initialElapsed
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)

        app.buttons["workoutHome"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        assertNoSharingChrome(in: app)
        openDeviceMenu(in: app)
        XCTAssertTrue(stopSharing.exists)
        XCTAssertEqual(code.label, originalCode)
        XCTAssertEqual(server.requestCount(method: "POST", path: "/api/share"), 1)
        closeDeviceMenu(in: app)
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        assertNoSharingChrome(in: app)

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        let pausedElapsed = longestVisibleTime(in: app)
        openDeviceMenu(in: app)
        XCTAssertEqual(code.label, originalCode)
        XCTAssertEqual(server.requestCount(method: "POST", path: "/api/share"), 1)
        stopSharing.tap()
        XCTAssertTrue(app.buttons[startSharingIdentifier].waitForExistence(timeout: 5))
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Disconnect Sharing"].exists)
        closeDeviceMenu(in: app)
        XCTAssertTrue(app.buttons["Start"].exists)
        XCTAssertTrue(app.buttons["End"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertEqual(longestVisibleTime(in: app), pausedElapsed, accuracy: 0.1)
        assertNoSharingChrome(in: app)
        expectation(for: NSPredicate { _, _ in
            server.requestCount(method: "DELETE", path: "/api/share") == 1
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(server.requestCount(method: "POST", path: "/api/share"), 1)
    }

    @MainActor
    func testHomeNavigationPreservesRunningAndPausedWorkout() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchHome()
        defer {
            clearWorkout(in: app)
            app.terminate()
        }

        app.buttons["Workout"].tap()
        app.buttons["Start"].tap()
        if app.alerts["Start Workout"].waitForExistence(timeout: 1) {
            app.alerts["Start Workout"].buttons["Start from now"].tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let initialElapsed = longestVisibleTime(in: app)
        app.buttons["workoutHome"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Clear Workout"].exists)
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in
            self.longestVisibleTime(in: app) > initialElapsed
        }, evaluatedWith: app)
        waitForExpectations(timeout: 5)

        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        let pausedElapsed = longestVisibleTime(in: app)
        app.buttons["workoutHome"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Clear Workout"].exists)
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["End"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertEqual(longestVisibleTime(in: app), pausedElapsed, accuracy: 0.1)
        captureScreenshot("Paused workout survives Home navigation")
    }

    @MainActor
    private func launchHome(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Prevent a previously saved friend code from starting network polling.
        app.launchArguments = ["-BPM_FriendCode", ""] + additionalArguments
        app.launch()
        clearWorkout(in: app)
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func clearWorkout(in app: XCUIApplication) {
        let home = app.buttons["workoutHome"]
        if !home.exists, app.buttons["Workout"].exists {
            app.buttons["Workout"].tap()
        }
        guard home.waitForExistence(timeout: 3) else { return }
        let end = app.buttons["End"]
        if end.exists && end.isEnabled { end.tap() }
        let reset = app.buttons["Reset"]
        if reset.waitForExistence(timeout: 1), reset.isEnabled {
            reset.tap()
            let confirm = app.alerts["Reset Workout"].buttons["Reset"]
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        home.tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openDeviceMenu(in app: XCUIApplication) {
        let device = app.buttons[deviceIdentifier]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func closeDeviceMenu(in app: XCUIApplication) {
        app.navigationBars["Select Device"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertNoSharingChrome(in app: XCUIApplication) {
        for identifier in ["toggleLiveHeartRateSharing", startSharingIdentifier, stopSharingIdentifier,
                           "copyLiveHeartRateShareCode"] {
            XCTAssertFalse(app.buttons[identifier].exists, "Sharing controls belong in the Device menu")
        }
        XCTAssertFalse(app.staticTexts["liveHeartRateShareCode"].exists)
        XCTAssertFalse(app.staticTexts[connectionMessage].exists)
        XCTAssertFalse(app.staticTexts[statusIdentifier].exists)
        let sharingLabel = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Viewing:", "Sharing:")
        XCTAssertFalse(app.buttons.matching(sharingLabel).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(sharingLabel).firstMatch.exists)
    }

    @MainActor
    private func assertSingleConnectPrompt(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Select Device"].exists)
        let prompt = app.staticTexts[statusIdentifier]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        XCTAssertEqual(prompt.label, connectionMessage)
        XCTAssertEqual(app.staticTexts.matching(identifier: statusIdentifier).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", connectionMessage)).count, 1)
        XCTAssertFalse(app.staticTexts[genericConnectionMessage].exists)
        XCTAssertFalse(app.staticTexts["Please connect a heart rate device before sharing."].exists)
        XCTAssertTrue(app.buttons[startSharingIdentifier].isEnabled)
        XCTAssertFalse(app.buttons[stopSharingIdentifier].exists)
        XCTAssertFalse(app.staticTexts["liveHeartRateShareCode"].exists)
        if !prompt.isHittable { app.swipeUp() }
        XCTAssertTrue(prompt.isHittable)
    }

    @MainActor
    private func connectSimulator(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        let monitor = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator HR Monitor")).firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        if !monitor.isHittable { app.swipeDown() }
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertWorkoutHeaderFits(in app: XCUIApplication) {
        let controls = [app.buttons["workoutHome"], app.buttons[deviceIdentifier],
                        app.buttons["Workout History"], app.buttons["Settings"]]
        for control in controls {
            XCTAssertTrue(control.exists)
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, app.frame.maxY)
        }
        let frames = controls.map(\.frame).sorted { $0.minX < $1.minX }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX, "Workout header controls must not overlap")
        }
    }

    @MainActor
    private func longestVisibleTime(in app: XCUIApplication) -> TimeInterval {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+:[0-9]{2}(\\.[0-9])?"))
            .allElementsBoundByIndex.compactMap { element -> TimeInterval? in
                let parts = element.label.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
                return minutes * 60 + seconds
            }.max() ?? 0
    }

    @MainActor
    private func captureScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Serves only synthetic sharing responses on an ephemeral loopback port.
private final class LoopbackSharingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BPMUITests.LiveHeartRateSharingServer")
    private let stateLock = NSLock()
    private var requests: [String: Int] = [:]
    private var startupError: NWError?
    private var connections: [NWConnection] = []
    private var stopped = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                self?.stateLock.lock()
                self?.startupError = error
                self?.stateLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            stop()
            throw ServerError.startupTimeout
        }
        stateLock.lock()
        let error = startupError
        stateLock.unlock()
        if let error { throw error }
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            throw ServerError.missingPort
        }
        return url
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func requestCount(method: String, path: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requests["\(method) \(path)", default: 0]
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = buffered
            if let data { request.append(data) }
            if let headerEnd = request.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) {
                let lines = headers.components(separatedBy: "\r\n")
                let contentLength = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count >= headerEnd.upperBound + contentLength {
                    self.respond(to: lines.first ?? "", on: connection)
                    return
                }
            }
            if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffered: request)
            }
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let key = parts.prefix(2).joined(separator: " ")
        stateLock.lock()
        requests[key, default: 0] += 1
        stateLock.unlock()
        let body: String
        let status: String
        switch key {
        case "POST /api/share":
            status = "200 OK"
            body = "{\"code\":\"123456\",\"token\":\"ui-test-token\"}"
        case "POST /api/share/beat", "DELETE /api/share":
            status = "200 OK"
            body = "{\"ok\":true}"
        case "POST /api/share/workout":
            status = "200 OK"
            body = "{\"commands\":[],\"serverTime\":\(Int64(Date().timeIntervalSince1970 * 1000))}"
        default:
            status = "404 Not Found"
            body = "{\"error\":\"Unknown test endpoint\"}"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum ServerError: Error {
        case startupTimeout
        case missingPort
    }
}
