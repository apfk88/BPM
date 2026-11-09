import Foundation
import XCTest
@testable import BPM

final class SharedWorkoutSyncTests: XCTestCase {
    @MainActor
    func testWorkoutArrivesWithoutFreshHeartRateAndExpiresOnMonotonicClock() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot(), heartRateAge: 60), for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        XCTAssertTrue(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkout?.workoutID, "workout")

        clock.seconds = 4
        clock.wallClockOffset = 3_600
        service.receiveFriendHeartRate(response(snapshot(), heartRateAge: 60), for: try poll(service))
        XCTAssertEqual(service.friendWorkoutPresentationAge, 4)
        clock.seconds = 5
        service.refreshFriendWorkoutFreshness()
        XCTAssertFalse(service.friendWorkoutIsFresh)
        clock.seconds = 20
        XCTAssertEqual(service.friendWorkoutPresentationAge, 5)
    }

    @MainActor
    func testStoredWorkoutAgeLimitsFreshnessAndFutureTimestampIsRejected() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot(), workoutAge: 4), for: try poll(service))
        XCTAssertTrue(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkoutPresentationAge, 4)
        clock.seconds = 1
        service.refreshFriendWorkoutFreshness()
        XCTAssertFalse(service.friendWorkoutIsFresh)

        service.receiveFriendHeartRate(response(snapshot(sequence: 2), workoutAge: -1), for: try poll(service))
        XCTAssertEqual(service.friendWorkout?.sequence, 1)
        XCTAssertFalse(service.friendWorkoutIsFresh)
        service.receiveFriendHeartRate(response(snapshot(sequence: 3), workoutAge: 6), for: try poll(service))
        XCTAssertEqual(service.friendWorkout?.sequence, 3)
        XCTAssertFalse(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkoutPresentationAge, 5)
    }

    @MainActor
    func testOutOfOrderSnapshotsAndPollsCannotReplaceNewerWorkout() throws {
        let service = makeService(SharedWorkoutTestClock())
        service.startViewing(code: "123456")
        let olderPoll = try poll(service)
        let newerPoll = try poll(service)
        service.receiveFriendHeartRate(response(snapshot(sequence: 2, revision: "new")), for: newerPoll)
        service.receiveFriendHeartRate(response(snapshot(sequence: 3, revision: "late-poll")), for: olderPoll)
        service.receiveFriendHeartRate(response(snapshot(sequence: 1, revision: "old")), for: try poll(service))
        XCTAssertEqual(service.friendWorkout?.controlRevision, "new")
        XCTAssertEqual(service.friendWorkout?.sequence, 2)
    }

    @MainActor
    func testNetworkTransitTimeCannotRenewExpiredSnapshotsOrCommands() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        let delayedPoll = try poll(service)
        clock.seconds = 6
        service.receiveFriendHeartRate(response(snapshot()), for: delayedPoll)
        XCTAssertFalse(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkoutPresentationAge, 5)

        service.isSharing = true
        service.shareToken = "host"
        service.processWorkoutCommands([command("delayed")], serverTime: 10_000, transportAge: 6,
                                       token: "host", snapshotProvider: { self.snapshot() }) { _ in
            XCTFail("A command delayed beyond five seconds must be rejected")
            return true
        }
    }

    @MainActor
    func testNetworkFailureFreezesTimerUntilNewSnapshotAndSessionChangesClearIt() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        clock.seconds = 2
        service.receiveFriendHeartRateError("Offline", for: try poll(service))
        clock.seconds = 4
        XCTAssertFalse(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkoutPresentationAge, 2)
        service.receiveFriendHeartRate(response(snapshot(sequence: 2)), for: try poll(service))
        XCTAssertTrue(service.friendWorkoutIsFresh)
        XCTAssertEqual(service.friendWorkoutPresentationAge, 0)

        let previousSessionPoll = try poll(service)
        service.startViewing(code: "654321")
        XCTAssertNil(service.friendWorkout)
        service.receiveFriendHeartRate(response(snapshot(sequence: 3)), for: previousSessionPoll)
        XCTAssertNil(service.friendWorkout)
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        service.receiveFriendHeartRateError("Ended", for: try poll(service), sessionEnded: true)
        XCTAssertNil(service.friendWorkout)
        XCTAssertFalse(service.friendWorkoutIsFresh)
        XCTAssertFalse(service.isViewing)
        XCTAssertNil(service.beginFriendHeartRatePoll())
        XCTAssertEqual(service.viewingStoppedMessage, "Your friend stopped sharing.")
        XCTAssertTrue(service.startViewing(code: "234567"))
        service.receiveFriendHeartRate(response(snapshot(sequence: 2)), for: try poll(service))
        service.stopViewing()
        XCTAssertNil(service.friendWorkout)
    }

    @MainActor
    func testHostRejectsExpiredWrongWorkoutWrongRevisionAndDisallowedCommandsAndDeduplicates() {
        let service = makeService(SharedWorkoutTestClock())
        service.isSharing = true
        service.shareToken = "host"
        var current = snapshot()
        var applied = [String]()
        let now: Int64 = 10_000
        let commands = [
            command("expired", createdAt: 4_999),
            command("expiry-boundary", createdAt: 5_000),
            command("future", createdAt: 10_001),
            command("wrong-workout", workoutID: "other"),
            command("wrong-revision", revision: "other"),
            command("disabled-rest", action: .rest),
            command("accepted")
        ]
        service.processWorkoutCommands(commands, serverTime: now, token: "host", snapshotProvider: { current }) {
            applied.append($0.id)
            current.controlRevision = "changed"
            return true
        }
        XCTAssertEqual(applied, ["accepted"])
        current.controlRevision = "revision"
        service.processWorkoutCommands([command("accepted")], serverTime: now, token: "host", snapshotProvider: { current }) {
            applied.append($0.id)
            return true
        }
        XCTAssertEqual(applied, ["accepted"])
        current.state = .paused
        service.processWorkoutCommands([command("paused")], serverTime: now, token: "host", snapshotProvider: { current }) {
            applied.append($0.id)
            return true
        }
        XCTAssertEqual(applied, ["accepted"])
        service.shareToken = "replacement"
        XCTAssertFalse(service.processWorkoutCommands([command("old-session")], serverTime: now, token: "host", snapshotProvider: { current }) { _ in
            XCTFail("Previous session cannot control a new one")
            return true
        })
    }

    @MainActor
    func testHostAcknowledgesAcceptedAndRejectedCommandsAndImmediatelyPublishesNewRevision() async throws {
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(SharedWorkoutTestClock(), session: session)
        service.isSharing = true
        service.shareToken = "host"
        var current = snapshot()
        var requests = [[String: Any]]()
        let commands = [command("accepted"), command("expired", createdAt: 1)]
        let firstResponse = try JSONSerialization.data(withJSONObject: [
            "commands": try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands)),
            "serverTime": 10_000
        ])
        WorkoutSyncURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            requests.append(body)
            XCTAssertEqual(request.url?.path, "/api/share/workout")
            return (200, requests.count == 1 ? firstResponse : Data(#"{"commands":[],"serverTime":10001}"#.utf8))
        }
        await service.syncWorkout(snapshotProvider: { current }) { _ in
            current.controlRevision = "changed"
            return true
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual((requests[0]["snapshot"] as? [String: Any])?["sequence"] as? Int, 1)
        XCTAssertEqual((requests[1]["snapshot"] as? [String: Any])?["sequence"] as? Int, 2)
        XCTAssertEqual((requests[1]["snapshot"] as? [String: Any])?["controlRevision"] as? String, "changed")
        XCTAssertEqual(Set(requests[1]["acknowledgedCommandIds"] as? [String] ?? []), ["accepted", "expired"])
    }

    @MainActor
    func testViewerControlWaitsForRevisionAndCannotSendWhilePendingOrStale() async throws {
        let clock = SharedWorkoutTestClock()
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(clock, session: session)
        var requests = 0
        WorkoutSyncURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/share/control")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["action"] as? String, "work")
            XCTAssertEqual(body["controlRevision"] as? String, "revision")
            requests += 1
            return (200, Data("{}".utf8))
        }
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        await service.requestWorkoutControl(.work)
        XCTAssertTrue(service.isWorkoutControlPending)
        await service.requestWorkoutControl(.work)
        XCTAssertEqual(requests, 1)
        service.receiveFriendHeartRate(response(snapshot(sequence: 2)), for: try poll(service))
        XCTAssertTrue(service.isWorkoutControlPending)
        service.receiveFriendHeartRate(response(snapshot(sequence: 3, revision: "changed")), for: try poll(service))
        XCTAssertFalse(service.isWorkoutControlPending)
        clock.seconds = 5
        await service.requestWorkoutControl(.work)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testViewerClearsReceivedPresetAndWaitsForOwnerConfirmation() async throws {
        let clock = SharedWorkoutTestClock()
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(clock, session: session)
        var requests = 0
        WorkoutSyncURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(request.url?.path, "/api/share/control")
            XCTAssertEqual(body["action"] as? String, "clearPreset")
            XCTAssertEqual(body["controlRevision"] as? String, "revision")
            XCTAssertNil(body["preset"])
            requests += 1
            return (200, Data("{}".utf8))
        }
        var loaded = snapshot()
        loaded.state = .idle
        loaded.isPresetMode = true
        loaded.activePreset = TimerPreset(name: "Other device's preset")
        loaded.allowedActions = [.start, .loadPreset, .clearPreset]
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(loaded), for: try poll(service))
        await service.requestWorkoutControl(.clearPreset)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(service.isWorkoutControlPending)
        XCTAssertEqual(service.friendWorkout?.activePreset, loaded.activePreset)

        var cleared = loaded
        cleared.sequence = 2
        cleared.controlRevision = "cleared"
        cleared.isPresetMode = false
        cleared.activePreset = nil
        cleared.allowedActions = [.start, .loadPreset]
        service.receiveFriendHeartRate(response(cleared), for: try poll(service))
        XCTAssertFalse(service.isWorkoutControlPending)
        XCTAssertNil(service.friendWorkout?.activePreset)
        await service.requestWorkoutControl(.clearPreset)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testViewerRequestsHRVOnlyFromFreshHostCapabilityAndWaitsForRevision() async throws {
        let clock = SharedWorkoutTestClock()
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(clock, session: session)
        var requests = 0
        WorkoutSyncURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["action"] as? String, "hrvStart")
            XCTAssertEqual(body["controlRevision"] as? String, "ready-hrv")
            XCTAssertNil(body["preset"])
            requests += 1
            return (200, Data("{}".utf8))
        }
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        await service.requestWorkoutControl(.hrvStart)
        XCTAssertEqual(requests, 0)

        var ready = snapshot(sequence: 2, revision: "ready-hrv")
        ready.hrv = SharedHRVSnapshot(revision: UUID().uuidString, isPresented: false, state: .idle,
                                      remainingTime: 120, hrvValue: nil, avgHeartRate: nil, minHeartRate: nil,
                                      maxHeartRate: nil, currentBPM: 60, readinessReason: .ready,
                                      errorMessage: nil, allowsRemoteControl: true)
        service.receiveFriendHeartRate(response(ready), for: try poll(service))
        await service.requestWorkoutControl(.hrvStart)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(service.isWorkoutControlPending)
        await service.requestWorkoutControl(.hrvStart)
        XCTAssertEqual(requests, 1)

        var measuring = ready
        measuring.sequence = 3
        measuring.controlRevision = "measuring-hrv"
        measuring.hrv?.revision = UUID().uuidString
        measuring.hrv?.state = .measuring
        measuring.hrv?.isPresented = true
        service.receiveFriendHeartRate(response(measuring), for: try poll(service))
        XCTAssertFalse(service.isWorkoutControlPending)
        XCTAssertEqual(service.friendWorkout?.hrv?.state, .measuring)
        clock.seconds = 5
        await service.requestWorkoutControl(.hrvCancel)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(service.friendWorkoutIsFresh)
    }

    @MainActor
    func testUnconfirmedControlExpiresWithoutAutomaticRetryAndNewRevisionClearsError() async throws {
        let clock = SharedWorkoutTestClock()
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(clock, session: session)
        var requests = 0
        WorkoutSyncURLProtocol.handler = { _ in
            requests += 1
            return (200, Data("{}".utf8))
        }
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        await service.requestWorkoutControl(.work)
        clock.seconds = 5
        service.refreshFriendWorkoutFreshness()
        XCTAssertFalse(service.isWorkoutControlPending)
        XCTAssertNotNil(service.workoutControlError)
        XCTAssertEqual(requests, 1)
        service.receiveFriendHeartRate(response(snapshot(sequence: 2, revision: "changed")), for: try poll(service))
        XCTAssertNil(service.workoutControlError)
    }

    @MainActor
    func testLostControlResponseKeepsRequestPendingUntilRevisionOrExpiry() async throws {
        let clock = SharedWorkoutTestClock()
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(clock, session: session)
        var requests = 0
        WorkoutSyncURLProtocol.handler = { _ in
            requests += 1
            throw URLError(.networkConnectionLost)
        }
        service.startViewing(code: "123456")
        service.receiveFriendHeartRate(response(snapshot()), for: try poll(service))
        await service.requestWorkoutControl(.work)
        XCTAssertTrue(service.isWorkoutControlPending)
        XCTAssertNotNil(service.workoutControlError)
        await service.requestWorkoutControl(.work)
        XCTAssertEqual(requests, 1)
        clock.seconds = 4
        service.receiveFriendHeartRate(response(snapshot(sequence: 2)), for: try poll(service))
        XCTAssertTrue(service.isWorkoutControlPending)
        clock.seconds = 5
        service.refreshFriendWorkoutFreshness()
        XCTAssertFalse(service.isWorkoutControlPending)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testOldServerWithoutWorkoutRouteKeepsHeartRateSharingAndStopsUnsupportedPolling() async {
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(SharedWorkoutTestClock(), session: session)
        service.isSharing = true
        service.shareToken = "host"
        var requests = 0
        WorkoutSyncURLProtocol.handler = { _ in
            requests += 1
            return (405, Data(#"{"message":"Method not allowed"}"#.utf8))
        }
        for _ in 0..<2 {
            await service.syncWorkout(snapshotProvider: { self.snapshot() }) { _ in
                XCTFail("Unsupported route cannot apply commands")
                return false
            }
        }
        XCTAssertTrue(service.isSharing)
        XCTAssertEqual(service.shareToken, "host")
        XCTAssertNotNil(service.workoutSharingError)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testRepeatedShareStartsAcrossMenuReentryReuseInFlightAndActiveSession() async throws {
        let session = makeNetworkSession()
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            session.invalidateAndCancel()
            WorkoutSyncURLProtocol.handler = nil
        }
        let service = makeService(SharedWorkoutTestClock(), session: session)
        let started = expectation(description: "Original session request is in flight")
        let requests = SharingStartRequestCounter()
        WorkoutSyncURLProtocol.handler = { request in
            let requestNumber = requests.increment()
            XCTAssertEqual(request.url?.path, "/api/share")
            XCTAssertEqual(request.httpMethod, "POST")
            if requestNumber == 1 {
                started.fulfill()
                guard releaseResponse.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            return (200, Data(#"{"code":"123456","token":"original-session"}"#.utf8))
        }

        XCTAssertFalse(service.isStartingSharing)
        let originalStart = Task { try await service.startSharing() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(service.isStartingSharing)
        XCTAssertFalse(service.isSharing)

        // Recreated Home/Workout menus share this service. Their repeated taps
        // must return without replacing or waiting on the original request.
        let repeatedStartsReturned = expectation(description: "Reentered menus reuse the pending session")
        repeatedStartsReturned.expectedFulfillmentCount = 3
        let repeatedStarts = (0..<3).map { _ in
            Task {
                try await service.startSharing()
                repeatedStartsReturned.fulfill()
            }
        }
        await fulfillment(of: [repeatedStartsReturned], timeout: 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(service.isStartingSharing)
        XCTAssertNil(service.shareCode)

        releaseResponse.signal()
        try await originalStart.value
        for repeatedStart in repeatedStarts { try await repeatedStart.value }
        XCTAssertTrue(service.isSharing)
        XCTAssertFalse(service.isStartingSharing)
        XCTAssertEqual(service.shareCode, "123456")
        XCTAssertEqual(service.shareToken, "original-session")

        for _ in 0..<3 { try await service.startSharing() }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(service.isSharing)
        XCTAssertFalse(service.isStartingSharing)
        XCTAssertEqual(service.shareCode, "123456")
        XCTAssertEqual(service.shareToken, "original-session")
    }

    @MainActor
    func testEnteringViewerModeInvalidatesPendingBroadcastAndDeletesAbandonedSession() async throws {
        let session = makeNetworkSession()
        defer { session.invalidateAndCancel(); WorkoutSyncURLProtocol.handler = nil }
        let service = makeService(SharedWorkoutTestClock(), session: session)
        let started = expectation(description: "Broadcast creation is in flight")
        let releaseResponse = DispatchSemaphore(value: 0)
        var deleted = false
        WorkoutSyncURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deleted = true
                return (200, Data("{}".utf8))
            }
            started.fulfill()
            guard releaseResponse.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return (200, Data(#"{"code":"123456","token":"abandoned"}"#.utf8))
        }
        let start = Task { try await service.startSharing() }
        await fulfillment(of: [started], timeout: 3)
        service.startViewing(code: "654321")
        releaseResponse.signal()
        do {
            try await start.value
            XCTFail("A superseded broadcast must not start")
        } catch is CancellationError {
            // The new viewing session owns the screen and connection mode.
        }
        XCTAssertTrue(service.isViewing)
        XCTAssertEqual(service.friendCode, "654321")
        XCTAssertFalse(service.isSharing)
        XCTAssertNil(service.shareCode)
        XCTAssertNil(service.shareToken)
        XCTAssertTrue(deleted)
    }

    @MainActor
    func testLiveActivityTimerSurvivesMissingBPMOnlyUntilWorkoutExpires() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        XCTAssertNil(service.friendActivityTimer)
        service.receiveFriendHeartRate(response(snapshot(), workoutAge: 1, heartRateAge: 60), for: try poll(service))
        XCTAssertNil(service.friendHeartRate)
        let timer = try XCTUnwrap(service.friendActivityTimer)
        XCTAssertEqual(timer.elapsedSeconds, 21)
        XCTAssertEqual(timer.referenceDate, clock.date.addingTimeInterval(-21))
        XCTAssertEqual(timer.endDate, clock.date.addingTimeInterval(4))
        XCTAssertEqual(timer.expiresAt, clock.date.addingTimeInterval(4))

        clock.seconds = 3
        XCTAssertEqual(service.friendActivityTimer?.elapsedSeconds, 24)
        // Reading the same stored snapshot must not extend its lifetime.
        service.receiveFriendHeartRate(response(snapshot(), workoutAge: 1, heartRateAge: 60), for: try poll(service))
        clock.seconds = 4
        XCTAssertNil(service.friendActivityTimer)
    }

    @MainActor
    func testLiveActivityPausedTimerHasNoRunningReferenceAndIdleWorkoutHasNoTimer() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        var paused = snapshot()
        paused.state = .paused
        paused.totalTimeAdvances = false
        paused.setTimeDirection = 0
        service.receiveFriendHeartRate(response(paused), for: try poll(service))
        clock.seconds = 2
        let timer = try XCTUnwrap(service.friendActivityTimer)
        XCTAssertEqual(timer.elapsedSeconds, 20)
        XCTAssertNil(timer.referenceDate)
        XCTAssertNil(timer.endDate)

        var idle = snapshot(sequence: 2)
        idle.state = .idle
        idle.isCompleted = true
        service.receiveFriendHeartRate(response(idle), for: try poll(service))
        XCTAssertNil(service.friendActivityTimer)
    }

    @MainActor
    func testLiveActivityCooldownIncludesElapsedCooldownAndStopsOnViewingFailure() throws {
        let clock = SharedWorkoutTestClock()
        let service = makeService(clock)
        service.startViewing(code: "123456")
        var cooldown = snapshot()
        cooldown.state = .cooldown
        cooldown.totalTime = 100
        cooldown.totalTimeAdvances = false
        cooldown.setTime = 90
        cooldown.setTimeDirection = -1
        service.receiveFriendHeartRate(response(cooldown), for: try poll(service))
        clock.seconds = 2
        XCTAssertEqual(service.friendActivityTimer?.elapsedSeconds, 132)

        service.receiveFriendHeartRateError("Connection lost", for: try poll(service))
        XCTAssertNil(service.friendActivityTimer)
        cooldown.sequence = 2
        service.receiveFriendHeartRate(response(cooldown), for: try poll(service))
        XCTAssertNotNil(service.friendActivityTimer)
        service.stopViewing()
        XCTAssertNil(service.friendActivityTimer)
    }

    @MainActor
    private func makeService(_ clock: SharedWorkoutTestClock, session: URLSession = .shared) -> SharingService {
        let defaults = UserDefaults(suiteName: "shared-workout-test-\(UUID())")!
        defaults.set("https://example.test", forKey: "BPM_API_BASE_URL")
        return SharingService(userDefaults: defaults, nowProvider: { clock.date }, ticksProvider: { clock.seconds },
                              automaticallyPoll: false, managesLiveActivities: false, networkSession: session)
    }

    private func makeNetworkSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkoutSyncURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func poll(_ service: SharingService) throws -> FriendHeartRatePoll {
        try XCTUnwrap(service.beginFriendHeartRatePoll())
    }

    private func response(_ snapshot: SharedWorkoutSnapshot, workoutAge: TimeInterval = 0, heartRateAge: TimeInterval = 0) -> HeartRateResponse {
        HeartRateResponse(bpm: nil, max: nil, avg: nil, min: nil,
                          timestamp: Int64((1_800_000_000 - heartRateAge) * 1000),
                          workout: snapshot, workoutTimestamp: Int64(10_000 - workoutAge * 1000), serverTime: 10_000)
    }

    private func command(_ id: String, workoutID: String = "workout", revision: String = "revision",
                         action: SharedWorkoutAction = .work, createdAt: Int64 = 10_000) -> SharedWorkoutCommand {
        SharedWorkoutCommand(id: id, workoutID: workoutID, controlRevision: revision, action: action, createdAt: createdAt)
    }

    private func snapshot(sequence: Int64 = 1, revision: String = "revision") -> SharedWorkoutSnapshot {
        SharedWorkoutSnapshot(sequence: sequence, workoutID: "workout", controlRevision: revision,
                              screen: .workout, page: .table, state: .running, isCompleted: false, isPresetMode: false,
                              canWork: true, canRest: false, totalTime: 20, setTime: 5, totalTimeAdvances: true,
                              setTimeDirection: 1, showTenths: true, isEmpty: false, avgWorkTime: nil,
                              avgBPM: nil, maxBPM: nil, minBPM: nil, zone: nil, setNumber: "1", calories: "---",
                              primaryBPM: "---", rows: [], chart: [], segments: [], chartMaxTime: 20, zones: [])
    }
}

private final class SharingStartRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return requestCount
    }
}

private final class SharedWorkoutTestClock {
    var seconds: TimeInterval = 0
    var wallClockOffset: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds + wallClockOffset) }
}

private final class WorkoutSyncURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
