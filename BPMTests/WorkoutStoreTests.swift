import Foundation
import Testing
@testable import BPM

struct WorkoutStoreTests {
    @Test func savesAndLoadsWorkouts() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let record = sampleWorkout(startOffset: -120, duration: 60)
        store.saveWorkout(record)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let reloaded = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(reloaded.workouts.count == 1)
        #expect(reloaded.workouts.first?.id == record.id)
        #expect(reloaded.workouts.first?.hrr == record.hrr)
    }

    @Test func retentionPrunesOldWorkouts() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(1, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let oldRecord = sampleWorkout(startOffset: -172800, duration: 60)
        store.saveWorkout(oldRecord)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(store.workouts.isEmpty)
    }

    @Test func decodesLegacyWorkoutWithoutHealthKitFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString

        let json = """
        {
          "id":"\(id)",
          "schemaVersion":1,
          "title":"Legacy",
          "startAt":"\(now)",
          "endAt":"\(now)",
          "durationSeconds":60,
          "avgHr":120,
          "maxHr":150,
          "minHr":100,
          "hrv":null,
          "caloriesTotal":50,
          "caloriesActive":40,
          "hrSamples":[],
          "zones":[],
          "sets":[],
          "notes":null,
          "source":"phone",
          "appVersion":"1.0 (1)",
          "createdAt":"\(now)",
          "updatedAt":"\(now)"
        }
        """

        let data = try #require(json.data(using: .utf8))
        let decoded = try decoder.decode(WorkoutRecord.self, from: data)
        #expect(decoded.healthKitWorkoutUUID == nil)
        #expect(decoded.healthKitSyncedAt == nil)
        #expect(decoded.healthKitLastError == nil)
        #expect(decoded.hrr == nil)
    }

    @Test func saveWorkoutUpdatesHealthKitFieldsOnExistingRecord() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let baseRecord = sampleWorkout(startOffset: -120, duration: 60)
        store.saveWorkout(baseRecord)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let workoutUUID = UUID()
        let syncedRecord = baseRecord.updatingHealthKitSync(
            workoutUUID: workoutUUID,
            syncedAt: Date(),
            lastError: nil
        )
        store.saveWorkout(syncedRecord)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(store.workouts.count == 1)
        #expect(store.workouts.first?.healthKitWorkoutUUID == workoutUUID)
        #expect(store.workouts.first?.healthKitLastError == nil)
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
            hrr: 18,
            caloriesTotal: 120,
            caloriesActive: 90,
            hrSamples: [],
            zones: [],
            sets: [],
            notes: nil,
            source: "phone",
            appVersion: "1.0 (1)",
            healthKitWorkoutUUID: nil,
            healthKitSyncedAt: nil,
            healthKitLastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func resetICloudStore() -> NSUbiquitousKeyValueStore {
        let store = NSUbiquitousKeyValueStore.default
        store.removeObject(forKey: WorkoutICloudKey.data)
        store.removeObject(forKey: WorkoutICloudKey.updatedAt)
        store.synchronize()
        return store
    }
}
