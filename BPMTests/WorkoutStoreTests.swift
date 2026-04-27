import Foundation
import Testing
@testable import BPM

@Suite(.serialized)
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

    @Test func firstLaunchWithoutLocalOrRemoteDoesNotPublishEmptyICloudHistory() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        _ = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(iCloudStore.data(forKey: WorkoutICloudKey.data) == nil)
        #expect(iCloudStore.object(forKey: WorkoutICloudKey.updatedAt) == nil)
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

    @Test func saveWorkoutPersistsNotesAcrossReload() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let record = sampleWorkout(
            startOffset: -120,
            duration: 60,
            notes: "Easy aerobic day. Felt smooth."
        )

        store.saveWorkout(record)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(store.workouts.first(where: { $0.id == record.id })?.notes == "Easy aerobic day. Felt smooth.")

        let reloaded = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(reloaded.workouts.first(where: { $0.id == record.id })?.notes == "Easy aerobic day. Felt smooth.")
    }

    @Test func workoutRecordNormalizesNotesWhitespace() throws {
        let viewModel = TimerViewModel()
        viewModel.currentHeartRate = { 142 }
        viewModel.start()
        viewModel.stopAndComplete()
        let zoneConfig = HeartRateZoneConfig(maxHeartRate: 190)

        let trimmedRecord = try #require(
            viewModel.workoutRecord(
                zoneConfig: zoneConfig,
                title: "Session",
                notes: "  Focused threshold work.  "
            )
        )
        #expect(trimmedRecord.notes == "Focused threshold work.")

        let emptyRecord = try #require(
            viewModel.workoutRecord(
                zoneConfig: zoneConfig,
                title: "Session",
                notes: " \n\t "
            )
        )
        #expect(emptyRecord.notes == nil)
    }

    @Test func saveWorkoutNormalizesTitleWhitespace() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workouts-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "workout-store-\(UUID().uuidString)")!
        defaults.set(90, forKey: WorkoutDefaultsKey.retentionDays)
        let iCloudStore = resetICloudStore()

        let store = WorkoutStore(storeURL: tempURL, userDefaults: defaults, iCloudStore: iCloudStore)
        let trimmedTitleRecord = sampleWorkout(
            startOffset: -180,
            duration: 60,
            title: "  Lift Session  ",
            notes: "Good tempo work."
        )
        store.saveWorkout(trimmedTitleRecord)

        let emptyTitleRecord = sampleWorkout(
            startOffset: -60,
            duration: 60,
            title: " \n\t ",
            notes: "Leg day."
        )
        store.saveWorkout(emptyTitleRecord)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(store.workouts.first(where: { $0.id == trimmedTitleRecord.id })?.title == "Lift Session")
        #expect(store.workouts.first(where: { $0.id == emptyTitleRecord.id })?.title == nil)
    }

    @Test func workoutRecordBuildsChartDataPointsFromSavedSamples() {
        let start = Date(timeIntervalSince1970: 1_234_567)
        let record = makeWorkoutRecord(
            start: start,
            duration: 120,
            hrSamples: [
                WorkoutHeartRateSample(timestamp: start.addingTimeInterval(12), bpm: 128, workoutTime: nil),
                WorkoutHeartRateSample(timestamp: start.addingTimeInterval(5), bpm: 122, workoutTime: 4),
                WorkoutHeartRateSample(timestamp: start.addingTimeInterval(-2), bpm: 90, workoutTime: nil)
            ]
        )

        #expect(record.chartDataPoints.map(\.time) == [4, 12])
        #expect(record.chartDataPoints.map(\.bpm) == [122, 128])
        #expect(record.chartMaxTime == 120)
    }

    @Test func workoutRecordBuildsChartSegmentsFromSavedSets() {
        let record = makeWorkoutRecord(
            duration: 120,
            sets: [
                WorkoutSetSummary(
                    id: UUID(),
                    label: "Work 1",
                    setTime: 30,
                    totalTime: 30,
                    isRestSet: false,
                    isCooldownSet: false,
                    associatedWorkSetNumber: 1,
                    avgBpm: 145,
                    minBpm: 132,
                    maxBpm: 156
                ),
                WorkoutSetSummary(
                    id: UUID(),
                    label: "Rest 1",
                    setTime: 15,
                    totalTime: 45,
                    isRestSet: true,
                    isCooldownSet: false,
                    associatedWorkSetNumber: 1,
                    avgBpm: 118,
                    minBpm: 110,
                    maxBpm: 126
                ),
                WorkoutSetSummary(
                    id: UUID(),
                    label: "Cooldown",
                    setTime: 60,
                    totalTime: 105,
                    isRestSet: false,
                    isCooldownSet: true,
                    associatedWorkSetNumber: nil,
                    avgBpm: 104,
                    minBpm: 96,
                    maxBpm: 112
                )
            ]
        )

        #expect(record.chartSegments.map(\.startTime) == [0, 30, 45])
        #expect(record.chartSegments.map(\.endTime) == [30, 45, 105])
        #expect(record.chartSegments.map(\.type) == [.work, .rest, .cooldown])
        #expect(record.chartMaxTime == 120)
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
        hrSampleCount: Int = 0,
        title: String? = "Test Session",
        notes: String? = nil
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
            title: title,
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
            notes: notes,
            source: "phone",
            appVersion: "1.0 (1)",
            healthKitWorkoutUUID: nil,
            healthKitSyncedAt: nil,
            healthKitLastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeWorkoutRecord(
        start: Date = Date(),
        duration: TimeInterval,
        hrSamples: [WorkoutHeartRateSample] = [],
        sets: [WorkoutSetSummary] = []
    ) -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(),
            schemaVersion: WorkoutRecord.schemaVersion,
            title: "Chart Test",
            startAt: start,
            endAt: start.addingTimeInterval(duration),
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
            sets: sets,
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
