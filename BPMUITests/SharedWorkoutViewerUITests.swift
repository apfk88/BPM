import Network
import XCTest

final class SharedWorkoutViewerUITests: XCTestCase {
    @MainActor
    func testViewerNavigatesIndependentlyAndCanControlWorkoutWithoutSaving() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedWorkoutViewerServer()
        let app = launchViewer(baseURL: try server.start())
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            server.stop()
        }

        assertPage("table", in: app)
        assertViewerControls(in: app)
        XCTAssertTrue(app.buttons["sharedWorkSet"].isEnabled)
        XCTAssertTrue(app.buttons["sharedRestSet"].isEnabled)
        assertViewerIndicator(in: app)
        captureScreenshot("Shared workout green person badge and trainer controls")

        for page in ["bpm", "stats", "chart"] {
            app.swipeLeft()
            assertPage(page, in: app)
        }
        captureScreenshot("Viewer chooses chart independently")

        let pollCount = server.pollCount
        server.setHostNavigation(screen: "home", page: "bpm")
        waitUntil("Viewer receives host navigation update", in: app) { server.pollCount > pollCount }
        assertPage("chart", in: app)
        app.buttons["sharedWorkoutHome"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        assertViewerIndicator(in: app)
        XCTAssertFalse(app.alerts["Clear Workout"].exists)
        captureScreenshot("Viewer Home shows shared green device and workout badges")
        app.buttons["deviceConnectionMenu"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        let friendCode = app.textFields["friendShareCode"]
        XCTAssertTrue(friendCode.waitForExistence(timeout: 5))
        XCTAssertEqual(friendCode.value as? String, "123456")
        XCTAssertFalse(friendCode.isEnabled)
        XCTAssertTrue(app.buttons["disconnectFriendShareCode"].exists)
        captureScreenshot("Shared viewer code stays in Device menu")
        app.navigationBars["Select Device"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        assertViewerIndicator(in: app)
        XCTAssertTrue(app.buttons["HRV"].isEnabled)
        app.buttons["HRV"].tap()
        XCTAssertTrue(app.buttons["xmark"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].exists)
        app.buttons["xmark"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        app.buttons["Workout"].tap()
        assertPage("chart", in: app)
        assertViewerControls(in: app)

        // The host's screen selection does not limit commands for its running workout.
        app.buttons["sharedWorkSet"].tap()
        waitUntil("Work command received", in: app) { server.commands.count == 1 }
        waitUntil("Work command confirmed", in: app) { app.buttons["sharedRestSet"].isEnabled }
        let work = try XCTUnwrap(server.commands.first)
        XCTAssertEqual(work["action"] as? String, "work")
        XCTAssertEqual(work["code"] as? String, "123456")
        XCTAssertEqual(work["workoutID"] as? String, SharedWorkoutViewerServer.workoutID)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(work["id"] as? String)))
        XCTAssertEqual(work["controlRevision"] as? String, "revision-0")

        app.buttons["sharedRestSet"].tap()
        waitUntil("Rest command received", in: app) { server.commands.count == 2 }
        waitUntil("Rest command confirmed", in: app) { app.buttons["sharedWorkSet"].isEnabled }
        XCTAssertFalse(app.buttons["sharedRestSet"].isEnabled)
        let rest = server.commands[1]
        XCTAssertEqual(rest["action"] as? String, "rest")
        XCTAssertEqual(rest["controlRevision"] as? String, "revision-1")
        XCTAssertNotEqual(work["id"] as? String, rest["id"] as? String)
        XCTAssertEqual(Set(server.commands.compactMap { $0["action"] as? String }), Set(["work", "rest"]))

        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil("Viewer rotates to landscape", in: app) { app.frame.width > app.frame.height }
        assertPage("chart", in: app)
        assertViewerControls(in: app)
        assertViewerIndicator(in: app)
        for identifier in ["sharedWorkoutHome", "deviceConnectionMenu", "sharedWorkSet", "sharedRestSet"] {
            assertOnScreen(app.buttons[identifier], in: app)
        }
        captureScreenshot("Shared workout landscape chart")
    }

    @MainActor
    func testStaleAndPausedWorkoutsDisableRemoteControlsAndFreezeTimers() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedWorkoutViewerServer()
        let app = launchViewer(baseURL: try server.start())
        defer {
            app.terminate()
            server.stop()
        }

        assertPage("table", in: app)
        XCTAssertTrue(app.buttons["sharedWorkSet"].isEnabled)
        server.setStale(true)
        let status = app.staticTexts["sharedWorkoutStatus"]
        waitUntil("Stale workout disables remote controls", in: app, timeout: 9) {
            status.label == "Waiting for workout updates…" && !app.buttons["sharedWorkSet"].isEnabled
        }
        XCTAssertFalse(app.buttons["sharedRestSet"].isEnabled)
        XCTAssertFalse(app.buttons["sharedWorkoutPause"].isEnabled)
        XCTAssertFalse(app.buttons["sharedWorkoutEnd"].isEnabled)
        XCTAssertFalse(app.buttons["sharedWorkoutCool"].isEnabled)
        let frozenTotal = app.staticTexts["sharedWorkoutTotalTime"].label
        let frozenSet = app.staticTexts["sharedWorkoutSetTime"].label
        let stalePolls = server.pollCount
        waitUntil("Stale snapshot remains frozen across polls", in: app) { server.pollCount >= stalePolls + 2 }
        XCTAssertEqual(app.staticTexts["sharedWorkoutTotalTime"].label, frozenTotal)
        XCTAssertEqual(app.staticTexts["sharedWorkoutSetTime"].label, frozenSet)
        XCTAssertTrue(server.commands.isEmpty)
        captureScreenshot("Stale shared workout disables set controls")

        server.setPaused(true)
        server.setStale(false)
        waitUntil("Paused workout arrives", in: app) { status.label == "Paused" }
        XCTAssertFalse(app.buttons["sharedWorkSet"].isEnabled)
        XCTAssertFalse(app.buttons["sharedRestSet"].isEnabled)
        let pausedTotal = app.staticTexts["sharedWorkoutTotalTime"].label
        let pausedSet = app.staticTexts["sharedWorkoutSetTime"].label
        let pausedPolls = server.pollCount
        waitUntil("Paused snapshot remains frozen across polls", in: app) { server.pollCount >= pausedPolls + 2 }
        XCTAssertEqual(app.staticTexts["sharedWorkoutTotalTime"].label, pausedTotal)
        XCTAssertEqual(app.staticTexts["sharedWorkoutSetTime"].label, pausedSet)
        assertViewerControls(in: app)
        XCTAssertTrue(server.commands.isEmpty)
        captureScreenshot("Paused shared workout")

        server.setPaused(false)
        waitUntil("Fresh running workout restores set controls", in: app) {
            app.buttons["sharedWorkSet"].isEnabled && app.buttons["sharedRestSet"].isEnabled
        }
    }

    @MainActor
    func testTrainerCanPauseResumeEndResetStartAndCoolWithoutSaving() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedWorkoutViewerServer()
        let app = launchViewer(baseURL: try server.start())
        defer { app.terminate(); server.stop() }

        app.buttons["sharedWorkoutPause"].tap()
        waitUntil("Host confirms pause", in: app) { app.buttons["sharedWorkoutResume"].isEnabled }
        XCTAssertFalse(app.buttons["sharedWorkSet"].isEnabled)
        app.buttons["sharedWorkoutResume"].tap()
        waitUntil("Host confirms resume", in: app) { app.buttons["sharedWorkoutPause"].isEnabled }
        app.buttons["sharedWorkoutEnd"].tap()
        waitUntil("Host confirms end", in: app) { app.buttons["sharedWorkoutReset"].isEnabled }
        XCTAssertFalse(app.buttons["Save Workout"].exists)
        app.buttons["sharedWorkoutReset"].tap()
        XCTAssertTrue(app.alerts["Reset Workout"].waitForExistence(timeout: 5))
        app.alerts["Reset Workout"].buttons["Reset"].tap()
        waitUntil("Host confirms reset", in: app) { app.buttons["sharedWorkoutStart"].isEnabled }
        XCTAssertTrue(app.buttons["sharedWorkoutLoadPreset"].isEnabled)
        app.buttons["sharedWorkoutStart"].tap()
        waitUntil("Host confirms start", in: app) { app.buttons["sharedWorkoutCool"].isEnabled }
        app.buttons["sharedWorkoutCool"].tap()
        waitUntil("Host confirms cooldown", in: app) {
            server.commands.last?["action"] as? String == "cool" && app.buttons["sharedWorkoutPause"].isEnabled
                && !app.buttons["sharedWorkoutCool"].isEnabled
        }
        XCTAssertEqual(server.commands.compactMap { $0["action"] as? String }, ["pause", "resume", "end", "reset", "start", "cool"])
        XCTAssertFalse(app.buttons["Save Workout"].exists)
        captureScreenshot("Trainer controls owner workout without a Save action")
    }

    @MainActor
    func testOwnerStoppingSharingAlertsViewerAndReturnsToCleanHome() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedWorkoutViewerServer()
        let app = launchViewer(baseURL: try server.start())
        defer { app.terminate(); server.stop() }
        assertPage("table", in: app)
        server.endSharing()
        let stopped = app.alerts["Sharing Stopped"]
        XCTAssertTrue(stopped.waitForExistence(timeout: 10))
        XCTAssertTrue(stopped.staticTexts["Your friend stopped sharing."].exists)
        stopped.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Workout"].value as? String, "No active workout")
        XCTAssertEqual(app.buttons["deviceConnectionMenu"].value as? String, "Not connected")
        XCTAssertFalse(app.buttons["sharedWorkoutHome"].exists)
        app.buttons["Workout"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertFalse(app.buttons["Save Workout"].exists)
        captureScreenshot("Stopped sharing clears viewer and returns Home")
    }

    @MainActor
    private func launchViewer(baseURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", "123456", "-BPM_API_BASE_URL", baseURL.absoluteString]
        app.launch()
        XCTAssertTrue(app.buttons["sharedWorkoutHome"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertPage(_ page: String, in app: XCUIApplication) {
        let indicator = app.descendants(matching: .any).matching(identifier: "sharedWorkoutPage").firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", page), evaluatedWith: indicator)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func assertViewerControls(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Save Workout"].exists, "Only the owner saves their workout")
        XCTAssertTrue(app.buttons["sharedWorkSet"].exists)
        XCTAssertTrue(app.buttons["sharedRestSet"].exists)
        XCTAssertTrue(app.buttons["sharedWorkoutEnd"].isEnabled)
        XCTAssertTrue(app.buttons["sharedWorkoutCool"].isEnabled)
        XCTAssertTrue(app.buttons["sharedWorkoutPause"].exists || app.buttons["sharedWorkoutResume"].exists)
    }

    @MainActor
    private func assertViewerIndicator(in app: XCUIApplication) {
        let device = app.buttons["deviceConnectionMenu"]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        XCTAssertEqual(device.value as? String, "Viewing shared BPM")
        assertOnScreen(device, in: app)
        for identifier in ["toggleLiveHeartRateSharing", "startLiveHeartRateSharing", "stopLiveHeartRateSharing",
                           "copyLiveHeartRateShareCode", "heartRateConnectionStatus"] {
            XCTAssertFalse(app.buttons[identifier].exists, "Sharing controls belong in the Device menu")
        }
        XCTAssertFalse(app.staticTexts["liveHeartRateShareCode"].exists)
        XCTAssertFalse(app.textFields["friendShareCode"].exists)
        let sharingLabel = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Viewing:", "Sharing:")
        XCTAssertFalse(app.buttons.matching(sharingLabel).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(sharingLabel).firstMatch.exists)
    }

    @MainActor
    private func assertOnScreen(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists)
        if element.isEnabled { XCTAssertTrue(element.isHittable) }
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(element.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY)
    }

    @MainActor
    private func waitUntil(_ description: String, in app: XCUIApplication, timeout: TimeInterval = 5,
                           condition: @escaping () -> Bool) {
        let conditionExpectation = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: app)
        conditionExpectation.expectationDescription = description
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func captureScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A synthetic broadcaster served from the test runner. No production API or
/// actual heart-rate measurements are used by these UI tests.
private final class SharedWorkoutViewerServer: @unchecked Sendable {
    static let workoutID = "2E7A0FE0-4698-414D-93FC-6106A693B48E"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BPMUITests.SharedWorkoutViewerServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var startupError: NWError?
    private var stopped = false
    private var receivedCommands: [[String: Any]] = []
    private var polls = 0
    private var sequence = 0
    private var revision = 0
    private var screen = "workout"
    private var page = "table"
    private var paused = false
    private var stale = false
    private var resting = false
    private var workoutState = "running"
    private var completed = false
    private var sharingEnded = false
    private var startedAt = Date()
    private var pausedElapsed: TimeInterval = 0
    private var lastSnapshot: [String: Any]?
    private var lastSnapshotTimestamp: Int64 = 0

    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return polls
    }

    var commands: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return receivedCommands
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                self?.lock.lock()
                self?.startupError = error
                self?.lock.unlock()
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw ServerError.startupTimeout }
        lock.lock()
        let error = startupError
        lock.unlock()
        if let error { throw error }
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else { throw ServerError.missingPort }
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

    func setHostNavigation(screen: String, page: String) {
        lock.lock()
        defer { lock.unlock() }
        self.screen = screen
        self.page = page
    }

    func setStale(_ stale: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.stale = stale
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard self.paused != paused else { return }
        if paused {
            pausedElapsed = Date().timeIntervalSince(startedAt)
        } else {
            startedAt = Date().addingTimeInterval(-pausedElapsed)
        }
        self.paused = paused
        workoutState = paused ? "paused" : "running"
        revision += 1
    }

    func endSharing() {
        lock.lock()
        sharingEnded = true
        lock.unlock()
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = buffered
            if let data { request.append(data) }
            if let headerEnd = request.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: request[..<headerEnd.lowerBound], encoding: .utf8) {
                let lines = headers.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count >= headerEnd.upperBound + length {
                    let body = Data(request[headerEnd.upperBound..<(headerEnd.upperBound + length)])
                    self.respond(to: lines.first ?? "", body: body, on: connection)
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, buffered: request) }
        }
    }

    private func respond(to requestLine: String, body: Data, on connection: NWConnection) {
        let key = requestLine.split(separator: " ").prefix(2).joined(separator: " ")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let result: (status: String, body: [String: Any])
        lock.lock()
        switch key {
        case "GET /api/share/123456":
            polls += 1
            if !stale || lastSnapshot == nil {
                sequence += 1
                lastSnapshot = snapshot()
                lastSnapshotTimestamp = now
            }
            if sharingEnded {
                result = ("404 Not Found", ["error": "Sharing session expired or ended.", "code": "SESSION_NOT_FOUND"])
            } else {
                result = ("200 OK", ["bpm": 132, "avg": 128, "min": 100, "max": 145,
                                     "timestamp": now, "serverTime": now,
                                     "workoutTimestamp": lastSnapshotTimestamp, "workout": lastSnapshot!])
            }
        case "POST /api/share/control":
            if let command = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let action = command["action"] as? String, allowedActions.contains(action),
               !stale, command["controlRevision"] as? String == "revision-\(revision)" {
                receivedCommands.append(command)
                revision += 1
                switch action {
                case "work", "rest": resting = action == "rest"
                case "pause":
                    pausedElapsed = Date().timeIntervalSince(startedAt)
                    paused = true
                    workoutState = workoutState == "cooldown" ? "cooldownPaused" : "paused"
                case "resume":
                    startedAt = Date().addingTimeInterval(-pausedElapsed)
                    paused = false
                    completed = false
                    workoutState = workoutState == "cooldownPaused" ? "cooldown" : "running"
                case "end":
                    if !paused { pausedElapsed = Date().timeIntervalSince(startedAt) }
                    paused = true
                    completed = true
                    workoutState = "idle"
                case "reset":
                    paused = true
                    completed = false
                    pausedElapsed = 0
                    resting = false
                    workoutState = "idle"
                case "start":
                    startedAt = Date()
                    paused = false
                    workoutState = "running"
                case "cool":
                    if paused { startedAt = Date().addingTimeInterval(-pausedElapsed) }
                    paused = false
                    workoutState = "cooldown"
                default: break
                }
                result = ("200 OK", ["queued": true])
            } else {
                result = ("409 Conflict", ["error": "Workout changed. Try again."])
            }
        default:
            result = ("404 Not Found", ["error": "Unknown test endpoint"])
        }
        lock.unlock()
        let data = (try? JSONSerialization.data(withJSONObject: result.body, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(result.status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Called while holding the state lock.
    private var allowedActions: [String] {
        switch workoutState {
        case "idle": return completed ? ["resume", "reset"] : ["start", "loadPreset"]
        case "paused": return ["resume", "end", "reset", "cool"]
        case "cooldownPaused": return ["resume", "end", "reset"]
        case "cooldown": return ["pause", "end", "reset"]
        default: return ["work", "pause", "end", "reset", "cool"] + (resting ? [] : ["rest"])
        }
    }

    /// Called while holding the state lock.
    private func snapshot() -> [String: Any] {
        let elapsed = paused ? pausedElapsed : Date().timeIntervalSince(startedAt)
        let empty = workoutState == "idle" && !completed
        let total = empty ? 0 : 75 + elapsed
        let set = empty ? 0 : 12 + elapsed
        let row: [String: Any] = ["id": "active-\(revision)", "label": resting ? "2R" : "\(revision + 1)",
                                  "kind": resting ? "rest" : "work", "isActive": true,
                                  "duration": set, "totalTime": total, "avgBPM": 130, "minBPM": 125, "maxBPM": 140]
        return [
            "schemaVersion": 1, "sequence": sequence, "workoutID": Self.workoutID,
            "controlRevision": "revision-\(revision)", "screen": screen, "page": page,
            "state": workoutState, "isCompleted": completed, "isPresetMode": false,
            "canWork": allowedActions.contains("work"), "canRest": allowedActions.contains("rest"), "totalTime": total,
            "setTime": set, "totalTimeAdvances": !paused, "setTimeDirection": paused ? 0 : 1,
            "showTenths": true, "isEmpty": empty, "avgWorkTime": 30,
            "allowedActions": allowedActions,
            "avgBPM": 128, "maxBPM": 145, "minBPM": 100, "zone": 2,
            "setNumber": resting ? "2R" : "\(revision + 1)", "calories": "42", "primaryBPM": "avg",
            "rows": empty ? [] : [row],
            "chart": empty ? [] : [
                ["time": 0, "bpm": 120, "segment": 0, "validUntil": 30],
                ["time": 30, "bpm": 140, "segment": 0, "validUntil": 60],
                ["time": 60, "bpm": 132, "segment": 0, "validUntil": total]
            ],
            "segments": empty ? [] : [["startTime": 0, "endTime": total, "kind": "work"]],
            "chartMaxTime": total, "zones": empty ? [] : [["zone": 1, "duration": 30], ["zone": 2, "duration": 45]]
        ]
    }

    private enum ServerError: Error {
        case startupTimeout
        case missingPort
    }
}
