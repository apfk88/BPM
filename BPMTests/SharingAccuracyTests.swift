import Foundation
import XCTest
@testable import BPM

final class SharingAccuracyTests: XCTestCase {
    @MainActor func testRepeatedStoredPacketCannotExtendFreshness() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        let response = packet(140, at: clock.date)
        service.receiveFriendHeartRate(response, for: try poll(service))
        XCTAssertEqual(service.friendHeartRate, 140)
        clock.seconds = 9
        service.receiveFriendHeartRate(response, for: try poll(service))
        XCTAssertEqual(service.friendHeartRate, 140)
        clock.seconds = 10
        service.receiveFriendHeartRate(response, for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.friendAvgHeartRate)
        XCTAssertNotNil(service.errorMessage)
    }

    @MainActor func testAlreadyAgedPacketOnlyGetsRemainingFreshness() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(packet(140, at: clock.date.addingTimeInterval(-8)), for: try poll(service))
        XCTAssertEqual(service.friendHeartRate, 140)
        clock.seconds = 2
        // A wall-clock correction cannot prolong an accepted reading.
        clock.wallClockOffset = -3600
        service.refreshFriendHeartRateFreshness()
        XCTAssertNil(service.friendHeartRate)
    }

    @MainActor func testStaleFutureAndZeroReadingsAreNeverPresented() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        for response in [packet(140, at: clock.date.addingTimeInterval(-10)),
                         packet(140, at: clock.date.addingTimeInterval(60)),
                         packet(0, at: clock.date)] {
            service.receiveFriendHeartRate(response, for: try poll(service))
            XCTAssertNil(service.friendHeartRate)
            XCTAssertNotNil(service.errorMessage)
        }
    }

    @MainActor func testNewReadingsRenewFreshnessAndRecoverAfterError() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(packet(140, at: clock.date), for: try poll(service))
        service.receiveFriendHeartRateError("Network failed", for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        clock.seconds = 1
        service.receiveFriendHeartRate(packet(150, at: clock.date), for: try poll(service))
        XCTAssertEqual(service.friendHeartRate, 150)
        XCTAssertNil(service.errorMessage)
        clock.seconds = 10.9
        service.refreshFriendHeartRateFreshness()
        XCTAssertEqual(service.friendHeartRate, 150)
        clock.seconds = 11
        service.refreshFriendHeartRateFreshness()
        XCTAssertNil(service.friendHeartRate)
    }

    @MainActor func testOutOfOrderResponsesAndErrorsCannotReplaceNewerData() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        let olderPoll = try poll(service)
        let newerPoll = try poll(service)
        service.receiveFriendHeartRate(packet(150, at: clock.date), for: newerPoll)
        service.receiveFriendHeartRate(packet(120, at: clock.date), for: olderPoll)
        service.receiveFriendHeartRateError("Old request failed", for: olderPoll)
        XCTAssertEqual(service.friendHeartRate, 150)
        XCTAssertNil(service.errorMessage)
        // A newer HTTP request carrying older server data is also ignored.
        service.receiveFriendHeartRate(packet(130, at: clock.date.addingTimeInterval(-1)), for: try poll(service))
        XCTAssertEqual(service.friendHeartRate, 150)
    }

    @MainActor func testChangingOrStoppingSessionInvalidatesPendingCallbacks() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        let previousPoll = try poll(service)
        service.receiveFriendHeartRate(packet(140, at: clock.date), for: previousPoll)
        let pendingPoll = try poll(service)
        service.startViewing(code: "654321")
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.friendMaxHeartRate)
        service.receiveFriendHeartRate(packet(180, at: clock.date), for: pendingPoll)
        service.receiveFriendHeartRateError("Previous session expired", for: pendingPoll)
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.errorMessage)
        let currentPoll = try poll(service)
        service.stopViewing()
        service.receiveFriendHeartRate(packet(180, at: clock.date), for: currentPoll)
        XCTAssertNil(service.friendHeartRate)
        XCTAssertFalse(service.isViewing)
    }

    @MainActor func testDisconnectAndSessionExpiryClearLastKnownValues() throws {
        let clock = SharingTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(packet(140, at: clock.date), for: try poll(service))
        clock.seconds = 1
        service.receiveFriendHeartRate(packet(nil, at: clock.date), for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.friendMinHeartRate)
        clock.seconds = 2
        service.receiveFriendHeartRate(packet(140, at: clock.date), for: try poll(service))
        service.receiveFriendHeartRateError("Sharing session expired", for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        XCTAssertNil(service.friendMaxHeartRate)
        XCTAssertEqual(service.errorMessage, "Sharing session expired")
    }

    @MainActor private func makeService(_ clock: SharingTestClock) -> SharingService {
        SharingService(
            userDefaults: UserDefaults(suiteName: "sharing-accuracy-\(UUID())")!,
            nowProvider: { clock.date }, ticksProvider: { clock.seconds },
            automaticallyPoll: false, managesLiveActivities: false
        )
    }

    private func poll(_ service: SharingService) throws -> FriendHeartRatePoll {
        try XCTUnwrap(service.beginFriendHeartRatePoll())
    }

    private func packet(_ bpm: Int?, at date: Date) -> HeartRateResponse {
        HeartRateResponse(bpm: bpm, max: 170, avg: 130, min: 80,
                          timestamp: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

private final class SharingTestClock {
    var seconds: TimeInterval = 0
    var wallClockOffset: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds + wallClockOffset) }
}
