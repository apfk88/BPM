import Foundation
import Testing
@testable import BPM

@MainActor
struct WorkoutEndRecoveryTests {
    @Test func resumesTheSameSetAndExcludesTheEndedInterval() throws {
        var now = Date(timeIntervalSince1970: 1000)
        let origin = now
        let store = makeStore()
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset() }
        model.start()
        now = origin.addingTimeInterval(20)
        model.recordHeartRateSample(HeartRateSample(value: 130, timestamp: now, workoutTime: nil))
        model.endWorkout()
        model.endWorkout() // Repeated taps cannot finalize the same set twice.
        #expect(model.state == .idle)
        #expect(model.sets.count == 1)
        #expect(model.sets[0].setTime == 20)
        now = origin.addingTimeInterval(50)
        model.resumeEndedWorkout()
        model.resumeEndedWorkout()
        #expect(model.state == .running)
        #expect(model.elapsedTime == 20)
        #expect(model.currentSetTime == 20)
        #expect(model.sets.isEmpty)
        now = origin.addingTimeInterval(60)
        model.recordHeartRateSample(HeartRateSample(value: 150, timestamp: now, workoutTime: nil))
        model.endWorkout()
        let record = try #require(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)))
        #expect(record.startAt == origin)
        #expect(record.endAt == now)
        #expect(record.durationSeconds == 30)
        #expect(record.sets.count == 1)
        #expect(record.sets[0].setTime == 30)
        #expect(record.hrSamples.map(\.workoutTime) == [20, 30])
        #expect(record.pauses?.count == 1)
        let pause = try #require(record.pauses?.first)
        #expect(pause.end.timeIntervalSince(pause.start) == 30)
    }

    @Test func pausedAndRestSetsResumeWithoutAddingDuplicateSets() {
        var now = Date(timeIntervalSince1970: 1000)
        let origin = now
        let model = TimerViewModel(sessionStore: makeStore(), nowProvider: { now })
        defer { model.reset() }
        model.start()
        now = origin.addingTimeInterval(30)
        model.captureRestSet()
        now = origin.addingTimeInterval(40)
        model.stop()
        now = origin.addingTimeInterval(50)
        model.endWorkout()
        now = origin.addingTimeInterval(80)
        model.resumeEndedWorkout()
        #expect(model.isTimingRestSet)
        #expect(model.elapsedTime == 40)
        #expect(model.currentSetTime == 10)
        #expect(model.sets.count == 2)
        now = origin.addingTimeInterval(85)
        model.captureSet()
        #expect(model.sets.count == 2)
        #expect(model.sets[1].isRestSet)
        #expect(model.sets[1].setTime == 15)
    }

    @Test func restoresEndedWorkoutThenResumesItsPresetPhase() {
        var now = Date(timeIntervalSince1970: 1000)
        let origin = now
        let store = makeStore()
        let model = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: store, nowProvider: { now })
        let preset = TimerPreset(name: "Intervals", workDuration: 60, restDuration: 30,
                                 numberOfSets: 2, includeCooldown: false, playSound: false)
        model.loadPreset(preset)
        model.startPreset()
        now = origin.addingTimeInterval(25)
        model.endWorkout()
        #expect(store.load()?.endRecovery?.activePreset == preset)
        let restored = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: store, nowProvider: { now })
        defer { model.reset(); restored.reset() }
        now = origin.addingTimeInterval(75)
        restored.resumeEndedWorkout()
        #expect(restored.activePreset == preset)
        #expect(restored.presetPhaseTimeRemaining == 35)
        #expect(restored.sets.isEmpty)
        now = origin.addingTimeInterval(110)
        restored.refreshTiming()
        #expect(restored.presetPhase == .rest)
        #expect(restored.elapsedTime == 60)
        #expect(restored.sets.first?.setTime == 60)
    }

    @Test(arguments: [false, true])
    func cooldownContinuesWithoutDuplicatingPartialSetsOrReportingInterruptedRecovery(pauseBeforeEnding: Bool) throws {
        var now = Date(timeIntervalSince1970: 1000)
        let origin = now
        let model = TimerViewModel(sessionStore: makeStore(), nowProvider: { now })
        defer { model.reset() }
        model.currentHeartRate = { 150 }
        model.start()
        now = origin.addingTimeInterval(60)
        model.captureSet()
        model.end()
        now = origin.addingTimeInterval(90)
        if pauseBeforeEnding {
            model.toggleCooldown()
            now = origin.addingTimeInterval(105)
        }
        model.endWorkout()
        #expect(model.sets.count == 2)
        now = origin.addingTimeInterval(120)
        model.resumeEndedWorkout()
        #expect(model.state == .cooldown)
        #expect(model.cooldownTime == 30)
        #expect(model.sets.count == 1)
        now = origin.addingTimeInterval(150)
        model.refreshTiming()
        #expect(model.cooldownTime == 60)
        #expect(model.sets.count == 2)
        now = origin.addingTimeInterval(210)
        model.refreshTiming()
        #expect(model.state == .idle)
        let record = try #require(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)))
        #expect(record.durationSeconds == 180)
        #expect(record.hrr == nil)
        #expect(record.sets.filter(\.isCooldownSet).count == 2)
    }

    @Test func naturallyCompletedPresetCanContinueAsAnotherWorkSet() {
        var now = Date(timeIntervalSince1970: 1000)
        let origin = now
        let model = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: makeStore(), nowProvider: { now })
        defer { model.reset() }
        model.loadPreset(TimerPreset(workDuration: 10, numberOfSets: 1, includeCooldown: false, playSound: false))
        model.startPreset()
        now = origin.addingTimeInterval(10)
        model.refreshTiming()
        #expect(model.state == .idle)
        now = origin.addingTimeInterval(30)
        model.resumeEndedWorkout()
        #expect(model.state == .running)
        #expect(model.elapsedTime == 10)
        #expect(model.currentSetTime == 0)
        #expect(model.sets.count == 1)
        now = origin.addingTimeInterval(40)
        model.endWorkout()
        #expect(model.frozenElapsedTime == 20)
        #expect(model.sets.count == 2)
        #expect(model.sets[1].setTime == 10)
    }

    private func makeStore() -> ActiveWorkoutSessionStore {
        ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("end-recovery-\(UUID()).json"))
    }
}
