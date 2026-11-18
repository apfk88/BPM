import XCTest
@testable import BPM

final class SharingSessionLifecycleTests: XCTestCase {
    @MainActor
    func testOwnCodeAndBroadcastingRejectJoinWithoutDisconnectingMonitor() {
        var disconnects = 0
        let service = makeService { disconnects += 1 }
        service.isSharing = true
        service.shareCode = "123456"
        service.shareToken = "owner-token"
        XCTAssertFalse(service.startViewing(code: "123 456"))
        XCTAssertEqual(service.errorMessage, "You can’t join your own session.")
        XCTAssertFalse(service.startViewing(code: "654321"))
        XCTAssertTrue(service.isSharing)
        XCTAssertFalse(service.isViewing)
        XCTAssertEqual(service.shareToken, "owner-token")
        XCTAssertEqual(disconnects, 0)
    }

    @MainActor
    func testJoiningDisconnectsMonitorBeforePublishingViewerStateAndCannotBroadcast() async {
        var disconnects = 0
        let service = makeService { disconnects += 1 }
        XCTAssertTrue(service.startViewing(code: "123456", disconnectMonitor: {
            XCTAssertFalse(service.isViewing)
            disconnects += 1
        }))
        XCTAssertEqual(disconnects, 1)
        XCTAssertTrue(service.isViewing)
        XCTAssertTrue(service.startViewing(code: "123456"))
        XCTAssertEqual(disconnects, 1, "Reopening the same session must not restart it")
        do {
            try await service.startSharing()
            XCTFail("A viewer cannot also broadcast")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(service.isViewing)
        XCTAssertFalse(service.isSharing)
    }

    @MainActor
    func testStoppedSharingResetsViewerAndNotifiesOnlyAfterAConfirmedConnection() throws {
        let service = makeService()
        service.startViewing(code: "123456")
        service.receiveFriendHeartRateError("Invalid code", for: try XCTUnwrap(service.beginFriendHeartRatePoll()), sessionEnded: true)
        XCTAssertTrue(service.isViewing)
        XCTAssertNil(service.viewingStoppedMessage)
        XCTAssertEqual(service.errorMessage, "Invalid code")

        service.receiveFriendHeartRate(HeartRateResponse(bpm: 120, max: 140, avg: 115, min: 80,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)), for: try XCTUnwrap(service.beginFriendHeartRatePoll()))
        let delayed = try XCTUnwrap(service.beginFriendHeartRatePoll())
        service.receiveFriendHeartRateError("Ended", for: try XCTUnwrap(service.beginFriendHeartRatePoll()), sessionEnded: true)
        XCTAssertFalse(service.isViewing)
        XCTAssertNil(service.friendCode)
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.friendWorkout)
        XCTAssertTrue(service.friendRRIntervals.isEmpty)
        XCTAssertEqual(service.viewingStoppedMessage, "Your friend stopped sharing.")
        service.receiveFriendHeartRateError("Late network error", for: delayed)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testTemporaryNetworkFailureKeepsSessionForRecovery() throws {
        let service = makeService()
        service.startViewing(code: "123456")
        service.receiveFriendHeartRateError("Offline", for: try XCTUnwrap(service.beginFriendHeartRatePoll()))
        XCTAssertTrue(service.isViewing)
        XCTAssertNil(service.viewingStoppedMessage)
    }

    func testJoinLinksAcceptOnlyExpectedSchemeDomainAndSixDigitCode() {
        XCTAssertEqual(SharingService.friendCode(from: URL(string: "bpm://join?code=123456")!), "123456")
        XCTAssertEqual(SharingService.friendCode(from: URL(string: "https://bpmtracker.app/join/654321")!), "654321")
        for url in ["https://example.com/join/123456", "http://bpmtracker.app/join/123456", "bpm://other?code=123456", "bpm://join?code=1234567", "bpm://join?code=１２３４５６", "https://bpmtracker.app/join/123456/extra"] {
            XCTAssertNil(SharingService.friendCode(from: URL(string: url)!))
        }
    }

