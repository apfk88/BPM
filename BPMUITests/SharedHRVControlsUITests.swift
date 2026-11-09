import Network
import XCTest

final class SharedHRVControlsUITests: XCTestCase {
    @MainActor
    func testViewerStartsHostMeasurementMirrorsResultAndResetsWithoutSaving() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedHRVControlsServer()
        let app = launchViewer(baseURL: try server.start())
        defer { app.terminate(); server.stop() }

        openHRV(in: app)
        startViewerMeasurement(in: app, server: server)
        server.setRemainingTime(38)
        waitUntil("Viewer follows the host countdown", in: app) {
            (33...38).contains(self.countdownSeconds(in: app))
        }
        assertViewerHasNoSharedLabelOrSave(in: app)

        server.completeMeasurement()
        let result = app.staticTexts["hrvResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "64ms")
        XCTAssertTrue(app.buttons["resetHRVButton"].isEnabled)
        assertViewerHasNoSharedLabelOrSave(in: app)

        // Leaving a completed viewer screen must not clear the owner's result.
        app.buttons["xmark"].tap()
        XCTAssertTrue(app.buttons["HRV"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Clear Measurement"].exists)
        let polls = server.pollCount
        waitUntil("Completed host result survives viewer dismissal", in: app) { server.pollCount >= polls + 2 }
        XCTAssertEqual(server.commandActions, ["hrvStart"])
        openHRV(in: app)
        XCTAssertEqual(result.label, "64ms")

        app.buttons["resetHRVButton"].tap()
        waitUntil("Reset reaches host", in: app) { server.commandActions == ["hrvStart", "hrvReset"] }
        XCTAssertEqual(result.label, "64ms", "A viewer waits for the host to confirm reset")
        XCTAssertFalse(app.buttons["resetHRVButton"].isEnabled)
        server.confirmViewerCommand()
        waitUntil("Host reset returns viewer to ready", in: app) {
            app.buttons["measureHRVButton"].isEnabled && !result.exists
        }
        XCTAssertEqual(app.staticTexts["hrvCountdown"].label, "2:00")
        assertViewerHasNoSharedLabelOrSave(in: app)
    }

    @MainActor
    func testViewerStopConfirmsCancellationOnTheHost() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedHRVControlsServer()
        let app = launchViewer(baseURL: try server.start())
        defer { app.terminate(); server.stop() }

        openHRV(in: app)
        startViewerMeasurement(in: app, server: server)
        app.buttons["xmark"].tap()
        let stopAlert = app.alerts["Stop Measurement"]
        XCTAssertTrue(stopAlert.waitForExistence(timeout: 5))
        stopAlert.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["hrvCountdown"].exists)
        XCTAssertEqual(server.commandActions, ["hrvStart"])

        app.buttons["xmark"].tap()
        XCTAssertTrue(stopAlert.waitForExistence(timeout: 5))
        stopAlert.buttons["Stop"].tap()
        waitUntil("Stop reaches host", in: app) { server.commandActions == ["hrvStart", "hrvCancel"] }
        server.confirmViewerCommand()
        XCTAssertTrue(app.buttons["HRV"].waitForExistence(timeout: 5))
        openHRV(in: app)
        waitUntil("Cancelled measurement is ready again", in: app) { app.buttons["measureHRVButton"].isEnabled }
        XCTAssertEqual(app.staticTexts["hrvCountdown"].label, "2:00")
        XCTAssertFalse(app.staticTexts["hrvResult"].exists)
        assertViewerHasNoSharedLabelOrSave(in: app)
    }

    @MainActor
    func testRemoteStartOpensHostHRVFromHomeAndPublishesItsCountdown() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try SharedHRVControlsServer()
        let baseURL = try server.start()
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", "", "-BPM_API_BASE_URL", baseURL.absoluteString]
        app.launch()
        defer { app.terminate(); server.stop() }
        app.resetWorkoutAndReturnHome()

