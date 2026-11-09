import Network
import UIKit
import XCTest

final class SharedWorkoutControlsUITests: XCTestCase {
    @MainActor
    func testPresetClearRowsAndControlSizesMatchInPortrait() throws {
        try assertPresetControls(orientation: .portrait)
    }

    @MainActor
    func testPresetClearRowsAndControlSizesMatchInLandscape() throws {
        try assertPresetControls(orientation: .landscapeLeft)
    }

    @MainActor
    func testViewerUsesWholeSecondsForSetRowsAndCompletedAverage() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedWorkoutControlsServer(scenario: .paused)
        let app = launchViewer(baseURL: try server.start())
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            server.stop()
        }

        for scenario in [SharedWorkoutControlsServer.Scenario.paused, .completed] {
            server.setScenario(scenario)
            let status = scenario == .completed ? "Workout ended" : "Paused"
            waitUntil("Snapshot reaches \(status)", in: app) {
                app.staticTexts["sharedWorkoutStatus"].label == status
            }
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                rotate(to: orientation, in: app)
                XCTAssertEqual(app.staticTexts["sharedWorkoutTotalTime"].label, "1:15")
                XCTAssertEqual(app.staticTexts["sharedWorkoutSetTime"].label,
                               scenario == .completed ? "0:30" : "0:12")
                let row = app.descendants(matching: .any)
                    .matching(identifier: "sharedWorkoutRow_fractional").firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                XCTAssertTrue(row.label.contains("0:12"), row.label)
                XCTAssertTrue(row.label.contains("1:15"), row.label)
                XCTAssertNil(row.label.range(of: #"\d+:\d{2}\.\d"#, options: .regularExpression),
                             "A broadcaster's showTenths preference must not add decimals to viewer rows")
            }
        }
        XCTAssertTrue(server.commands.isEmpty)
    }

    @MainActor
    private func assertPresetControls(orientation: UIDeviceOrientation) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", "", "-timerPresetsSeeded", "NO"]
        app.launch()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        app.resetWorkoutAndReturnHome()
        XCTAssertTrue(app.buttons["Workout"].waitForExistence(timeout: 5))
        app.buttons["Workout"].tap()
        rotate(to: orientation, in: app)
        let hostClear = app.buttons["workoutClearPreset"]
        if hostClear.exists && hostClear.isEnabled { hostClear.tap() }

        let titles = ["Start", "Load Preset", "Work Set", "Rest Set"]
        var hostSizes: [String: CGSize] = [:]
        for title in titles {
            let button = app.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            hostSizes[title] = button.frame.size
        }
        app.buttons["Load Preset"].tap()
        let preset = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "HIIT 20/10 x8")).firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        XCTAssertTrue(app.navigationBars["Presets"].waitForNonExistence(timeout: 5))
        assertPresetRow(in: app, rowID: "workoutPresetName", clearID: "workoutClearPreset",
                        firstButton: "Start", lastButton: "Load Preset")
        hostClear.tap()
        XCTAssertTrue(hostClear.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "workoutPresetName").firstMatch.exists)
        XCTAssertTrue(app.buttons["Work Set"].exists)
        XCTAssertTrue(app.buttons["Rest Set"].exists)
        XCTAssertFalse(app.navigationBars["Presets"].exists)
        app.resetWorkoutAndReturnHome()
        app.terminate()

        let server = try SharedWorkoutControlsServer(scenario: .idlePreset)
        let viewer = launchViewer(baseURL: try server.start(), hasActiveWorkout: false)
        defer { viewer.terminate(); server.stop() }
        rotate(to: orientation, in: viewer)
        assertPresetRow(in: viewer, rowID: "sharedWorkoutPresetName", clearID: "sharedWorkoutClearPreset",
                        firstButton: "sharedWorkoutStart", lastButton: "sharedWorkoutLoadPreset")

        // Preset changes remain unavailable once the host is mid-workout.
        server.setScenario(.pausedPreset)
        waitUntil("Active preset arrives", in: viewer) {
            viewer.buttons["sharedWorkoutResume"].exists
        }
        XCTAssertTrue(viewer.buttons["sharedWorkoutClearPreset"].exists)
        XCTAssertFalse(viewer.buttons["sharedWorkoutClearPreset"].isEnabled)
        XCTAssertTrue(server.commands.isEmpty)
        server.setScenario(.idlePreset)
        waitUntil("Idle preset can be cleared", in: viewer) {
            viewer.buttons["sharedWorkoutStart"].exists && viewer.buttons["sharedWorkoutClearPreset"].isEnabled
        }
        viewer.buttons["sharedWorkoutClearPreset"].tap()
        waitUntil("Host confirms clear preset", in: viewer) {
            !viewer.buttons["sharedWorkoutClearPreset"].exists && viewer.buttons["sharedWorkSet"].exists
        }
        let command = try XCTUnwrap(server.commands.first)
        XCTAssertEqual(server.commands.count, 1)
        XCTAssertEqual(command["action"] as? String, "clearPreset")
        XCTAssertEqual(command["code"] as? String, "123456")
        XCTAssertEqual(command["workoutID"] as? String, SharedWorkoutControlsServer.workoutID)
        XCTAssertEqual(command["controlRevision"] as? String, "revision-2")
        XCTAssertFalse(viewer.navigationBars["Presets"].exists)
        XCTAssertFalse(viewer.descendants(matching: .any).matching(identifier: "sharedWorkoutPresetName").firstMatch.exists)

        let identifiers = ["Start": "sharedWorkoutStart", "Load Preset": "sharedWorkoutLoadPreset",
                           "Work Set": "sharedWorkSet", "Rest Set": "sharedRestSet"]
        for title in titles {
            let button = viewer.buttons[try XCTUnwrap(identifiers[title])]
            let hostSize = try XCTUnwrap(hostSizes[title])
            XCTAssertTrue(button.exists)
            XCTAssertEqual(button.frame.width, hostSize.width, accuracy: 2, "\(title) width differs between host and viewer")
            XCTAssertEqual(button.frame.height, hostSize.height, accuracy: 2, "\(title) height differs between host and viewer")
        }
    }

    @MainActor
    private func assertPresetRow(in app: XCUIApplication, rowID: String, clearID: String,
                                 firstButton: String, lastButton: String) {
        let row = app.descendants(matching: .any).matching(identifier: rowID).firstMatch
        let clear = app.buttons[clearID]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.isEnabled)
        XCTAssertTrue(clear.isHittable)
        let leading = min(app.buttons[firstButton].frame.minX, app.buttons[lastButton].frame.minX)
        let trailing = max(app.buttons[firstButton].frame.maxX, app.buttons[lastButton].frame.maxX)
        XCTAssertEqual(row.frame.minX, leading, accuracy: 2, "Preset row must span the controls")
        XCTAssertEqual(row.frame.maxX, trailing, accuracy: 2, "Preset row must span the controls")
        XCTAssertGreaterThan(clear.frame.midX, row.frame.midX, "Clear belongs at the trailing end of the preset row")
        XCTAssertGreaterThanOrEqual(clear.frame.minY, row.frame.minY - 1)
        XCTAssertLessThanOrEqual(clear.frame.maxY, row.frame.maxY + 1)
        XCTAssertLessThanOrEqual(clear.frame.maxX, row.frame.maxX + 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(rowID) \(app.frame.width > app.frame.height ? "landscape" : "portrait")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchViewer(baseURL: URL, hasActiveWorkout: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", "123456", "-BPM_API_BASE_URL", baseURL.absoluteString]
        app.launch()
        if !hasActiveWorkout {
            let workout = app.buttons["Workout"]
            XCTAssertTrue(workout.waitForExistence(timeout: 10), "An unstarted shared preset still opens Home")
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: workout)
            waitForExpectations(timeout: 10)
            XCTAssertFalse(app.buttons["sharedWorkoutHome"].exists)
            workout.tap()
        }
        XCTAssertTrue(app.buttons["sharedWorkoutHome"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func rotate(to orientation: UIDeviceOrientation, in app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        waitUntil("Workout rotates", in: app) {
            orientation.isLandscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }
    }

    @MainActor
    private func waitUntil(_ description: String, in app: XCUIApplication, condition: @escaping () -> Bool) {
        let conditionExpectation = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: app)
        conditionExpectation.expectationDescription = description
        waitForExpectations(timeout: 10)
    }
}

/// Isolated synthetic owner. Fractional snapshots deliberately advertise showTenths.
private final class SharedWorkoutControlsServer: @unchecked Sendable {
    enum Scenario { case idlePreset, idle, pausedPreset, paused, completed }
    static let workoutID = "429D60A7-70C9-402E-B516-0306B1E05204"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BPMUITests.SharedWorkoutControlsServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var startupError: NWError?
    private var scenario: Scenario
    private var revision = 0
    private var sequence = 0
    private var receivedCommands: [[String: Any]] = []

    var commands: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return receivedCommands
    }

    init(scenario: Scenario) throws {
        self.scenario = scenario
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
            guard let self else { connection.cancel(); return }
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
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func setScenario(_ scenario: Scenario) {
        lock.lock()
        defer { lock.unlock() }
        self.scenario = scenario
        revision += 1
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
            sequence += 1
            result = ("200 OK", ["bpm": 132, "avg": 128, "min": 100, "max": 145,
                                 "timestamp": now, "serverTime": now, "workoutTimestamp": now,
                                 "workout": snapshot()])
        case "POST /api/share/control":
            if let command = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               command["action"] as? String == "clearPreset", scenario == .idlePreset,
               command["controlRevision"] as? String == "revision-\(revision)" {
                receivedCommands.append(command)
                revision += 1
                scenario = .idle
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
    private func snapshot() -> [String: Any] {
        let preset = scenario == .idlePreset || scenario == .pausedPreset
        let empty = scenario == .idlePreset || scenario == .idle
        let completed = scenario == .completed
        let actions = empty ? (["start", "loadPreset"] + (preset ? ["clearPreset"] : []))
            : completed ? ["resume", "reset"] : ["resume", "end", "reset"]
        var snapshot: [String: Any] = [
            "schemaVersion": 1, "sequence": sequence, "workoutID": Self.workoutID,
            "controlRevision": "revision-\(revision)", "screen": "workout", "page": "table",
            "state": empty || completed ? "idle" : "paused", "isCompleted": completed, "isPresetMode": preset,
            "canWork": false, "canRest": false, "totalTime": empty ? 0 : 75.8, "setTime": empty ? 0 : 12.6,
            "totalTimeAdvances": false, "setTimeDirection": 0, "showTenths": true, "isEmpty": empty,
            "avgWorkTime": 30.7, "allowedActions": actions,
            "avgBPM": 128, "maxBPM": 145, "minBPM": 100, "zone": 2,
            "setNumber": "1", "calories": "42", "primaryBPM": "avg",
            "rows": empty ? [] : [["id": "fractional", "label": "1", "kind": "work", "isActive": false,
                                    "duration": 12.6, "totalTime": 75.8, "avgBPM": 130, "minBPM": 125, "maxBPM": 140]],
            "chart": [], "segments": [], "chartMaxTime": 75.8, "zones": []
        ]
        if preset {
            snapshot["activePreset"] = ["id": "CF6F2782-65A0-4EC6-95C6-A4A46C50CED7", "name": "HIIT 20/10 x8",
                                         "workDuration": 20, "restDuration": 10, "numberOfSets": 8,
                                         "includeCooldown": false, "playSound": false]
        }
        return snapshot
    }

    private enum ServerError: Error { case startupTimeout, missingPort }
}
