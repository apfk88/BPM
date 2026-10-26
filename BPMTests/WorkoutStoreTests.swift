import Foundation
import Testing
@testable import BPM

@Suite(.serialized)
struct WorkoutStoreTests {
    @MainActor @Test func editingDetailsPersistsAndKeepsLatestMeasurementsAndSync() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workout-edit-\(UUID()).json")
        let defaults = UserDefaults(suiteName: "workout-edit-\(UUID())")!
        let cloud = resetICloudStore()
        let store = WorkoutStore(storeURL: url, userDefaults: defaults, iCloudStore: cloud)
        let original = sampleWorkout(startOffset: -120, duration: 60, hrSampleCount: 120, notes: "Original description")
        store.saveWorkout(original)
        // A sync result arrives after the edit screen opened. Editing must retain that newer result.
        let synced = original.updatingHealthKitSync(workoutUUID: UUID(), syncedAt: Date(), lastError: nil)
        store.saveWorkout(synced)
        try await edit(store, id: original.id, title: "  Tempo workout  ", description: "  Steady effort.\n")

        let saved = try #require(store.workouts.first)
        #expect(saved.title == "Tempo workout")
        #expect(saved.notes == "Steady effort.")
        #expect(saved.healthKitWorkoutUUID == synced.healthKitWorkoutUUID)
        #expect(saved.updatedAt >= original.updatedAt)
        func measurementFields(_ record: WorkoutRecord) throws -> NSDictionary {
            var json = try #require(JSONSerialization.jsonObject(with: Data(record.jsonString().utf8)) as? [String: Any])
            for key in ["title", "notes", "createdAt", "updatedAt"] { json.removeValue(forKey: key) }
            return json as NSDictionary
        }
        #expect(try measurementFields(saved) == measurementFields(synced))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let disk = try decoder.decode([WorkoutRecord].self, from: Data(contentsOf: url))
        let remote = try decoder.decode([WorkoutRecord].self, from: #require(cloud.data(forKey: WorkoutICloudKey.data)))
        #expect(disk.first?.title == saved.title)
        #expect(disk.first?.notes == saved.notes)
        #expect(remote.first?.title == saved.title)
        #expect(remote.first?.notes == saved.notes)

        // Reload without a cloud copy to prove the edit was saved locally.
        let reloaded = WorkoutStore(storeURL: url, userDefaults: defaults, iCloudStore: resetICloudStore())
        for _ in 0..<100 where reloaded.workouts.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(reloaded.workouts.first?.title == saved.title)
        #expect(reloaded.workouts.first?.notes == saved.notes)
        let delayedSyncID = UUID()
        reloaded.updateHealthKitSync(for: original.id, workoutUUID: delayedSyncID, syncedAt: Date(), lastError: nil)
        for _ in 0..<100 where reloaded.workouts.first?.healthKitWorkoutUUID != delayedSyncID {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(reloaded.workouts.first?.healthKitWorkoutUUID == delayedSyncID)
        #expect(reloaded.workouts.first?.title == saved.title)
        #expect(reloaded.workouts.first?.notes == saved.notes)
        try await edit(reloaded, id: original.id, title: " \n", description: " \t")
        #expect(reloaded.workouts.first?.title == nil)
        #expect(reloaded.workouts.first?.notes == nil)
    }

    @MainActor @Test func editingDeletedWorkoutDoesNotRecreateIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workout-edit-\(UUID()).json")
        let store = WorkoutStore(storeURL: url, userDefaults: UserDefaults(suiteName: "workout-edit-\(UUID())")!,
                                 iCloudStore: resetICloudStore())
        let original = sampleWorkout(startOffset: -120, duration: 60)
        store.saveWorkout(original)
        store.deleteWorkout(original)
        store.updateHealthKitSync(for: original.id, workoutUUID: UUID(), syncedAt: Date(), lastError: nil)
        do {
            try await edit(store, id: original.id, title: "Deleted workout", description: "")
            Issue.record("Editing a deleted workout must fail")
        } catch {
            #expect(error as? WorkoutStore.DetailEditError == .workoutNotFound)
        }
        #expect(store.workouts.isEmpty)
    }

    @MainActor @Test func failedDetailSaveRetainsPublishedAndCloudRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workout-edit-\(UUID())")
        let cloud = resetICloudStore()
        let store = WorkoutStore(storeURL: directory.appendingPathComponent("workouts.json"),
                                 userDefaults: UserDefaults(suiteName: "workout-edit-\(UUID())")!, iCloudStore: cloud)
        let original = sampleWorkout(startOffset: -120, duration: 60)
        store.saveWorkout(original)
        try await edit(store, id: original.id, title: "Saved title", description: "Saved description")
        let previousJSON = store.workouts.first?.jsonString()
        let previousCloud = cloud.data(forKey: WorkoutICloudKey.data)
        // Replace this test's own directory with a file to produce a real write failure.
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await edit(store, id: original.id, title: "Unsaved title", description: "Unsaved description")
            Issue.record("A failed disk write must report failure")
        } catch {
            #expect(error as? WorkoutStore.DetailEditError == .saveFailed)
        }
        #expect(store.workouts.first?.jsonString() == previousJSON)
        #expect(cloud.data(forKey: WorkoutICloudKey.data) == previousCloud)
    }

    @MainActor @Test func saveCompletionReportsActualDiskSuccessOrFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workout-save-\(UUID())")
        let url = directory.appendingPathComponent("workouts.json")
        let cloud = resetICloudStore()
        let store = WorkoutStore(storeURL: url, userDefaults: UserDefaults(suiteName: "workout-save-\(UUID())")!,
                                 iCloudStore: cloud)
        let original = sampleWorkout(startOffset: -120, duration: 60)
        let saved = try await withCheckedThrowingContinuation { continuation in
            store.saveWorkout(original) { continuation.resume(with: $0) }
        }
        #expect(saved.id == original.id)
        #expect(store.workouts.contains { $0.id == saved.id })
        #expect(FileManager.default.fileExists(atPath: url.path))
        let previousCloud = cloud.data(forKey: WorkoutICloudKey.data)
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsaved = sampleWorkout(startOffset: -90, duration: 40)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                store.saveWorkout(unsaved) { continuation.resume(with: $0) }
            }
            Issue.record("A failed write must not report a saved workout")
        } catch {
            #expect(error == .saveFailed)
        }
        #expect(!store.workouts.contains { $0.id == unsaved.id })
        #expect(cloud.data(forKey: WorkoutICloudKey.data) == previousCloud)
    }

    @MainActor private func edit(_ store: WorkoutStore, id: UUID, title: String, description: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.updateDetails(for: id, title: title, description: description) { continuation.resume(with: $0) }
        }
    }

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
        #expect(reloaded.workouts.first(where: { $0.id == record.id })?.zoneConfig?.maxHeartRate == 190)
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
        #expect(decoded.zoneConfig == nil)
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
        #expect(store.workouts.first?.zoneConfig?.maxHeartRate == 190)
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
        #expect(trimmedRecord.zoneConfig?.maxHeartRate == zoneConfig.maxHeartRate)

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
        #expect(syncedRecords.allSatisfy { $0.zoneConfig?.maxHeartRate == 190 })
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
            updatedAt: Date(),
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)
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

    private func resetICloudStore() -> InMemoryICloudKeyValueStore {
        let store = InMemoryICloudKeyValueStore()
        store.removeObject(forKey: WorkoutICloudKey.data)
        store.removeObject(forKey: WorkoutICloudKey.updatedAt)
        store.synchronize()
        return store
    }
}