        app.buttons["deviceConnectionMenu"].tap()
        let monitor = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator HR Monitor")).firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        monitor.tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForNonExistence(timeout: 5))
        app.buttons["deviceConnectionMenu"].tap()
        XCTAssertTrue(app.navigationBars["Select Device"].waitForExistence(timeout: 5))
        app.buttons["startLiveHeartRateSharing"].tap()
        XCTAssertTrue(app.buttons["stopLiveHeartRateSharing"].waitForExistence(timeout: 5))
        app.navigationBars["Select Device"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["HRV"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["hrvCountdown"].exists)

        // The fixture sends only a command. The app's local monitor/model must
        // acquire beats, open HRV, and publish the resulting measuring state.
        server.requestHostStart()
        XCTAssertTrue(app.staticTexts["hrvCountdown"].waitForExistence(timeout: 12))
        waitUntil("Host publishes its active measurement", in: app) {
            server.hostHRVState == "measuring" && server.hostHRVIsPresented && server.hostStartWasAcknowledged
        }
        XCTAssertFalse(app.alerts["Starting Measurement"].exists)
        XCTAssertEqual(app.buttons["measureHRVButton"].label, "Measuring...")
        XCTAssertFalse(app.buttons["measureHRVButton"].isEnabled)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Shared HRV")).firstMatch.exists)
        let initialRemaining = countdownSeconds(in: app)
        XCTAssertGreaterThan(initialRemaining, 100)
        waitUntil("Host countdown advances locally", in: app) {
            let remaining = self.countdownSeconds(in: app)
            return remaining >= 0 && remaining < initialRemaining
        }
        XCTAssertEqual(server.hostStartDeliveryCount, 1)

        app.buttons["xmark"].tap()
        XCTAssertTrue(app.alerts["Stop Measurement"].waitForExistence(timeout: 5))
        app.alerts["Stop Measurement"].buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["HRV"].waitForExistence(timeout: 5))
        waitUntil("Local cancellation is published to viewers", in: app) {
            server.hostHRVState == "idle" && !server.hostHRVIsPresented
        }

        // Exercise the user's real simulator failure path for a full recording,
        // including the timer and Bluetooth simulator integration.
        app.buttons["HRV"].tap()
        let measure = app.buttons["measureHRVButton"]
        waitUntil("Simulator is ready for a fresh measurement", in: app) { measure.isEnabled }
        measure.tap()
        let startAlert = app.alerts["Starting Measurement"]
        if startAlert.waitForExistence(timeout: 2) { startAlert.buttons["OK"].tap() }
        XCTAssertTrue(app.staticTexts["hrvResult"].waitForExistence(timeout: 130),
                      "The simulated monitor must complete a full measurement with valid beat coverage")
        XCTAssertTrue(app.buttons["Save"].exists)
        waitUntil("The owner's completed result is published", in: app) {
            server.hostHRVState == "completed" && server.hostHRVValue != nil
        }
        let result = try XCTUnwrap(server.hostHRVValue)
        XCTAssertEqual(app.staticTexts["hrvResult"].label, "\(Int(result.rounded()))ms")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Completed simulator HRV shared by owner"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["resetHRVButton"].tap()
    }

    @MainActor
    private func launchViewer(baseURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BPM_FriendCode", "123456", "-BPM_API_BASE_URL", baseURL.absoluteString]
        app.launch()
        waitUntil("Viewer connects on Home", in: app) {
            app.buttons["HRV"].exists && app.buttons["deviceConnectionMenu"].value as? String == "Viewing shared BPM"
        }
        return app
    }

    @MainActor
    private func openHRV(in app: XCUIApplication) {
        app.buttons["HRV"].tap()
        XCTAssertTrue(app.buttons["xmark"].waitForExistence(timeout: 5))
        assertViewerHasNoSharedLabelOrSave(in: app)
    }

    @MainActor
    private func startViewerMeasurement(in app: XCUIApplication, server: SharedHRVControlsServer) {
        let measure = app.buttons["measureHRVButton"]
        waitUntil("Shared measurement is ready", in: app) { measure.isEnabled }
        measure.tap()
        let starting = app.alerts["Starting Measurement"]
        if starting.waitForExistence(timeout: 2) { starting.buttons["OK"].tap() }
        waitUntil("Start reaches host", in: app) { server.commandActions == ["hrvStart"] }
        XCTAssertFalse(measure.isEnabled)
        XCTAssertEqual(app.staticTexts["hrvReadinessMessage"].label, "Sending change…")
        XCTAssertEqual(app.staticTexts["hrvCountdown"].label, "2:00", "The viewer must not start a separate measurement")
        XCTAssertEqual(server.firstViewerCommand?["workoutID"] as? String, SharedHRVControlsServer.workoutID)
        XCTAssertEqual(server.firstViewerCommand?["controlRevision"] as? String, "revision-0")
        server.confirmViewerCommand()
        waitUntil("Host measurement appears on viewer", in: app) {
            measure.label == "Measuring..." && (85...90).contains(self.countdownSeconds(in: app))
        }
    }

    @MainActor
    private func countdownSeconds(in app: XCUIApplication) -> Int {
        let parts = app.staticTexts["hrvCountdown"].label.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else { return -1 }
        return minutes * 60 + seconds
    }

    @MainActor
    private func assertViewerHasNoSharedLabelOrSave(in app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Shared HRV")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Save"].exists)
        XCTAssertFalse(app.buttons["Saved"].exists)
    }

    @MainActor
    private func waitUntil(_ description: String, in app: XCUIApplication, condition: @escaping () -> Bool) {
        let pending = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: app)
        pending.expectationDescription = description
        waitForExpectations(timeout: 12)
    }
}

