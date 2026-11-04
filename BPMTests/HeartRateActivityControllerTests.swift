import ActivityKit
import Foundation
import Testing
@testable import BPM

@MainActor
struct HeartRateActivityControllerTests {
    @Test func noReadingOrErrorAloneNeverStartsAnActivity() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)

        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: 0, average: nil, maximum: nil, minimum: nil, hasError: true)
        await controller.waitForPendingUpdates()
        controller.updateSharingState(isSharing: true)
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                  isViewing: true, hasError: true)
        await controller.waitForPendingUpdates()

        #expect(client.starts.isEmpty)
        #expect(client.currentContent == nil)
    }

    @Test func localSignalLossEndsImmediatelyAndReconnectCanStartAgain() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: 115, maximum: 130, minimum: 100)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == 120)

        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)

        controller.updateActivity(bpm: 121, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 2)
        #expect(client.currentContent?.state.bpm == 121)
    }

    @Test func timerOnlyWorkoutStartsAtZeroAndSurvivesSensorDisconnect() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        let reference = Date()
        controller.updateTimer(elapsedSeconds: 0, isRunning: true, referenceDate: reference)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.elapsedSeconds == 0)
        #expect(client.currentContent?.state.timerReferenceDate == reference)

        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        controller.endLocalHeartRate()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == nil)
        #expect(client.currentContent?.state.elapsedSeconds == 0)
        #expect(client.starts.count == 1)

        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
    }

    @Test func pausedWorkoutKeepsItsFrozenTimeWithoutAReading() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateTimer(elapsedSeconds: 90, isRunning: true, referenceDate: nil)
        await controller.waitForPendingUpdates()

        #expect(client.currentContent?.state.elapsedSeconds == 90)
        #expect(client.currentContent?.state.timerReferenceDate == nil)
        controller.endLocalHeartRate()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.elapsedSeconds == 90)
    }

    @Test func stoppingSharingDoesNotEndSensorOrTimerSession() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil, isSharing: true)
        await controller.waitForPendingUpdates()
        controller.updateSharingState(isSharing: false)
        await controller.waitForPendingUpdates()

        #expect(client.currentContent?.state.bpm == 120)
        #expect(client.currentContent?.state.isSharing == false)
        #expect(client.starts.count == 1)
    }

    @Test func friendSignalLossAndStopViewingEndTheActivity() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.isViewing == true)

        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                  isViewing: true, hasError: true)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)

        controller.updateActivity(bpm: 145, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        controller.endViewing()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
    }

    @Test func friendWorkoutWithoutHeartRateEndsWhenItsSnapshotExpires() async {
        let clock = HeartRateActivityTestClock()
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client, now: { clock.now })
        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                  isViewing: true, elapsedSeconds: 40,
                                  timerReferenceDate: clock.now.addingTimeInterval(-40),
                                  timerExpiresAt: clock.now.addingTimeInterval(5))
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.elapsedSeconds == 40)
        #expect(client.currentContent?.state.isViewing == true)

        clock.now.addTimeInterval(6)
        controller.updateSharingState(isSharing: false)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
    }

    @Test func localDisconnectDoesNotDismissFriendAndStoppingViewerRestoresLocalReading() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 110, average: nil, maximum: nil, minimum: nil)
        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()

        controller.endLocalHeartRate()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == 144)
        #expect(client.currentContent?.state.isViewing == true)

        controller.updateActivity(bpm: 111, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == 144)
        controller.endViewing()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == 111)
        #expect(client.currentContent?.state.isViewing == false)
    }

    @Test func localWorkoutTakesPriorityAndSurvivesStoppingTheViewer() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        controller.updateTimer(elapsedSeconds: 20, isRunning: true)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.bpm == nil)
        #expect(client.currentContent?.state.isViewing == false)
        #expect(client.currentContent?.state.elapsedSeconds == 20)

        controller.endViewing()
        await controller.waitForPendingUpdates()
        #expect(client.currentContent?.state.elapsedSeconds == 20)
        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
    }

    @Test func staleHeartRateCannotReturnWhenWorkoutStopsOrSharingChanges() async {
        let clock = HeartRateActivityTestClock()
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client, now: { clock.now })
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil,
                                  heartRateExpiresAt: clock.now.addingTimeInterval(3))
        controller.updateTimer(elapsedSeconds: 10, isRunning: true)
        await controller.waitForPendingUpdates()

        clock.now.addTimeInterval(4)
        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
        controller.updateSharingState(isSharing: true)
        await controller.waitForPendingUpdates()
        #expect(client.currentContent == nil)
        #expect(client.starts.count == 1)
    }

    @Test(arguments: [ActivityState.dismissed, .ended])
    func dismissedActivityDoesNotReappearUntilTheSensorSessionRestarts(state: ActivityState) async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        client.activityState = state
        controller.updateActivity(bpm: 121, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        controller.updateSharingState(isSharing: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 1)

        controller.endLocalHeartRate()
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: 122, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 2)
        #expect(client.currentContent?.state.bpm == 122)
    }

    @Test func dismissedFriendActivityStaysDismissedUntilViewingRestarts() async {
        let clock = HeartRateActivityTestClock()
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client, now: { clock.now })
        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateActivity(bpm: 145, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 1)

        clock.now.addTimeInterval(4)
        controller.refreshActivity()
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: nil, average: nil, maximum: nil, minimum: nil,
                                  isViewing: true, hasError: true)
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: 146, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 1)
        #expect(client.currentContent == nil)

        controller.endViewing()
        await controller.waitForPendingUpdates()
        controller.updateActivity(bpm: 147, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 2)
        #expect(client.currentContent?.state.bpm == 147)
    }

    @Test func dismissedTimerActivityStaysDismissedUntilANewWorkoutStarts() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateTimer(elapsedSeconds: 20, isRunning: true)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateTimer(elapsedSeconds: 21, isRunning: true)
        await controller.waitForPendingUpdates()
        controller.endLocalHeartRate()
        controller.updateTimer(elapsedSeconds: 22, isRunning: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 1)

        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
        await controller.waitForPendingUpdates()
        controller.updateTimer(elapsedSeconds: 0, isRunning: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 2)
        #expect(client.currentContent?.state.elapsedSeconds == 0)
    }

    @Test func dismissingViewerDoesNotForgetTheLocalSensorDismissal() async {
        let clock = HeartRateActivityTestClock()
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client, now: { clock.now })
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateActivity(bpm: 121, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()

        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateActivity(bpm: 145, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        controller.endViewing()
        await controller.waitForPendingUpdates()

        #expect(client.starts.count == 2)
        #expect(client.currentContent == nil)
        controller.endLocalHeartRate()
        controller.updateActivity(bpm: 122, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 3)
        #expect(client.currentContent?.state.bpm == 122)
    }

    @Test func dismissingWorkoutDoesNotForgetTheViewerDismissal() async {
        let clock = HeartRateActivityTestClock()
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client, now: { clock.now })
        controller.updateActivity(bpm: 144, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateActivity(bpm: 145, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()

        controller.updateTimer(elapsedSeconds: 20, isRunning: true)
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed
        controller.updateTimer(elapsedSeconds: 21, isRunning: true)
        await controller.waitForPendingUpdates()
        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
        await controller.waitForPendingUpdates()

        #expect(client.starts.count == 2)
        #expect(client.currentContent == nil)
        controller.endViewing()
        controller.updateActivity(bpm: 146, average: nil, maximum: nil, minimum: nil, isViewing: true)
        await controller.waitForPendingUpdates()
        #expect(client.starts.count == 3)
        #expect(client.currentContent?.state.bpm == 146)
    }

    @Test func signalLostBeforeAQueuedRequestNeverCreatesAnEmptyActivity() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        controller.endLocalHeartRate()
        await controller.waitForPendingUpdates()

        #expect(client.starts.isEmpty)
        #expect(client.currentContent == nil)
    }

    @Test(arguments: ["sensor", "viewer", "workout"])
    func dismissalOfPreviousSessionCannotSuppressACoalescedRestart(source: String) async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        if source == "workout" {
            controller.updateTimer(elapsedSeconds: 20, isRunning: true)
        } else {
            controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil,
                                      isViewing: source == "viewer")
        }
        await controller.waitForPendingUpdates()
        client.activityState = .dismissed

        // End and restart before the asynchronous reconciler sees the old
        // activity's dismissal, as can happen during rapid session changes.
        switch source {
        case "viewer":
            controller.endViewing()
            controller.updateActivity(bpm: 160, average: nil, maximum: nil, minimum: nil, isViewing: true)
        case "workout":
            controller.updateTimer(elapsedSeconds: nil, isRunning: false)
            controller.updateTimer(elapsedSeconds: 0, isRunning: true)
        default:
            controller.endLocalHeartRate()
            controller.updateActivity(bpm: 160, average: nil, maximum: nil, minimum: nil)
        }
        await controller.waitForPendingUpdates()

        #expect(client.starts.count == 2)
        #expect(client.activityState == .active)
        if source == "workout" {
            #expect(client.currentContent?.state.elapsedSeconds == 0)
        } else {
            #expect(client.currentContent?.state.bpm == 160)
        }
    }

    @Test func disconnectDuringAnInFlightUpdateCannotResurrectTheActivity() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        let gate = HeartRateActivityOperationGate()
        client.nextUpdateGate = gate
        controller.updateActivity(bpm: 140, average: nil, maximum: nil, minimum: nil)
        await gate.waitUntilEntered()

        controller.endLocalHeartRate()
        gate.release()
        await controller.waitForPendingUpdates()

        #expect(client.currentContent == nil)
        #expect(client.starts.count == 1)
        #expect(client.maximumConcurrentOperations == 1)
    }

    @Test func reconnectDuringAnInFlightEndStartsOnlyTheLatestReading() async {
        let client = RecordingHeartRateActivityClient()
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await controller.waitForPendingUpdates()
        let gate = HeartRateActivityOperationGate()
        client.nextEndGate = gate
        controller.endLocalHeartRate()
        await gate.waitUntilEntered()

        controller.updateActivity(bpm: 160, average: nil, maximum: nil, minimum: nil)
        gate.release()
        await controller.waitForPendingUpdates()

        #expect(client.currentContent?.state.bpm == 160)
        #expect(client.starts.count == 2)
        #expect(client.maximumConcurrentOperations == 1)
    }

    @Test func launchCleanupFinishesBeforeStartingTheCurrentSession() async {
        let client = RecordingHeartRateActivityClient()
        client.activityState = .active
        let gate = HeartRateActivityOperationGate()
        client.nextEndGate = gate
        let controller = HeartRateActivityController(client: client)
        controller.updateActivity(bpm: 120, average: nil, maximum: nil, minimum: nil)
        await gate.waitUntilEntered()
        #expect(client.starts.isEmpty)

        controller.endLocalHeartRate()
        gate.release()
        await controller.waitForPendingUpdates()
        #expect(client.starts.isEmpty)
        #expect(client.currentContent == nil)
        #expect(client.maximumConcurrentOperations == 1)
    }
}

@MainActor
private final class HeartRateActivityTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class HeartRateActivityOperationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class RecordingHeartRateActivityClient: HeartRateActivityClient {
    typealias Content = ActivityContent<HeartRateActivityAttributes.ContentState>

    var areActivitiesEnabled = true
    var activityState: ActivityState?
    var currentContent: Content?
    var starts: [Content] = []
    var nextUpdateGate: HeartRateActivityOperationGate?
    var nextEndGate: HeartRateActivityOperationGate?
    private(set) var maximumConcurrentOperations = 0
    private var concurrentOperations = 0

    func endAllActivities() async {
        beginOperation()
        defer { concurrentOperations -= 1 }
        if let gate = nextEndGate {
            nextEndGate = nil
            await gate.enter()
        }
        activityState = nil
        currentContent = nil
    }

    func update(_ content: Content) async {
        beginOperation()
        defer { concurrentOperations -= 1 }
        if let gate = nextUpdateGate {
            nextUpdateGate = nil
            await gate.enter()
        }
        currentContent = content
    }

    func start(_ content: Content) throws {
        beginOperation()
        defer { concurrentOperations -= 1 }
        starts.append(content)
        currentContent = content
        activityState = .active
    }

    private func beginOperation() {
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
    }
}
