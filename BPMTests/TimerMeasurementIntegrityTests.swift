import Foundation
import Testing
@testable import BPM

@MainActor
struct TimerMeasurementIntegrityTests {
    @Test func recoverableHistoryDurationMatchesTheMeasurementsActuallyIncluded() throws {
        let clock = Clock()
        clock.seconds = 4_000
        let model = model(clock: clock, profile: profile)
        let sessionID = UUID()
        let samples: [HeartRateSample] = [
            .init(value: 100, timestamp: clock.date.addingTimeInterval(-3_601), workoutTime: nil),
            .init(value: 0, timestamp: clock.date.addingTimeInterval(-500), workoutTime: nil),
            .init(value: 120, timestamp: clock.date.addingTimeInterval(-400), workoutTime: nil, sensorContactStatus: .notDetected),
            .init(value: 125, timestamp: clock.date.addingTimeInterval(-123), workoutTime: nil),
            .init(value: 130, timestamp: clock.date.addingTimeInterval(-20), workoutTime: nil),
            .init(value: 140, timestamp: clock.date.addingTimeInterval(1), workoutTime: nil)
        ]
        model.currentSessionMeasurements = { (sessionID, samples) }
        #expect(model.recoverableHistoryDuration(for: UUID()) == nil)
        let duration = try #require(model.recoverableHistoryDuration(for: sessionID))
        #expect(duration == 123)
        model.start(includingPreviousMeasurementsFrom: sessionID)
        #expect(model.elapsedTime == duration)
        model.reset()
        #expect(model.recoverableHistoryDuration(for: sessionID) == nil)
    }