/// Synthetic bidirectional service. Viewer commands wait for explicit host
/// confirmation; host tests receive commands and publish their own HRV snapshots.
private final class SharedHRVControlsServer: @unchecked Sendable {
    static let workoutID = "5A812464-90C2-42FB-B3F5-AB4D3013191B"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BPMUITests.SharedHRVControlsServer")
    private let lock = NSLock()
    private var startupError: NWError?
    private var connections: [NWConnection] = []
    private var viewerCommands: [[String: Any]] = []
    private var pendingViewerAction: String?
    private var viewerState = "idle"
    private var remainingTime: Double = 120
    private var revision = 0
    private var hrvRevision = UUID().uuidString
    private var sequence = 0
    private var polls = 0
    private var hostStartRequested = false
    private var deliveredHostStartID: String?
    private var hostStartDeliveries = 0
    private var acknowledgedIDs: Set<String> = []
    private var publishedHostHRV: [String: Any] = [:]

    var commandActions: [String] { withLock { viewerCommands.compactMap { $0["action"] as? String } } }
    var firstViewerCommand: [String: Any]? { withLock { viewerCommands.first } }
    var pollCount: Int { withLock { polls } }
    var hostHRVState: String? { withLock { publishedHostHRV["state"] as? String } }
    var hostHRVValue: Double? { withLock { publishedHostHRV["hrvValue"] as? Double } }
    var hostHRVIsPresented: Bool { withLock { publishedHostHRV["isPresented"] as? Bool == true } }
    var hostStartDeliveryCount: Int { withLock { hostStartDeliveries } }
    var hostStartWasAcknowledged: Bool {
        withLock { deliveredHostStartID.map { acknowledgedIDs.contains($0) } ?? false }
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
            case .failed(let error): self?.withLock { self?.startupError = error }; ready.signal()
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
        if let error = withLock({ startupError }) { throw error }
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

    func confirmViewerCommand() {
        withLock {
            guard let action = pendingViewerAction else { return }
            pendingViewerAction = nil
            viewerState = action == "hrvStart" ? "measuring" : "idle"
            remainingTime = action == "hrvStart" ? 90 : 120
            revision += 1
            hrvRevision = UUID().uuidString
        }
    }

    func setRemainingTime(_ seconds: Double) { withLock { remainingTime = seconds } }

    func completeMeasurement() {
        withLock {
            viewerState = "completed"
            remainingTime = 0
            revision += 1
            hrvRevision = UUID().uuidString
        }
    }

    func requestHostStart() { withLock { hostStartRequested = true } }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
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
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let response = withLock { () -> (status: String, body: [String: Any]) in
            switch key {
            case "GET /api/share/123456":
                polls += 1
                sequence += 1
                return ("200 OK", ["bpm": 112, "timestamp": now, "serverTime": now,
                                    "workoutTimestamp": now, "workout": viewerSnapshot()])
            case "POST /api/share/control":
                guard let action = request["action"] as? String,
                      ["hrvStart", "hrvCancel", "hrvReset"].contains(action), pendingViewerAction == nil,
                      request["controlRevision"] as? String == "revision-\(revision)" else {
                    return ("409 Conflict", ["error": "Measurement changed"])
                }
                viewerCommands.append(request)
                pendingViewerAction = action
                return ("200 OK", ["queued": true])
            case "POST /api/share/workout":
                let snapshot = request["snapshot"] as? [String: Any] ?? [:]
                publishedHostHRV = snapshot["hrv"] as? [String: Any] ?? [:]
                acknowledgedIDs.formUnion(request["acknowledgedCommandIds"] as? [String] ?? [])
                var commands: [[String: Any]] = []
                if hostStartRequested, deliveredHostStartID == nil,
                   publishedHostHRV["state"] as? String == "idle",
                   publishedHostHRV["readinessReason"] as? String == "ready",
                   let workoutID = snapshot["workoutID"] as? String,
                   let controlRevision = snapshot["controlRevision"] as? String {
                    let commandID = UUID().uuidString
                    deliveredHostStartID = commandID
                    hostStartDeliveries += 1
                    commands = [["id": commandID, "workoutID": workoutID, "controlRevision": controlRevision,
                                 "action": "hrvStart", "createdAt": now]]
                }
                return ("200 OK", ["commands": commands, "serverTime": now])
            case "POST /api/share": return ("200 OK", ["code": "123456", "token": "hrv-ui-test-token"])
            case "POST /api/share/beat", "POST /api/share/rr", "DELETE /api/share": return ("200 OK", ["ok": true])
            default: return ("404 Not Found", ["error": "Unknown test endpoint"])
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])) ?? Data("{}".utf8)
        var bytes = Data("HTTP/1.1 \(response.status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(data)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Called with the state lock held.
    private func viewerSnapshot() -> [String: Any] {
        var hrv: [String: Any] = [
            "revision": hrvRevision, "isPresented": viewerState != "idle", "state": viewerState,
            "remainingTime": remainingTime, "currentBPM": 112, "readinessReason": "ready",
            "allowsRemoteControl": true
        ]
        if viewerState == "completed" {
            hrv["hrvValue"] = 64.4
            hrv["avgHeartRate"] = 112
            hrv["minHeartRate"] = 98
            hrv["maxHeartRate"] = 128
        }
        return [
            "schemaVersion": 1, "sequence": sequence, "workoutID": Self.workoutID,
            "controlRevision": "revision-\(revision)", "screen": "home", "page": "table", "state": "idle",
            "isCompleted": false, "isPresetMode": false, "canWork": false, "canRest": false,
            "totalTime": 0, "setTime": 0, "totalTimeAdvances": false, "setTimeDirection": 0,
            "showTenths": false, "isEmpty": true, "setNumber": "1", "calories": "0", "primaryBPM": "avg",
            "rows": [], "chart": [], "segments": [], "chartMaxTime": 0, "zones": [], "allowedActions": [], "hrv": hrv
        ]
    }

    private enum ServerError: Error { case startupTimeout, missingPort }
}
