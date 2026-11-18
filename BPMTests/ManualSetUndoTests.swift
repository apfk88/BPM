import Foundation
import Testing
@testable import BPM

@MainActor
struct ManualSetUndoTests {
    @Test(arguments: [false, true])
    func undoDuringWorkReturnsToThePreviousWorkOrRestSet(fromRest: Bool) throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        var now = origin
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let timer = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { timer.reset() }
        timer.start()
        #expect(timer.undoableSetChange == nil)
        now = origin.addingTimeInterval(20)
        if fromRest { timer.captureRestSet() } else { timer.captureSet() }
        now = origin.addingTimeInterval(24)
        timer.recordHeartRateSample(HeartRateSample(value: 120, timestamp: now, workoutTime: nil))
        let earlierChange = try #require(timer.undoableSetChange)
        now = origin.addingTimeInterval(30)
        timer.captureSet()
        let accidentalTap = try #require(timer.undoableSetChange)
        now = origin.addingTimeInterval(34)
        timer.recordHeartRateSample(HeartRateSample(value: 150, timestamp: now, workoutTime: nil))
        let before = try #require(store.load())

        timer.undoSetChange(id: earlierChange.id)
        #expect(timer.undoableSetChange?.id == accidentalTap.id)
        timer.undoSetChange(id: accidentalTap.id)
        #expect(timer.state == .running)
        #expect(timer.elapsedTime == 34)
        #expect(timer.currentSetTime == 14)
        #expect(timer.isTimingRestSet == fromRest)
        #expect(timer.minBPMForCurrentSet() == 120)
        #expect(timer.maxBPMForCurrentSet() == 150)
        let after = try #require(store.load())
        #expect(after.heartRateSamples == before.heartRateSamples)
        #expect(after.startTime == before.startTime)
        #expect(after.pauses == before.pauses)
        now = origin.addingTimeInterval(40)
        timer.endWorkout()
        #expect(timer.undoableSetChange == nil)
        let saved = try #require(timer.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)))
        #expect(saved.durationSeconds == 40)
        #expect(saved.sets.map(\.label) == ["1", fromRest ? "1R" : "2"])
        #expect(saved.sets.map(\.setTime) == [20, 20])
        #expect(saved.hrSamples.map(\.workoutTime) == [24, 34])
    }

    @Test(arguments: [false, true])
    func undoRestAfterRelaunchPreservesPauseAndAnyPreviouslyMarkedWorkSet(markWorkFirst: Bool) throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        var now = origin
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let timer = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { timer.reset() }
        timer.start()
        now = origin.addingTimeInterval(30)
        if markWorkFirst { timer.captureSet() }
        timer.captureRestSet()
        let restChange = try #require(timer.undoableSetChange)
        now = origin.addingTimeInterval(45)
        timer.stop()
        now = origin.addingTimeInterval(60)
        let restored = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { restored.reset() }
        restored.undoSetChange(id: restChange.id)
        #expect(restored.state == .paused)
        #expect(!restored.isTimingRestSet)
        #expect(restored.elapsedTime == 45)
        #expect(restored.currentSetTime == (markWorkFirst ? 15 : 45))
        #expect(restored.sets.map(\.setNumber) == (markWorkFirst ? [1] : []))
        restored.start()
        now = origin.addingTimeInterval(65)
        restored.captureSet()
        #expect(restored.sets.last?.setNumber == (markWorkFirst ? 2 : 1))
        #expect(restored.sets.last?.setTime == (markWorkFirst ? 20 : 50))
        #expect(restored.sets.last?.totalTime == 50)
    }
}
