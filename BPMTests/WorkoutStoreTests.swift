import Foundation
import Testing
@testable import BPM

struct WorkoutStoreTests {
    @Test func savesAndLoadsWorkouts() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults)
        let record = sampleWorkout(startOffset: -120, duration: 60)
        store.saveWorkout(record)
        try await Task.sleep(nanoseconds: 200_000_000)

        let reloaded = WorkoutStore(storeURL: tempURL, userDefaults: defaults)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(reloaded.workouts.count == 1)
        #expect(reloaded.workouts.first?.id == record.id)
    }

    @Test func retentionPrunesOldWorkouts() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(1, forKey: WorkoutDefaultsKey.retentionDays)

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults)
        let oldRecord = sampleWorkout(startOffset: -172800, duration: 60)
        store.saveWorkout(oldRecord)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.workouts.isEmpty)
    }

    private func sampleWorkout(startOffset: TimeInterval, duration: TimeInterval) -> WorkoutRecord {
        let start = Date().addingTimeInterval(startOffset)
        let end = start.addingTimeInterval(duration)
        return WorkoutRecord(
            id: UUID(),
            schemaVersion: WorkoutRecord.schemaVersion,
            title: "Test Session",
            startAt: start,
            endAt: end,
            durationSeconds: duration,
            avgHr: 140,
            maxHr: 170,
            minHr: 110,
            hrv: nil,
            caloriesTotal: 120,
            caloriesActive: 90,
            hrSamples: [],
            zones: [],
            sets: [],
            notes: nil,
            source: "phone",
            appVersion: "1.0 (1)",
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
