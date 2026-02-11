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
        #expect(reloaded.workouts.contains(where: { $0.id == record.id }))
        #expect(reloaded.workouts.first(where: { $0.id == record.id })?.hrr == record.hrr)
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

    @Test func iCloudSyncCompactsPayloadWhenWorkoutDataIsLarge() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(365, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let sampleCount = 8_000
        let workoutCount = 6
        var expectedIDs = Set<UUID>()

        for index in 0..<workoutCount {
            let record = sampleWorkout(
                startOffset: TimeInterval(-(index + 1) * 1_200),
                duration: 1_200,
                hrSampleCount: sampleCount
            )
            expectedIDs.insert(record.id)
            store.saveWorkout(record)
        }

        var waitCycles = 0
        while waitCycles < 120 {
            let savedIDs = Set(store.workouts.map(\.id))
            if expectedIDs.isSubset(of: savedIDs) {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            waitCycles += 1
        }

        let savedIDs = Set(store.workouts.map(\.id))
        #expect(expectedIDs.isSubset(of: savedIDs))
        #expect(store.workouts.contains(where: { expectedIDs.contains($0.id) && $0.hrSamples.count == sampleCount }))

        var syncedData: Data?
        waitCycles = 0
        while syncedData == nil && waitCycles < 50 {
            syncedData = iCloudStore.data(forKey: WorkoutICloudKey.data)
            if syncedData != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
            waitCycles += 1
        }

        guard let syncedData else {
            Issue.record("Expected iCloud workout payload")
            return
        }

        #expect(syncedData.count <= 1_048_576)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let syncedRecords = try decoder.decode([WorkoutRecord].self, from: syncedData)
        #expect(!syncedRecords.isEmpty)
        #expect(syncedRecords.count <= workoutCount)
        #expect(syncedRecords.allSatisfy { $0.hrSamples.count <= 1_200 })
    }

    private func sampleWorkout(
        startOffset: TimeInterval,
        duration: TimeInterval,
        hrSampleCount: Int = 0
    ) -> WorkoutRecord {
        let start = Date().addingTimeInterval(startOffset)
        let end = start.addingTimeInterval(duration)
        let hrSamples: [WorkoutHeartRateSample]
        if hrSampleCount > 0 {
            let interval = max(duration / Double(hrSampleCount), 0.2)
            hrSamples = (0..<hrSampleCount).map { index in
                let elapsed = Double(index) * interval
                return WorkoutHeartRateSample(
                    timestamp: start.addingTimeInterval(elapsed),
                    bpm: 120 + (index % 40),
                    workoutTime: elapsed
                )
            }
        } else {
            hrSamples = []
        }

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
            hrSamples: hrSamples,
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
