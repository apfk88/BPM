import Foundation
import Testing
@testable import BPM

struct WorkoutStartRecoveryTests {
    @Test @MainActor func includesOnlyValidCurrentSessionMeasurementsAndPersistsThem() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var now = origin.addingTimeInterval(30)
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset(); store.clear() }
        let id = UUID()
        let first = HeartRateSample(value: 100, timestamp: origin, workoutTime: nil)
        var history = [
            HeartRateSample(value: 110, timestamp: origin.addingTimeInterval(10), workoutTime: nil),
            first, first,
            HeartRateSample(value: 90, timestamp: now.addingTimeInterval(-3601), workoutTime: nil),
            HeartRateSample(value: 0, timestamp: origin.addingTimeInterval(-10), workoutTime: nil),
            HeartRateSample(value: 120, timestamp: origin.addingTimeInterval(-5), workoutTime: nil, sensorContactStatus: .notDetected),
            HeartRateSample(value: 130, timestamp: now.addingTimeInterval(60), workoutTime: nil)
        ]
        model.currentSessionMeasurements = { (id, history) }
        #expect(model.recoverableSessionID == id)
        // Asking or cancelling does not mutate workout data.
        #expect(model.state == .idle)
        #expect(!model.hasRestorableSession)
        history.append(HeartRateSample(value: 115, timestamp: origin.addingTimeInterval(20), workoutTime: nil))
        model.start(includingPreviousMeasurementsFrom: id)
        #expect(model.elapsedTime == 30)
        #expect(model.currentSetTime == 30)
        #expect(store.load()?.heartRateSamples.map(\.workoutTime) == [0, 10, 20])
        #expect(store.load()?.workoutStartedAt == origin)
        model.start(includingPreviousMeasurementsFrom: id) // Repeated tap must not import twice.
        #expect(store.load()?.heartRateSamples.count == 3)
        now = origin.addingTimeInterval(40)
        model.recordHeartRateSample(HeartRateSample(value: 125, timestamp: now, workoutTime: nil))
        #expect(store.load()?.heartRateSamples.count == 4)
        #expect(store.load()?.heartRateSamples.last?.workoutTime == 40)
        model.stop()
        let restored = TimerViewModel(sessionStore: store, nowProvider: { now })
        #expect(restored.elapsedTime == 40)
        #expect(restored.avgBPMForCurrentSet() == model.avgBPMForCurrentSet())
        restored.reset()
    }

    @Test @MainActor func startsNowWithoutImportAndNeverReusesPreResetMeasurements() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var now = origin.addingTimeInterval(30)
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset(); store.clear() }
        let id = UUID()
        var history = [HeartRateSample(value: 100, timestamp: origin, workoutTime: nil)]
        model.currentSessionMeasurements = { (id, history) }
        model.start()
        #expect(model.elapsedTime == 0)
        #expect(store.load()?.heartRateSamples.isEmpty == true)
        #expect(store.load()?.workoutStartedAt == now)
        model.reset()
        #expect(model.recoverableSessionID == nil)
        now = now.addingTimeInterval(5)
        history.append(HeartRateSample(value: 120, timestamp: now, workoutTime: nil))
        now = now.addingTimeInterval(10)
        model.start(includingPreviousMeasurementsFrom: id)
        #expect(model.elapsedTime == 10)
        #expect(store.load()?.heartRateSamples.map(\.value) == [120])
    }

    @Test @MainActor func completedWorkoutWithoutSetsCannotBeRecoveredAgain() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var now = origin
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset(); store.clear() }
        let id = UUID()
        model.currentSessionMeasurements = {
            (id, [HeartRateSample(value: 100, timestamp: origin.addingTimeInterval(5), workoutTime: nil)])
        }
        model.start()
        now = origin.addingTimeInterval(10)
        model.stopAndComplete()
        #expect(model.recoverableSessionID == nil)
    }

    @Test @MainActor func changedOrDisconnectedSessionCannotImportAlertHistory() {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset(); store.clear() }
        let oldID = UUID()
        model.currentSessionMeasurements = {
            (UUID(), [HeartRateSample(value: 100, timestamp: now.addingTimeInterval(-10), workoutTime: nil)])
        }
        model.start(includingPreviousMeasurementsFrom: oldID)
        #expect(model.elapsedTime == 0)
        #expect(store.load()?.heartRateSamples.isEmpty == true)
    }
}

extension WorkoutStartRecoveryTests {
    @Test @MainActor func emptyBufferAndPauseResumeDoNotImportMoreReadings() {
        var now = Date(timeIntervalSince1970: 1000)
        let store = ActiveWorkoutSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = TimerViewModel(sessionStore: store, nowProvider: { now })
        defer { model.reset(); store.clear() }
        let id = UUID()
        var history: [HeartRateSample] = []
        model.currentSessionMeasurements = { (id, history) }
        #expect(model.recoverableSessionID == nil)
        let first = HeartRateSample(value: 100, timestamp: now.addingTimeInterval(-20), workoutTime: nil)
        history = [first]
        model.start(includingPreviousMeasurementsFrom: id)
        model.recordHeartRateSample(first)
        #expect(store.load()?.heartRateSamples.count == 1)
        model.stop()
        now = now.addingTimeInterval(30)
        history.append(HeartRateSample(value: 120, timestamp: now, workoutTime: nil))
        model.start(includingPreviousMeasurementsFrom: id)
        #expect(model.elapsedTime == 20)
        #expect(store.load()?.heartRateSamples.count == 1)
        now = now.addingTimeInterval(10)
        model.refreshTiming()
        #expect(model.elapsedTime == 30)
    }
}