    @Test func signalLossReachesWorkoutWhenManagerHasNoSampleHistory() throws {
        let clock = Clock()
        let model = model(clock: clock, profile: profile)
        model.start()
        model.recordHeartRateSample(.init(value: 100, timestamp: clock.date, workoutTime: nil))
        // The active session can outlive a manager, for example after app restoration.
        let newManager = HeartRateBluetoothManager()
        model.observeHeartRate(from: newManager)
        clock.seconds = 1
        newManager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([4, 100])))
        clock.seconds = 2
        model.stopAndComplete()
        let record = try #require(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200)))
        #expect(record.hrSamples.first?.invalidatedAt == clock.origin.addingTimeInterval(1))
        #expect(record.zones.reduce(0) { $0 + $1.duration } == 1)
        model.reset()
    }

    @Test func knownContactLossStopsIntegrationAndSurvivesPersistence() throws {
        let clock = Clock()
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-loss-\(UUID()).json"))
        let model = TimerViewModel(sessionStore: store, nowProvider: { clock.date },
                                  soundCueHandler: { _ in }, energyProfileProvider: profile)
        let manager = HeartRateBluetoothManager()
        model.observeHeartRate(from: manager)
        model.start()
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0, 100])))
        clock.seconds = 1
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([4, 100])))
        #expect(store.load()?.heartRateSamples.first?.invalidatedAt == clock.date)
        clock.seconds = 2
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0, 200])))
        clock.seconds = 3
        model.stopAndComplete()

        let record = try #require(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200)))
        #expect(record.avgHr == 150)
        #expect(record.hrSamples.map(\.bpm) == [100, 200])
        #expect(record.hrSamples.first?.invalidatedAt == clock.origin.addingTimeInterval(1))
        #expect(record.zones.reduce(0) { $0 + $1.duration } == 2)
        #expect(model.chartDataPoints().map(\.segment) == [0, 1])
        #expect(record.chartDataPoints.map(\.segment) == [0, 1])
        let gap = WorkoutShareSnapshot(record: record, range: .init(start: 1.1, end: 1.9, duration: 3))
        #expect(gap.average == nil)
        #expect(gap.points.isEmpty)

        let restored = TimerViewModel(sessionStore: store, nowProvider: { clock.date },
                                     soundCueHandler: { _ in }, energyProfileProvider: profile)
        #expect(restored.workoutRecord(zoneConfig: .init(maxHeartRate: 200))?.hrSamples.first?.invalidatedAt == clock.origin.addingTimeInterval(1))
        #expect(restored.avgHeartRate == 150)
        restored.reset()
        model.reset()
    }

    @Test func oldSamplesDecodeWithoutLossMetadata() throws {
        let raw = Data(#"{"timestamp":0,"bpm":120,"workoutTime":0}"#.utf8)
        #expect(try JSONDecoder().decode(WorkoutHeartRateSample.self, from: raw).invalidatedAt == nil)
        let sessionRaw = Data(#"{"timestamp":0,"value":120,"workoutTime":0}"#.utf8)
        #expect(try JSONDecoder().decode(PersistedHeartRateSample.self, from: sessionRaw).invalidatedAt == nil)
    }

    private final class Clock {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var seconds: TimeInterval = 0
        var date: Date { origin.addingTimeInterval(seconds) }
    }

    private func profile() -> UserEnergyProfile {
        UserEnergyProfile(weightKg: 80, ageYears: 40, sexAtBirth: .male, heightCm: 180,
                          restHeartRate: nil, maxHeartRate: nil, vo2Max: nil,
                          rmrKcalPerDay: nil, bodyFatPercent: nil, medsAffectingHr: false)
    }

    private func model(clock: Clock, profile: @escaping () -> UserEnergyProfile) -> TimerViewModel {
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("measurement-integrity-\(UUID()).json"))
        return TimerViewModel(sessionStore: store, nowProvider: { clock.date },
                              soundCueHandler: { _ in }, energyProfileProvider: profile)
    }

    @Test func prePauseReadingCannotContributeAfterResume() {
        let clock = Clock()
        let model = model(clock: clock, profile: profile)
        model.start()
        clock.seconds = 9
        model.recordHeartRateSample(.init(value: 100, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 10
        model.stop()
        clock.seconds = 110
        model.start()
        clock.seconds = 111
        model.recordHeartRateSample(.init(value: 160, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 112
        model.stopAndComplete()
        // One covered second on each side, with no measurement for the first second after resume.
        #expect(model.avgHeartRate == 130)
        #expect(model.timeInZones(config: .init(maxHeartRate: 200)).reduce(0) { $0 + $1.duration } == 2)
        model.reset()
    }

    @Test func wholeSessionSummaryIncludesRecordedCooldown() throws {
        let clock = Clock()
        let model = model(clock: clock, profile: profile)
        model.start()
        model.recordHeartRateSample(.init(value: 160, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 3
        model.end()
        model.recordHeartRateSample(.init(value: 100, timestamp: clock.date, workoutTime: nil))
        clock.seconds = 6
        model.stopCooldownAndComplete()
        let record = try #require(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200)))
        #expect(record.durationSeconds == 6)
        #expect(record.avgHr == 130)
        #expect(record.minHr == 100)
        #expect(record.maxHr == 160)
        model.reset()
    }

    @Test func savedCaloriesUseCurrentSamplesAndProfileWithoutWaitingForBackgroundQueue() throws {
        let clock = Clock()
        var currentProfile = profile()
        let model = model(clock: clock, profile: { currentProfile })
        model.start()
        for second in 0...20 {
            clock.seconds = Double(second)
            model.recordHeartRateSample(.init(value: 150, timestamp: clock.date, workoutTime: nil))
        }
        clock.seconds = 21
        model.stopAndComplete()
        let saved = try #require(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200)))
        let kcalPerMinute = (-55.0969 + 0.6309 * 150 + 0.1988 * 80 + 0.2017 * 40) / 4.184
        #expect(abs(try #require(saved.caloriesTotal) - kcalPerMinute * 21 / 60) < 0.01)
        // A queued estimate from the earlier complete profile cannot populate this record.
        currentProfile.sexAtBirth = nil
        #expect(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200))?.caloriesTotal == nil)
        model.reset()
        guard case .disabled = model.caloriesStatus else {
            Issue.record("Reset must clear the last workout's calorie value immediately")
            return
        }
    }

    @Test func calorieIntegrationRetainsExactPauseBoundaryAndOriginalStartDate() throws {
        let clock = Clock()
        let model = model(clock: clock, profile: profile)
        model.start()
        for second in 0...9 {
            clock.seconds = Double(second)
            model.recordHeartRateSample(.init(value: 150, timestamp: clock.date, workoutTime: nil))
        }
        clock.seconds = 9.5
        model.stop()
        clock.seconds = 109.5
        model.start()
        for second in 110...120 {
            clock.seconds = Double(second)
            model.recordHeartRateSample(.init(value: 150, timestamp: clock.date, workoutTime: nil))
        }
        clock.seconds = 121
        model.stopAndComplete()
        let saved = try #require(model.workoutRecord(zoneConfig: .init(maxHeartRate: 200)))
        let kcalPerMinute = (-55.0969 + 0.6309 * 150 + 0.1988 * 80 + 0.2017 * 40) / 4.184
        #expect(abs(try #require(saved.caloriesTotal) - kcalPerMinute * 20.5 / 60) < 0.01)
        #expect(saved.startAt == clock.origin)
        #expect(saved.durationSeconds == 21)
        model.reset()
    }
}