    @MainActor
    func testNoViewerTimeoutStopsSharingAndPublishesAlert() async throws {
        let clock = SharingLifecycleClock()
        let session = makeNetworkSession()
        let message = "Sharing stopped automatically because no one connected within 5 minutes. Start a new session to keep sharing."
        LifecycleURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, self.startResponse()) }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/share", "Checking our own session must not count as a viewer")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner")
            return (404, try JSONSerialization.data(withJSONObject: ["code": "SESSION_NO_VIEWER", "message": message]))
        }
        let service = makeNetworkService(clock: clock, session: session)
        try await service.startSharing()
        clock.seconds = 300
        await service.refreshSharingSession()
        XCTAssertFalse(service.isSharing)
        XCTAssertNil(service.shareCode)
        XCTAssertNil(service.shareToken)
        XCTAssertEqual(service.sharingStoppedMessage, message)
        XCTAssertEqual(service.errorMessage, message)
    }

    @MainActor
    func testViewerConnectionKeepsSessionUntilNinetyMinuteAutomaticAlert() async throws {
        let clock = SharingLifecycleClock()
        let session = makeNetworkSession()
        LifecycleURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, self.startResponse()) }
            if clock.seconds < 5400 {
                return (200, Data(#"{"serverTime":300000,"expiresAt":5400000,"viewerDeadline":300000,"hasConnectedViewer":true}"#.utf8))
            }
            return (404, try JSONSerialization.data(withJSONObject: ["code": "SESSION_EXPIRED", "message": SharingService.sharingExpiredMessage]))
        }
        let service = makeNetworkService(clock: clock, session: session)
        try await service.startSharing()
        XCTAssertFalse(service.hasConnectedViewer)
        clock.seconds = 300
        await service.refreshSharingSession()
        XCTAssertTrue(service.isSharing)
        XCTAssertTrue(service.hasConnectedViewer)
        XCTAssertNil(service.sharingStoppedMessage)
        clock.seconds = 5400
        await service.refreshSharingSession()
        XCTAssertFalse(service.isSharing)
        XCTAssertFalse(service.hasConnectedViewer)
        XCTAssertEqual(service.sharingStoppedMessage, SharingService.sharingExpiredMessage)
    }

    @MainActor
    func testOfflineStatusDoesNotInventNoViewerTimeoutAndStillEnforcesOverallLimit() async throws {
        let clock = SharingLifecycleClock()
        let session = makeNetworkSession()
        LifecycleURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, self.startResponse()) }
            throw URLError(.notConnectedToInternet)
        }
        let service = makeNetworkService(clock: clock, session: session)
        try await service.startSharing()
        clock.seconds = 300
        await service.refreshSharingSession()
        XCTAssertTrue(service.isSharing)
        XCTAssertNil(service.sharingStoppedMessage)
        clock.seconds = 5400
        await service.refreshSharingSession()
        XCTAssertFalse(service.isSharing)
        XCTAssertEqual(service.sharingStoppedMessage, SharingService.sharingExpiredMessage)
    }

    @MainActor
    func testLegacyServerNinetyMinuteTimerAlsoAlertsAndManualStopDoesNot() async throws {
        let clock = SharingLifecycleClock()
        let session = makeNetworkSession(expectedDeletes: 2)
        LifecycleURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Data(#"{"code":"123456","token":"owner"}"#.utf8))
        }
        let service = makeNetworkService(clock: clock, session: session)
        try await service.startSharing()
        clock.seconds = 5399
        await service.refreshSharingSession()
        XCTAssertTrue(service.isSharing)
        clock.seconds = 5400
        await service.refreshSharingSession()
        XCTAssertEqual(service.sharingStoppedMessage, SharingService.sharingExpiredMessage)
        try await service.startSharing()
        XCTAssertNil(service.sharingStoppedMessage)
        service.stopSharing()
        await service.refreshSharingSession()
        XCTAssertNil(service.sharingStoppedMessage)
    }

    @MainActor
    func testLateExpirationResponseCannotStopNewSharingSession() async throws {
        let clock = SharingLifecycleClock()
        let session = makeNetworkSession()
        let requested = expectation(description: "Old status requested")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        LifecycleURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, self.startResponse()) }
            requested.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return (404, Data(#"{"code":"SESSION_NO_VIEWER","message":"Expired old session"}"#.utf8))
        }
        let service = makeNetworkService(clock: clock, session: session)
        try await service.startSharing()
        let oldRefresh = Task { await service.refreshSharingSession() }
        await fulfillment(of: [requested], timeout: 2)
        service.stopSharing()
        // Establish the replacement while the old network request is held.
        service.isSharing = true
        service.shareCode = "654321"
        service.shareToken = "replacement"
        release.signal()
        await oldRefresh.value
        XCTAssertTrue(service.isSharing)
        XCTAssertEqual(service.shareCode, "654321")
        XCTAssertNil(service.sharingStoppedMessage)
    }

    private func startResponse() -> Data {
        Data(#"{"code":"123456","token":"owner","serverTime":0,"expiresAt":5400000,"viewerDeadline":300000,"hasConnectedViewer":false}"#.utf8)
    }

    private func makeNetworkSession(expectedDeletes: Int = 1) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleURLProtocol.self]
        let session = URLSession(configuration: config)
        let deleted = XCTestExpectation(description: "Stopped sharing deletes the owner session")
        deleted.expectedFulfillmentCount = expectedDeletes
        LifecycleURLProtocol.didDelete = { deleted.fulfill() }
        addTeardownBlock {
            // stopSharing deliberately sends DELETE asynchronously. Let those
            // requests start before invalidating their injected URLSession.
            await self.fulfillment(of: [deleted], timeout: 3)
            session.invalidateAndCancel()
            LifecycleURLProtocol.handler = nil
            LifecycleURLProtocol.didDelete = nil
        }
        return session
    }

    private func makeNetworkService(clock: SharingLifecycleClock, session: URLSession) -> SharingService {
        let defaults = UserDefaults(suiteName: "sharing-timeout-\(UUID())")!
        defaults.set("https://example.test", forKey: "BPM_API_BASE_URL")
        return SharingService(userDefaults: defaults, ticksProvider: { clock.seconds },
            automaticallyPoll: false, managesLiveActivities: false, networkSession: session)
    }

    private func makeService(disconnect: @escaping () -> Void = {}) -> SharingService {
        SharingService(userDefaults: UserDefaults(suiteName: "sharing-lifecycle-\(UUID())")!,
            automaticallyPoll: false, managesLiveActivities: false, disconnectLocalMonitor: disconnect)
    }
}

private final class SharingLifecycleClock {
    var seconds: TimeInterval = 0
}

private final class LifecycleURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var didDelete: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result: (Int, Data)
            if request.httpMethod == "DELETE" {
                result = (200, Data(#"{"success":true}"#.utf8))
                Self.didDelete?()
            } else if let handler = Self.handler {
                result = try handler(request)
            } else {
                throw URLError(.cancelled)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
