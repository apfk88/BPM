import XCTest
@testable import BPM

@MainActor
final class SharedWorkoutPresentationTests: XCTestCase {
    func testNavigationPreservesSessionAndControlRevision() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.start()
        clock.advance(42)
        timer.refreshTiming()
        let workout = snapshot(timer)
        let home = snapshot(timer, screen: .home, page: .chart)
        XCTAssertEqual(home.workoutID, workout.workoutID)
        XCTAssertEqual(home.controlRevision, workout.controlRevision)
        XCTAssertEqual(home.totalTime, 42, accuracy: 0.001)
        XCTAssertTrue(home.permits(.work))
        XCTAssertTrue(home.permits(.rest))
        XCTAssertEqual(home.rows.last?.duration, 42)
        XCTAssertEqual(timer.state, .running)
    }

    func testRemoteSetUsesOwnerClockAndHeartRateAndCannotBeReplayed() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.currentHeartRate = { 147 }
        timer.start()
        clock.advance(12)
        let before = snapshot(timer)
        let work = command(.work, snapshot: before)
        XCTAssertTrue(SharedWorkoutPresentation.apply(work, to: timer, current: before))
        XCTAssertEqual(timer.sets.count, 1)
        XCTAssertEqual(timer.sets.first?.setTime, 12)
        XCTAssertEqual(timer.sets.first?.heartRate, 147)
        XCTAssertFalse(SharedWorkoutPresentation.apply(work, to: timer, current: snapshot(timer)))
        XCTAssertEqual(timer.sets.count, 1)

        clock.advance(8)
        let restState = snapshot(timer)
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.rest, snapshot: restState), to: timer, current: restState))
        XCTAssertTrue(timer.isTimingRestSet)
        let resting = snapshot(timer)
        XCTAssertTrue(resting.permits(.work))
        XCTAssertFalse(resting.permits(.rest))
        XCTAssertEqual(resting.rows.last?.label, "2R")
        XCTAssertTrue(resting.rows.last?.isActive == true)
    }

    func testBlockingViewerSetLoggingRevokesPendingSetsWhileOwnerKeepsLogging() {
        let defaults = UserDefaults.standard
        let key = SharedWorkoutPresentation.blockViewerSetLoggingKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer { defaults.set(previous, forKey: key) }

        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.start()
        clock.advance(5)
        let open = snapshot(timer)
        XCTAssertTrue(open.canWork && open.canRest)
        XCTAssertTrue(open.permits(.work) && open.permits(.rest))

        defaults.set(true, forKey: key)
        let blocked = snapshot(timer)
        XCTAssertFalse(blocked.canWork)
        XCTAssertFalse(blocked.canRest)
        for action in [SharedWorkoutAction.work, .rest] {
            let pending = command(action, snapshot: open)
            XCTAssertFalse(blocked.permits(action))
            XCTAssertFalse(SharedWorkoutPresentation.apply(pending, to: timer, current: blocked))
            XCTAssertFalse(SharedWorkoutPresentation.apply(pending, to: timer, current: open))
        }
        XCTAssertTrue(timer.sets.isEmpty)
        timer.captureRestSet()
        XCTAssertTrue(timer.isTimingRestSet)
        clock.advance(3)
        timer.captureSet()
        XCTAssertFalse(timer.isTimingRestSet)
        timer.stop()
        XCTAssertTrue(snapshot(timer).permits(.resume))
        timer.start()

        defaults.set(false, forKey: key)
        let reopened = snapshot(timer)
        XCTAssertTrue(reopened.canWork && reopened.canRest)
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.rest, snapshot: reopened), to: timer, current: reopened))
    }

    func testViewerSetBellsFollowAcceptedCommandsAndTheHostPreference() {
        let defaults = UserDefaults.standard
        let key = SharedWorkoutPresentation.viewerSetBellsKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer { defaults.set(previous, forKey: key) }

        let clock = Clock()
        var cues: [TimerSoundCue] = []
        let timer = makeTimer(clock, soundCueHandler: { cues.append($0) })
        defer { timer.reset() }
        timer.start()

        func mark(_ action: SharedWorkoutAction) {
            clock.advance(3)
            let current = snapshot(timer)
            let request = command(action, snapshot: current)
            XCTAssertTrue(SharedWorkoutPresentation.apply(request, to: timer, current: current))
            XCTAssertFalse(SharedWorkoutPresentation.apply(request, to: timer, current: snapshot(timer)))
        }

        mark(.work)
        mark(.rest)
        XCTAssertEqual(cues, [.workBegins, .restBegins])

        defaults.set(false, forKey: key)
        mark(.work)
        mark(.rest)
        XCTAssertEqual(cues, [.workBegins, .restBegins])

        defaults.set(true, forKey: key)
        let audio = WorkoutRecordingAudio.shared
        let wasRecording = audio.isRecording
        defer { audio.setRecording(wasRecording) }
        audio.setRecording(true)
        mark(.work)
        audio.setRecording(false)
        timer.captureRestSet()
        XCTAssertEqual(cues, [.workBegins, .restBegins])

        mark(.work)
        XCTAssertEqual(cues, [.workBegins, .restBegins, .workBegins])
    }

    func testPauseResumeAndResetInvalidatePreviouslyRequestedSets() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.start()
        clock.advance(10)
        let initial = snapshot(timer)
        let oldCommand = command(.work, snapshot: initial)
        timer.stop()
        let paused = snapshot(timer)
        XCTAssertFalse(paused.permits(.work))
        XCTAssertEqual(paused.totalTime(after: 4), paused.totalTime)
        XCTAssertEqual(paused.setTime(after: 4), paused.setTime)
        XCTAssertFalse(SharedWorkoutPresentation.apply(oldCommand, to: timer, current: paused))
        clock.advance(1)
        timer.start()
        let resumed = snapshot(timer)
        XCTAssertNotEqual(resumed.controlRevision, initial.controlRevision)
        XCTAssertFalse(SharedWorkoutPresentation.apply(oldCommand, to: timer, current: resumed))
        timer.reset()
        timer.start()
        XCTAssertNotEqual(snapshot(timer).workoutID, initial.workoutID)
        XCTAssertFalse(SharedWorkoutPresentation.apply(oldCommand, to: timer, current: snapshot(timer)))
    }

    func testCooldownProjectsCountdownWithoutAdvancingFrozenWorkoutTotal() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.start()
        clock.advance(20)
        timer.end()
        let cooldown = snapshot(timer)
        XCTAssertEqual(cooldown.state, .cooldown)
        XCTAssertEqual(cooldown.totalTime(after: 3), 20)
        XCTAssertEqual(cooldown.setTime(after: 3), 117)
        XCTAssertFalse(cooldown.permits(.work))
        XCTAssertFalse(cooldown.permits(.rest))
        XCTAssertEqual(cooldown.rows.last?.label, "C2")
    }

    func testPresetAndCompletedWorkoutsDisallowRemoteSets() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.loadPreset(TimerPreset(name: "Intervals", workDuration: 30, restDuration: 10,
                                     numberOfSets: 3, includeCooldown: false, playSound: false))
        XCTAssertEqual(snapshot(timer).rows.count, 5)
        timer.startPreset()
        clock.advance(10)
        timer.refreshTiming()
        XCTAssertFalse(snapshot(timer).permits(.work))
        XCTAssertFalse(snapshot(timer).permits(.rest))
        timer.endWorkout()
        let completed = snapshot(timer)
        XCTAssertTrue(completed.isCompleted)
        XCTAssertFalse(completed.permits(.work))
    }

    func testPresetPrestartCountdownDoesNotAdvanceWorkoutRows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-countdown-\(UUID()).json")
        let timer = TimerViewModel(presetStartCountdownDuration: 5, sessionStore: ActiveWorkoutSessionStore(fileURL: url),
                                  soundCueHandler: { _ in })
        defer { timer.reset() }
        timer.loadPreset(TimerPreset(name: "Intervals", workDuration: 30, restDuration: 10,
                                     numberOfSets: 2, includeCooldown: false, playSound: false))
        timer.startPreset()
        let countdown = snapshot(timer)
        XCTAssertTrue(timer.isPresetPrestartCountdownActive)
        XCTAssertFalse(countdown.rowTimeAdvances)
        XCTAssertEqual(countdown.totalTime(after: 4), countdown.totalTime)
        XCTAssertEqual(countdown.setTime(after: 4), countdown.setTime)
    }

    func testChartReductionKeepsMeasuredExtremesAndSignalGaps() {
        let points: [SharedWorkoutSnapshot.ChartPoint] = (0..<2000).map { index in
            let bpm: Int
            if index == 431 { bpm = 223 }
            else if index == 1254 { bpm = 55 }
            else { bpm = 100 + index % 31 }
            return .init(time: Double(index), bpm: bpm, segment: index < 1000 ? 0 : 1,
                         validUntil: Double(index) + 0.25)
        }
        let reduced = SharedWorkoutPresentation.reducedChart(points, maxTime: 2000)
        XCTAssertLessThan(reduced.count, 800)
        XCTAssertTrue(reduced.contains(points[431]))
        XCTAssertTrue(reduced.contains(points[1254]))
        for index in [0, 999, 1000, 1999] { XCTAssertTrue(reduced.contains(points[index])) }
        XCTAssertTrue(reduced.allSatisfy { points.contains($0) })
    }

    func testSnapshotRoundTripsWithoutChangingLocalWorkout() throws {
        let timer = makeTimer(Clock())
        defer { timer.reset() }
        let initial = snapshot(timer, screen: .home)
        let decoded = try JSONDecoder().decode(SharedWorkoutSnapshot.self, from: JSONEncoder().encode(initial))
        XCTAssertEqual(decoded, initial)
        XCTAssertEqual(decoded.rows.first?.kind, "empty")
        XCTAssertEqual(timer.state, .idle)
        XCTAssertTrue(timer.sets.isEmpty)
    }

    func testOnlyOwnerCanPauseEndOrClearAnActiveWorkout() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        func apply(_ action: SharedWorkoutAction) {
            let current = snapshot(timer, screen: .home)
            XCTAssertTrue(current.permits(action))
            XCTAssertTrue(SharedWorkoutPresentation.apply(command(action, snapshot: current), to: timer, current: current))
        }
        func assertProtected() {
            let current = snapshot(timer)
            let forbidden: [SharedWorkoutAction] = [.pause, .end, .cool, .reset]
            var legacy = current
            legacy.allowedActions = forbidden
            for action in forbidden {
                XCTAssertFalse(current.allowedActions?.contains(action) == true)
                XCTAssertFalse(legacy.permits(action))
                XCTAssertFalse(SharedWorkoutPresentation.apply(command(action, snapshot: legacy), to: timer, current: legacy))
            }
            XCTAssertEqual(snapshot(timer), current)
        }
        apply(.start)
        XCTAssertEqual(timer.state, .running)
        clock.advance(12)
        assertProtected()
        timer.stop()
        XCTAssertEqual(timer.state, .paused)
        assertProtected()
        XCTAssertEqual(timer.elapsedTime, 12, accuracy: 0.001)
        clock.advance(30)
        apply(.resume)
        clock.advance(8)
        timer.captureSet()
        timer.end()
        XCTAssertEqual(timer.state, .cooldown)
        XCTAssertEqual(timer.frozenElapsedTime, 20, accuracy: 0.001)
        XCTAssertEqual(timer.sets.first?.setTime, 20)
        assertProtected()
        timer.toggleCooldown()
        XCTAssertEqual(timer.state, .cooldownPaused)
        assertProtected()
        apply(.resume)
        XCTAssertEqual(timer.state, .cooldown)
        timer.endWorkout()
        XCTAssertTrue(timer.isCompleted)
        apply(.resume)
        XCTAssertEqual(timer.state, .cooldown)
        timer.endWorkout()
        let beforeReset = snapshot(timer)
        let resetCommand = command(.reset, snapshot: beforeReset)
        XCTAssertTrue(SharedWorkoutPresentation.apply(resetCommand, to: timer, current: beforeReset))
        XCTAssertEqual(timer.state, .idle)
        XCTAssertTrue(timer.sets.isEmpty)
        XCTAssertFalse(SharedWorkoutPresentation.apply(resetCommand, to: timer, current: snapshot(timer)))
        XCTAssertNil(SharedWorkoutAction(rawValue: "save"))
    }

    func testTrainerLoadsAndClearsExactPresetAndRejectsInvalidPayloads() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        let preset = TimerPreset(name: "Trainer intervals", workDuration: 45, restDuration: 15,
                                 numberOfSets: 4, includeCooldown: true, playSound: false)
        let initial = snapshot(timer)
        var load = command(.loadPreset, snapshot: initial)
        load.preset = preset
        XCTAssertTrue(SharedWorkoutPresentation.apply(load, to: timer, current: initial))
        XCTAssertEqual(timer.activePreset, preset)
        XCTAssertEqual(snapshot(timer).activePreset, preset)
        XCTAssertFalse(snapshot(timer).permits(.work))

        let loaded = snapshot(timer)
        var invalidLoad = command(.loadPreset, snapshot: loaded)
        invalidLoad.preset = TimerPreset(name: "Invalid", workDuration: -1)
        XCTAssertFalse(SharedWorkoutPresentation.apply(invalidLoad, to: timer, current: loaded))
        XCTAssertEqual(timer.activePreset, preset)
        var unexpectedPayload = command(.start, snapshot: loaded)
        unexpectedPayload.preset = preset
        XCTAssertFalse(SharedWorkoutPresentation.apply(unexpectedPayload, to: timer, current: loaded))

        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.start, snapshot: loaded), to: timer, current: loaded))
        clock.advance(5)
        timer.refreshTiming()
        let running = snapshot(timer)
        XCTAssertFalse(running.permits(.pause))
        XCTAssertFalse(running.permits(.loadPreset))
        XCTAssertFalse(running.permits(.clearPreset))
        XCTAssertFalse(running.permits(.cool))
        XCTAssertFalse(SharedWorkoutPresentation.apply(command(.end, snapshot: running), to: timer, current: running))
        timer.endWorkout()
        let completed = snapshot(timer)
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.reset, snapshot: completed), to: timer, current: completed))
        let empty = snapshot(timer)
        load = command(.loadPreset, snapshot: empty)
        load.preset = preset
        XCTAssertTrue(SharedWorkoutPresentation.apply(load, to: timer, current: empty))
        let reloaded = snapshot(timer)
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.clearPreset, snapshot: reloaded), to: timer, current: reloaded))
        XCTAssertNil(timer.activePreset)
        XCTAssertEqual(timer.state, .idle)
    }

    func testLegacySnapshotOnlyPermitsItsOriginalManualSetControls() {
        let timer = makeTimer(Clock())
        defer { timer.reset() }
        timer.start()
        var legacy = snapshot(timer)
        legacy.allowedActions = nil
        XCTAssertTrue(legacy.permits(.work))
        XCTAssertTrue(legacy.permits(.rest))
        for action in SharedWorkoutAction.allCases where action != .work && action != .rest {
            XCTAssertFalse(legacy.permits(action))
        }
    }

    func testEitherParticipantCanClearAPresetRegardlessOfWhoLoadedIt() {
        for loadedRemotely in [false, true] {
            for clearedRemotely in [false, true] {
                let timer = makeTimer(Clock())
                defer { timer.reset() }
                let preset = TimerPreset(name: "Shared intervals", workDuration: 30, restDuration: 10,
                                         numberOfSets: 3, includeCooldown: false, playSound: false)
                if loadedRemotely {
                    let empty = snapshot(timer)
                    var load = command(.loadPreset, snapshot: empty)
                    load.preset = preset
                    XCTAssertTrue(SharedWorkoutPresentation.apply(load, to: timer, current: empty))
                } else {
                    timer.loadPreset(preset)
                }

                let loaded = snapshot(timer)
                XCTAssertTrue(timer.canClearPreset)
                XCTAssertTrue(loaded.permits(.clearPreset))
                if clearedRemotely {
                    XCTAssertTrue(SharedWorkoutPresentation.apply(command(.clearPreset, snapshot: loaded),
                                                                 to: timer, current: loaded))
                } else {
                    timer.clearPreset()
                }

                let cleared = snapshot(timer)
                XCTAssertNil(timer.activePreset)
                XCTAssertNil(cleared.activePreset)
                XCTAssertTrue(cleared.isEmpty)
                XCTAssertFalse(timer.canClearPreset)
                XCTAssertFalse(cleared.permits(.clearPreset))
                XCTAssertNotEqual(cleared.controlRevision, loaded.controlRevision)
            }
        }
    }

    func testClearPresetCannotChangeAnActiveWorkoutOrItsEndedRecovery() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        let preset = TimerPreset(name: "Intervals", workDuration: 30, restDuration: 10,
                                 numberOfSets: 3, includeCooldown: false, playSound: false)
        timer.loadPreset(preset)
        let loaded = snapshot(timer)
        let delayedClear = command(.clearPreset, snapshot: loaded)
        timer.startPreset()
        clock.advance(8)
        timer.refreshTiming()
        let running = snapshot(timer)
        XCTAssertFalse(timer.canClearPreset)
        XCTAssertFalse(SharedWorkoutPresentation.apply(delayedClear, to: timer, current: running))
        timer.clearPreset()
        XCTAssertEqual(snapshot(timer), running)

        timer.pausePreset()
        let paused = snapshot(timer)
        timer.clearPreset()
        XCTAssertEqual(snapshot(timer), paused)
        XCTAssertEqual(timer.activePreset, preset)

        timer.endWorkout()
        let ended = snapshot(timer)
        XCTAssertTrue(ended.isCompleted)
        XCTAssertNil(ended.activePreset)
        timer.clearPreset()
        XCTAssertEqual(snapshot(timer), ended)
        timer.resumeEndedWorkout()
        XCTAssertEqual(timer.activePreset, preset)
        XCTAssertEqual(timer.elapsedTime, 8, accuracy: 0.001)
    }

    func testEndingPresetCountdownStillClearsWithoutStartingARecording() {
        let clock = Clock()
        let timer = makeTimer(clock, countdownDuration: 5)
        defer { timer.reset() }
        timer.loadPreset(TimerPreset(name: "Intervals", workDuration: 30, restDuration: 10,
                                    numberOfSets: 3, includeCooldown: false, playSound: false))
        timer.startPreset()
        clock.advance(2)
        timer.refreshTiming()
        XCTAssertTrue(timer.isPresetPrestartCountdownActive)
        XCTAssertFalse(timer.canClearPreset)
        XCTAssertFalse(snapshot(timer).permits(.clearPreset))

        timer.endWorkout()
        clock.advance(10)
        timer.refreshTiming()
        XCTAssertEqual(timer.state, .idle)
        XCTAssertNil(timer.activePreset)
        XCTAssertFalse(timer.isPresetPrestartCountdownActive)
        XCTAssertFalse(timer.isCompleted)
        XCTAssertNil(timer.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)))
    }

    func testSavingOwnerWorkoutRejectsQueuedTrainerChangesWithoutClearingItsData() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        timer.start()
        clock.advance(30)
        timer.endWorkout()
        let ended = snapshot(timer)
        let queuedReset = command(.reset, snapshot: ended)
        let queuedResume = command(.resume, snapshot: ended)
        let savedRows = ended.rows
        let busy = SharedWorkoutPresentation.snapshot(
            timer: timer, screen: .workout, page: .table, heartRate: nil,
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg", calories: "---",
            allowsRemoteControl: false
        )

        XCTAssertEqual(busy.allowedActions, [])
        for action in SharedWorkoutAction.allCases { XCTAssertFalse(busy.permits(action)) }
        XCTAssertFalse(SharedWorkoutPresentation.apply(queuedReset, to: timer, current: busy))
        XCTAssertFalse(SharedWorkoutPresentation.apply(queuedResume, to: timer, current: busy))
        XCTAssertTrue(timer.isCompleted)
        XCTAssertEqual(snapshot(timer).rows, savedRows)
        XCTAssertEqual(snapshot(timer).workoutID, ended.workoutID)

        let afterCancel = snapshot(timer)
        XCTAssertTrue(afterCancel.permits(.resume))
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.resume, snapshot: afterCancel), to: timer, current: afterCancel))
        XCTAssertEqual(timer.state, .running)
        XCTAssertEqual(timer.elapsedTime, 30, accuracy: 0.001)
    }

    func testTrainerCanIncludeOwnerHistoryAndSensorChangeInvalidatesOldRequest() {
        let clock = Clock()
        let timer = makeTimer(clock)
        defer { timer.reset() }
        var sessionID = UUID()
        let history = [HeartRateSample(value: 120, timestamp: clock.date.addingTimeInterval(-85), workoutTime: nil),
                       HeartRateSample(value: 140, timestamp: clock.date.addingTimeInterval(-20), workoutTime: nil)]
        timer.currentSessionMeasurements = { (sessionID, history) }
        let available = snapshot(timer)
        XCTAssertEqual(available.recoverableHistorySeconds, 85)
        XCTAssertTrue(available.permits(.startIncludingHistory))
        let old = command(.startIncludingHistory, snapshot: available)
        sessionID = UUID()
        let changed = snapshot(timer)
        XCTAssertNotEqual(changed.controlRevision, available.controlRevision)
        XCTAssertFalse(SharedWorkoutPresentation.apply(old, to: timer, current: changed))
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.startIncludingHistory, snapshot: changed), to: timer, current: changed))
        XCTAssertEqual(timer.elapsedTime, 85, accuracy: 0.001)
        XCTAssertEqual(timer.minHeartRate, 120)
        XCTAssertEqual(timer.maxHeartRate, 140)
    }

    private func snapshot(_ timer: TimerViewModel, screen: SharedWorkoutSnapshot.Screen = .workout,
                          page: SharedWorkoutSnapshot.Page = .table) -> SharedWorkoutSnapshot {
        SharedWorkoutPresentation.snapshot(timer: timer, screen: screen, page: page, heartRate: 147,
                                          zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg", calories: "---")
    }

    private func command(_ action: SharedWorkoutAction, snapshot: SharedWorkoutSnapshot) -> SharedWorkoutCommand {
        SharedWorkoutCommand(id: UUID().uuidString, workoutID: snapshot.workoutID,
                             controlRevision: snapshot.controlRevision, action: action, createdAt: 0)
    }

    private func makeTimer(_ clock: Clock, countdownDuration: TimeInterval = 0,
                           soundCueHandler: @escaping (TimerSoundCue) -> Void = { _ in }) -> TimerViewModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-workout-\(UUID()).json")
        return TimerViewModel(presetStartCountdownDuration: countdownDuration, sessionStore: ActiveWorkoutSessionStore(fileURL: url),
                              nowProvider: { clock.date }, soundCueHandler: soundCueHandler)
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1000)
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }
}
