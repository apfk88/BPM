import Foundation
import Testing
@testable import BPM

struct HRVAccuracyTests {
    @Test func rmssdMatchesIndependentReferenceAndRejectsInvalidInputs() {
        let result = HRVCalculator.rmssd([1000, 1020, 990, 1010])
        #expect(abs((result ?? 0) - sqrt(1700.0 / 3)) < 0.000001)
        #expect(HRVCalculator.rmssd([1000, 1000, 1000]) == 0)
        #expect(HRVCalculator.rmssd([1000]) == nil)
        #expect(HRVCalculator.rmssd([0, 1000]) == nil)
        #expect(HRVCalculator.rmssd([.nan, 1000]) == nil)
        #expect(HRVCalculator.rmssd([.infinity, 1000]) == nil)
    }

    @Test @MainActor func fullRecordingSurvivesRollingBufferPruningAndDelayedCompletion() {
        let clock = TestMeasurementTime()
        let model = HRVMeasurementViewModel(ticksProvider: { clock.seconds }, nowProvider: { clock.date })
        let stream = UUID()
        var history: [RRInterval] = [RRInterval(value: 500, timestamp: clock.date, receivedTicks: 0)]
        model.supportsRRIntervals = { true }
        model.currentHeartRate = { 60 }
        model.currentRRStreamID = { stream }
        model.getRRIntervals = { history }
        model.startMeasurement()
        for index in 1...119 {
            clock.seconds = Double(index)
            history = [RRInterval(value: index.isMultiple(of: 2) ? 1010 : 990, timestamp: clock.date, receivedTicks: clock.seconds)]
            model.updateMeasurement()
            model.updateMeasurement() // A repeated read must not duplicate intervals.
        }
        clock.seconds = 120
        history.append(RRInterval(value: 1010, timestamp: clock.date, receivedTicks: 120))
        history.append(RRInterval(value: 1500, timestamp: clock.date, receivedTicks: 121))
        clock.seconds = 130
        model.updateMeasurement()
        #expect(model.state == .completed)
        #expect(abs((model.hrvValue ?? 0) - 20) < 0.000001)
        let record = model.hrvRecord()
        #expect(record?.rrIntervalsMs.count == 120)
        #expect(record?.durationSeconds == 120)
        #expect(record?.endAt == clock.origin.addingTimeInterval(120))
        model.reset()
        model.stopLiveHeartRateUpdates()
    }

    @Test @MainActor func noBPMFallbackAndNoResultAfterStreamChange() {
        let clock = TestMeasurementTime()
        let model = HRVMeasurementViewModel(ticksProvider: { clock.seconds }, nowProvider: { clock.date })
        var stream = UUID()
        model.supportsRRIntervals = { true }
        model.currentHeartRate = { 65 }
        model.currentRRStreamID = { stream }
        model.getRRIntervals = { [] }
        model.startMeasurement()
        clock.seconds = 6
        model.updateMeasurement()
        #expect(model.hasError)
        #expect(model.hrvValue == nil)
        #expect(model.hrvRecord() == nil)
        model.startMeasurement()
        stream = UUID()
        model.updateMeasurement()
        #expect(model.hasError)
        #expect(model.hrvRecord() == nil)
        model.stopLiveHeartRateUpdates()
    }

    @Test func qualityRejectsArtifactsAndIncompleteCoverage() {
        var beats = (1...120).map { RRInterval(value: 1000, timestamp: Date(), receivedTicks: Double($0)) }
        #expect(HRVCalculator.qualityError(intervals: beats, start: 0, duration: 120) == nil)
        beats[60] = RRInterval(value: 1600, timestamp: Date(), receivedTicks: 61)
        #expect(HRVCalculator.qualityError(intervals: beats, start: 0, duration: 120) != nil)
        beats[60] = RRInterval(value: 1000, timestamp: Date(), receivedTicks: 61)
        beats.removeSubrange(40...60)
        #expect(HRVCalculator.qualityError(intervals: beats, start: 0, duration: 120) != nil)
    }

    @Test func parserRejectsTruncatedPacketsAndPreservesRRPrecisionAndOrder() {
        for bytes: [UInt8] in [[], [0], [1, 60], [8, 60, 0], [16, 60], [16, 60, 0], [16, 60, 0, 4, 1], [16, 60, 0, 0]] {
            #expect(HeartRateBluetoothManager.parseHeartRateData(from: Data(bytes)).heartRate == nil)
        }
        let parsed = HeartRateBluetoothManager.parseHeartRateData(from: Data([0x19, 0x2c, 1, 0, 0, 0, 4, 1, 4]))
        #expect(parsed.heartRate == 300)
        #expect(parsed.rrIntervals == [1000, 1000.9765625])
        let sliced = Data([99, 0, 60]).dropFirst()
        #expect(HeartRateBluetoothManager.parseHeartRateData(from: sliced).heartRate == 60)
    }

