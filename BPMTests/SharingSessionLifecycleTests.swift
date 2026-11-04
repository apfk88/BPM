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

    private func makeService(disconnect: @escaping () -> Void = {}) -> SharingService {
        SharingService(userDefaults: UserDefaults(suiteName: "sharing-lifecycle-\(UUID())")!,
            automaticallyPoll: false, managesLiveActivities: false, disconnectLocalMonitor: disconnect)
    }
}
