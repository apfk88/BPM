import Foundation
import SwiftUI

enum WorkoutDefaultsKey {
    static let retentionDays = "BPM_Workouts_RetentionDays"
}

enum WorkoutICloudKey {
    static let data = "BPM_Workouts_Data"
    static let updatedAt = "BPM_Workouts_UpdatedAt"
}

private enum WorkoutICloudSyncLimit {
    // NSUbiquitousKeyValueStore per-key limit is 1 MB.
    static let hardKeyLimitBytes = 1_048_576
    // Keep headroom to avoid platform overhead edge cases.
    static let targetPayloadBytes = 950_000
    // Keep per-workout samples bounded for cross-device sync payload size.
    static let maxSamplesPerWorkout = 1_200
    static let fallbackSampleCaps = [600, 300, 120, 60, 30, 0]
}

final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    @Published private(set) var workouts: [WorkoutRecord] = []
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let userDefaults: UserDefaults
    private let iCloudStore: ICloudKeyValueStore
    private let queue = DispatchQueue(label: "bpm.workout-store", qos: .utility)
    private var cachedRecords: [WorkoutRecord] = []

    init(
        storeURL: URL = WorkoutStore.defaultStoreURL(),
        userDefaults: UserDefaults = .standard,
        iCloudStore: ICloudKeyValueStore = NSUbiquitousKeyValueStore.default
    ) {
        self.storeURL = storeURL
        self.userDefaults = userDefaults
        self.iCloudStore = iCloudStore
        registerDefaults()
        registerForICloudChanges()
        load()
    }

    var retentionDays: Int {
        let value = userDefaults.integer(forKey: WorkoutDefaultsKey.retentionDays)
        return value > 0 ? value : 90
    }

    var isRetentionUnlimited: Bool {
        retentionDays <= 0
    }

    func saveWorkout(_ record: WorkoutRecord) {
        queue.async {
            var updated = record
            let now = Date()
            var records = self.cachedRecords

            let titleValue = record.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = titleValue?.isEmpty == false ? titleValue : nil

            if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
                updated = WorkoutRecord(
                    id: record.id,
                    schemaVersion: record.schemaVersion,
                    title: normalizedTitle,
                    startAt: record.startAt,
                    endAt: record.endAt,
                    durationSeconds: record.durationSeconds,
                    avgHr: record.avgHr,
                    maxHr: record.maxHr,
                    minHr: record.minHr,
                    hrv: record.hrv,
                    hrr: record.hrr,
                    caloriesTotal: record.caloriesTotal,
                    caloriesActive: record.caloriesActive,
                    hrSamples: record.hrSamples,
                    zones: record.zones,
                    sets: record.sets,
                    notes: record.notes,
                    source: record.source,
                    appVersion: record.appVersion,
                    healthKitWorkoutUUID: record.healthKitWorkoutUUID,
                    healthKitSyncedAt: record.healthKitSyncedAt,
                    healthKitLastError: record.healthKitLastError,
                    createdAt: records[existingIndex].createdAt,
                    updatedAt: now
                )
                records[existingIndex] = updated
            } else {
                updated = WorkoutRecord(
                    id: record.id,
                    schemaVersion: record.schemaVersion,
                    title: normalizedTitle,
                    startAt: record.startAt,
                    endAt: record.endAt,
                    durationSeconds: record.durationSeconds,
                    avgHr: record.avgHr,
                    maxHr: record.maxHr,
                    minHr: record.minHr,
                    hrv: record.hrv,
                    hrr: record.hrr,
                    caloriesTotal: record.caloriesTotal,
                    caloriesActive: record.caloriesActive,
                    hrSamples: record.hrSamples,
                    zones: record.zones,
                    sets: record.sets,
                    notes: record.notes,
                    source: record.source,
                    appVersion: record.appVersion,
                    healthKitWorkoutUUID: record.healthKitWorkoutUUID,
                    healthKitSyncedAt: record.healthKitSyncedAt,
                    healthKitLastError: record.healthKitLastError,
                    createdAt: now,
                    updatedAt: now
                )
                records.insert(updated, at: 0)
            }

            records = self.pruneRetentionInternal(records: records, now: now)
            self.persist(records: records)
            DispatchQueue.main.async {
                self.lastError = nil
                self.workouts = self.sorted(records)
            }
        }
    }

    func deleteWorkout(_ record: WorkoutRecord) {
        queue.async {
            var records = self.cachedRecords
            records.removeAll { $0.id == record.id }
            self.persist(records: records)
            DispatchQueue.main.async {
                self.lastError = nil
                self.workouts = self.sorted(records)
            }
        }
    }

    func pruneRetention() {
        queue.async {
            let records = self.pruneRetentionInternal(records: self.cachedRecords, now: Date())
            self.persist(records: records)
            DispatchQueue.main.async {
                self.workouts = self.sorted(records)
            }
        }
    }

    func exportAllJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(workouts) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func load() {
        queue.async {
            do {
                self.iCloudStore.synchronize()
                let local = try self.loadLocalRecords()
                let remote = try self.loadICloudRecords()

                let selected = self.preferredRecords(local: local, remote: remote)
                let records = self.pruneRetentionInternal(records: selected.records, now: Date())
                if local.updatedAt != nil || remote.updatedAt != nil {
                    self.persist(records: records, updatedAt: selected.updatedAt)
                } else {
                    self.cachedRecords = records
                }
                self.cachedRecords = records
                DispatchQueue.main.async {
                    self.lastError = nil
                    self.workouts = self.sorted(records)
                }
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    DispatchQueue.main.async {
                        self.lastError = "Failed to load workouts"
                    }
                }
            }
        }
    }

    private func persist(records: [WorkoutRecord], updatedAt: Date = Date()) {
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: storeURL, options: [.atomic])
            persistToICloud(data: data, records: records, updatedAt: updatedAt)
            cachedRecords = records
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Failed to save workouts"
            }
        }
    }

    private func pruneRetentionInternal(records: [WorkoutRecord], now: Date) -> [WorkoutRecord] {
        guard retentionDays > 0 else { return records }
        let retentionSeconds = Double(retentionDays) * 24 * 60 * 60
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        return records.filter { $0.endAt >= cutoff }
    }

    private func ensureDirectoryExists() throws {
        let directory = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func sorted(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        records.sorted { $0.startAt > $1.startAt }
    }

    private func registerForICloudChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleICloudChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore
        )
    }

    @objc private func handleICloudChange() {
        queue.async {
            do {
                let local = try self.loadLocalRecords()
                let remote = try self.loadICloudRecords()
                guard let remoteUpdatedAt = remote.updatedAt else { return }
                let localUpdatedAt = local.updatedAt
                if localUpdatedAt == nil || remoteUpdatedAt > localUpdatedAt ?? .distantPast {
                    let merged = self.mergeRecords(local: local.records, remote: remote.records)
                    let records = self.pruneRetentionInternal(records: merged, now: Date())
                    self.persist(records: records, updatedAt: remoteUpdatedAt)
                    DispatchQueue.main.async {
                        self.lastError = nil
                        self.workouts = self.sorted(records)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Failed to sync workouts"
                }
            }
        }
    }

    private func loadLocalRecords() throws -> (records: [WorkoutRecord], updatedAt: Date?) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return ([], nil)
        }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([WorkoutRecord].self, from: data)
        let updatedAt = try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date
        return (records, updatedAt)
    }

    private func loadICloudRecords() throws -> (records: [WorkoutRecord], updatedAt: Date?) {
        guard let data = iCloudStore.data(forKey: WorkoutICloudKey.data) else {
            return ([], nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([WorkoutRecord].self, from: data)
        let updatedAtValue = iCloudStore.object(forKey: WorkoutICloudKey.updatedAt) as? TimeInterval
        let updatedAt = updatedAtValue.map { Date(timeIntervalSince1970: $0) }
        return (records, updatedAt)
    }

    private func preferredRecords(
        local: (records: [WorkoutRecord], updatedAt: Date?),
        remote: (records: [WorkoutRecord], updatedAt: Date?)
    ) -> (records: [WorkoutRecord], updatedAt: Date) {
        let mergedRecords = mergeRecords(local: local.records, remote: remote.records)
        let localUpdatedAt = local.updatedAt ?? .distantPast
        let remoteUpdatedAt = remote.updatedAt ?? .distantPast
        let chosenUpdatedAt = max(localUpdatedAt, remoteUpdatedAt)
        return (mergedRecords, chosenUpdatedAt == .distantPast ? Date() : chosenUpdatedAt)
    }

    private func mergeRecords(local: [WorkoutRecord], remote: [WorkoutRecord]) -> [WorkoutRecord] {
        var byId = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for remoteRecord in remote {
            if let existing = byId[remoteRecord.id] {
                byId[remoteRecord.id] = remoteRecord.updatedAt > existing.updatedAt ? remoteRecord : existing
            } else {
                byId[remoteRecord.id] = remoteRecord
            }
        }
        return Array(byId.values)
    }

    private func persistToICloud(data: Data, records: [WorkoutRecord], updatedAt: Date) {
        let payloadData: Data
        if data.count <= WorkoutICloudSyncLimit.targetPayloadBytes {
            payloadData = data
        } else if let compact = makeICloudPayload(from: records) {
            payloadData = compact
        } else {
            return
        }

        guard payloadData.count <= WorkoutICloudSyncLimit.hardKeyLimitBytes else { return }

        iCloudStore.set(payloadData, forKey: WorkoutICloudKey.data)
        iCloudStore.set(updatedAt.timeIntervalSince1970, forKey: WorkoutICloudKey.updatedAt)
        iCloudStore.synchronize()
    }

    private func makeICloudPayload(from records: [WorkoutRecord]) -> Data? {
        let sortedRecords = sorted(records)
        var syncedRecords: [WorkoutRecord] = []

        for record in sortedRecords {
            let compactRecord = compactRecordForICloud(record, maxSamples: WorkoutICloudSyncLimit.maxSamplesPerWorkout)
            var candidate = syncedRecords
            candidate.append(compactRecord)
            if let encoded = encodeForICloud(candidate), encoded.count <= WorkoutICloudSyncLimit.targetPayloadBytes {
                syncedRecords = candidate
                continue
            }

            if syncedRecords.isEmpty {
                for sampleCap in WorkoutICloudSyncLimit.fallbackSampleCaps {
                    let fallback = compactRecordForICloud(record, maxSamples: sampleCap)
                    if let encoded = encodeForICloud([fallback]), encoded.count <= WorkoutICloudSyncLimit.targetPayloadBytes {
                        syncedRecords = [fallback]
                        break
                    }
                }
            }
            break
        }

        return encodeForICloud(syncedRecords)
    }

    private func encodeForICloud(_ records: [WorkoutRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }

    private func compactRecordForICloud(_ record: WorkoutRecord, maxSamples: Int) -> WorkoutRecord {
        WorkoutRecord(
            id: record.id,
            schemaVersion: record.schemaVersion,
            title: record.title,
            startAt: record.startAt,
            endAt: record.endAt,
            durationSeconds: record.durationSeconds,
            avgHr: record.avgHr,
            maxHr: record.maxHr,
            minHr: record.minHr,
            hrv: record.hrv,
            hrr: record.hrr,
            caloriesTotal: record.caloriesTotal,
            caloriesActive: record.caloriesActive,
            hrSamples: downsampledSamples(record.hrSamples, maxCount: maxSamples),
            zones: record.zones,
            sets: record.sets,
            notes: record.notes,
            source: record.source,
            appVersion: record.appVersion,
            healthKitWorkoutUUID: record.healthKitWorkoutUUID,
            healthKitSyncedAt: record.healthKitSyncedAt,
            healthKitLastError: record.healthKitLastError,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func downsampledSamples(_ samples: [WorkoutHeartRateSample], maxCount: Int) -> [WorkoutHeartRateSample] {
        guard maxCount > 0 else { return [] }
        guard samples.count > maxCount else { return samples }

        let step = max(1, samples.count / maxCount)
        var reduced: [WorkoutHeartRateSample] = []
        reduced.reserveCapacity(maxCount + 1)

        var index = 0
        while index < samples.count {
            reduced.append(samples[index])
            index += step
        }

        if let last = samples.last, reduced.last?.timestamp != last.timestamp {
            reduced.append(last)
        }

        if reduced.count > maxCount {
            reduced = Array(reduced.prefix(maxCount))
        }
        return reduced
    }

    private func registerDefaults() {
        userDefaults.register(defaults: [
            WorkoutDefaultsKey.retentionDays: 365
        ])
    }

    static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = support?.appendingPathComponent("BPM", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory.appendingPathComponent("workouts.json")
    }
}