    @Test @MainActor func poorContactAndZeroHRNeverEnterRRHistory() {
        let manager = HeartRateBluetoothManager()
        let original = manager.rrStreamID
        manager.receiveHeartRateMeasurement(HeartRateMeasurementData(heartRate: 60, sensorContactStatus: .notDetected, hasRRIntervals: true, rrIntervals: [1000]))
        #expect(manager.rrIntervals.isEmpty)
        #expect(manager.rrStreamID != original)
        manager.receiveHeartRateMeasurement(HeartRateMeasurementData(heartRate: 0, sensorContactStatus: .detected, hasRRIntervals: true, rrIntervals: [1000]))
        #expect(manager.rrIntervals.isEmpty)
        #expect(manager.freshHeartRate == nil)
    }
}

@MainActor
private final class TestMeasurementTime {
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    var seconds: Double = 0
    var date: Date { origin.addingTimeInterval(seconds) }
}

struct WorkoutAccuracyTests {
    @MainActor private func makeModel(_ clock: TestMeasurementTime, countdown: Double = 0) -> TimerViewModel {
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-\(UUID()).json"))
        return TimerViewModel(presetStartCountdownDuration: countdown, sessionStore: store, nowProvider: { clock.date })
    }

    @MainActor private func preset(cooldown: Bool = false) -> TimerPreset {
        TimerPreset(workDuration: 10, restDuration: 5, numberOfSets: 3, includeCooldown: cooldown, playSound: false)
    }

    @Test @MainActor func partialPresetStopRecordsOnlyActualTime() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.loadPreset(preset())
        model.startPreset()
        clock.seconds = 4.125
        model.stopPresetAndComplete()
        #expect(model.sets.count == 1)
        #expect(model.sets.first?.setTime == 4.125)
        #expect(model.frozenElapsedTime == 4.125)
        #expect(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))?.durationSeconds == 4.125)
        model.reset()
    }

    @Test @MainActor func partialRestStopRecordsOnlyActualTime() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.loadPreset(preset())
        model.startPreset()
        clock.seconds = 12
        model.stopPresetAndComplete()
        #expect(model.sets.map(\.setTime) == [10, 2])
        #expect(model.sets.map(\.totalTime) == [10, 12])
        model.reset()
    }

    @Test @MainActor func delayedPrestartAndAllPhasesUseOriginalDeadlinesWithoutDuplicateFinalSet() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock, countdown: 5)
        model.loadPreset(preset())
        model.startPreset()
        clock.seconds = 55
        model.refreshTiming()
        #expect(model.state == .idle)
        #expect(model.sets.map(\.setTime) == [10, 5, 10, 5, 10])
        #expect(model.sets.map(\.totalTime) == [10, 15, 25, 30, 40])
        #expect(model.frozenElapsedTime == 40)
        let record = model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
        #expect(record?.startAt == clock.origin.addingTimeInterval(5))
        #expect(record?.endAt == clock.origin.addingTimeInterval(45))
        #expect(record?.durationSeconds == 40)
        #expect(record?.sets.allSatisfy { $0.avgBpm == nil } == true)
        model.refreshTiming()
        #expect(model.sets.count == 5)
        model.reset()
    }

    @Test @MainActor func pausePreservesEarlierSetHeartRatesAndRealStartTime() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.start()
        clock.seconds = 1
        model.recordHeartRateSample(HeartRateSample(value: 110, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 10
        model.captureSet()
        model.stop()
        clock.seconds = 110
        model.start()
        clock.seconds = 111
        model.recordHeartRateSample(HeartRateSample(value: 150, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 120
        model.captureSet()
        model.stopAndComplete()
        #expect(model.sets.map(\.setTime) == [10, 10])
        #expect(model.avgBPMForSet(model.sets[0]) == 110)
        #expect(model.avgBPMForSet(model.sets[1]) == 150)
        let record = model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
        #expect(record?.startAt == clock.origin)
        #expect(record?.endAt == clock.date)
        #expect(record?.durationSeconds == 20)
        #expect(record?.pauses == [WorkoutPause(start: clock.origin.addingTimeInterval(10), end: clock.origin.addingTimeInterval(110))])
        #expect(record?.hrSamples.count == 2)
        #expect(record?.zones.reduce(0) { $0 + $1.duration } == 6)
        model.reset()
    }

    @Test @MainActor func cooldownTotalsStayCorrectAcrossPauseAndLateCallbacks() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.loadPreset(preset(cooldown: true))
        model.startPreset()
        clock.seconds = 70 // Work ends at 40; 30 seconds of cooldown.
        model.refreshTiming()
        model.toggleCooldown()
        clock.seconds = 170
        model.toggleCooldown()
        clock.seconds = 310 // Late by 50 seconds; resume must not restart 120 seconds.
        model.refreshTiming()
        #expect(model.state == .idle)
        #expect(model.cooldownTime == 120)
        #expect(model.sets.suffix(2).map(\.setTime) == [60, 60])
        #expect(model.sets.suffix(2).map(\.totalTime) == [100, 160])
        #expect(model.heartRateRecovery == nil)
        let record = model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
        #expect(record?.durationSeconds == 160)
        #expect(record?.endAt == clock.origin.addingTimeInterval(260))
        model.reset()
    }

    @Test @MainActor func earlyCooldownStopIsNotTwoMinuteRecovery() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.currentHeartRate = { 140 }
        model.start()
        clock.seconds = 10
        model.captureSet()
        model.end()
        clock.seconds = 85
        model.stopCooldownAndComplete()
        #expect(model.sets.suffix(2).map(\.setTime) == [60, 15])
        #expect(model.sets.suffix(2).map(\.totalTime) == [70, 85])
        #expect(model.heartRateRecovery == nil)
        #expect(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))?.durationSeconds == 85)
        model.reset()
    }

    @Test @MainActor func stoppingDuringPrestartLeavesAnIdleEmptySession() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock, countdown: 5)
        model.loadPreset(preset())
        model.startPreset()
        clock.seconds = 2
        model.stopPresetAndComplete()
        #expect(model.state == .idle)
        #expect(!model.hasRestorableSession)
        #expect(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)) == nil)
        model.reset()
    }

    @Test @MainActor func pausedPrestartDoesNotCountPausedTime() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock, countdown: 5)
        model.loadPreset(preset())
        model.startPreset()
        clock.seconds = 2
        model.pausePreset()
        clock.seconds = 102
        model.refreshTiming()
        #expect(model.presetPhaseTimeRemaining == 3)
        model.startPreset()
        clock.seconds = 108
        model.stopPresetAndComplete()
        #expect(model.sets.first?.setTime == 3)
        #expect(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))?.startAt == clock.origin.addingTimeInterval(105))
        model.reset()
    }

    @Test @MainActor func restoredPresetCompletesOverduePhasesAndCooldownOnce() {
        let clock = TestMeasurementTime()
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("restore-accuracy-\(UUID()).json"))
        var original: TimerViewModel? = TimerViewModel(presetStartCountdownDuration: 0, sessionStore: store, nowProvider: { clock.date })
        original?.loadPreset(preset(cooldown: true))
        original?.startPreset()
        clock.seconds = 2
        original?.recordHeartRateSample(HeartRateSample(value: 150, timestamp: clock.date, workoutTime: nil))
        original = nil
        clock.seconds = 300
        let restored = TimerViewModel(sessionStore: store, nowProvider: { clock.date })
        #expect(restored.state == .idle)
        #expect(restored.sets.map(\.totalTime) == [10, 15, 25, 30, 40, 100, 160])
        let record = restored.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
        #expect(record?.durationSeconds == 160)
        #expect(record?.hrSamples.count == 1)
        #expect(record?.endAt == clock.origin.addingTimeInterval(160))
        #expect(record?.hrr == nil)
        restored.reset()
    }

    @Test @MainActor func newManualWorkoutDoesNotInheritPreviousDuration() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.start()
        clock.seconds = 10
        model.captureSet()
        model.stopAndComplete()
        clock.seconds = 20
        model.start()
        clock.seconds = 23
        model.captureSet()
        model.stopAndComplete()
        #expect(model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))?.durationSeconds == 3)
        model.reset()
    }

    @Test @MainActor func pausedAndCompletedWorkoutsRejectIncomingSamples() {
        let clock = TestMeasurementTime()
        let model = makeModel(clock)
        model.start()
        clock.seconds = 0.1
        model.recordHeartRateSample(HeartRateSample(value: 100, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 0.2
        model.recordHeartRateSample(HeartRateSample(value: 180, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 0.3
        model.stop()
        clock.seconds = 10
        model.recordHeartRateSample(HeartRateSample(value: 200, timestamp: clock.date, workoutTime: nil))
        model.captureSet()
        model.stopAndComplete()
        model.recordHeartRateSample(HeartRateSample(value: 210, timestamp: clock.date, workoutTime: nil))
        let record = model.workoutRecord(zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
        #expect(record?.maxHr == 180)
        #expect(record?.hrSamples.map(\.bpm) == [100, 180])
        #expect(abs((record?.durationSeconds ?? 0) - 0.3) < 0.00001)
        model.reset()
    }
}
