import Foundation
import SwiftUI

enum WorkoutDefaultsKey {
    static let retentionDays = "BPM_Workouts_RetentionDays"
}

enum WorkoutICloudKey {
    static let data = "BPM_Workouts_Data"
    static let updatedAt = "BPM_Workouts_UpdatedAt"
}

final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    @Published private(set) var workouts: [WorkoutRecord] = []
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let userDefaults: UserDefaults
    private let iCloudStore: NSUbiquitousKeyValueStore
    private let queue = DispatchQueue(label: "bpm.workout-store", qos: .utility)

    init(
        storeURL: URL = WorkoutStore.defaultStoreURL(),
        userDefaults: UserDefaults = .standard,
        iCloudStore: NSUbiquitousKeyValueStore = .default
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
            var records = self.workouts

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
                    caloriesTotal: record.caloriesTotal,
                    caloriesActive: record.caloriesActive,
                    hrSamples: record.hrSamples,
                    zones: record.zones,
                    sets: record.sets,
                    notes: record.notes,
                    source: record.source,
                    appVersion: record.appVersion,
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
                    caloriesTotal: record.caloriesTotal,
                    caloriesActive: record.caloriesActive,
                    hrSamples: record.hrSamples,
                    zones: record.zones,
                    sets: record.sets,
                    notes: record.notes,
                    source: record.source,
                    appVersion: record.appVersion,
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
            var records = self.workouts
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
            let records = self.pruneRetentionInternal(records: self.workouts, now: Date())
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
                self.persist(records: records, updatedAt: selected.updatedAt)
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
            persistToICloud(data: data, updatedAt: updatedAt)
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
                    let records = self.pruneRetentionInternal(records: remote.records, now: Date())
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
        let localUpdatedAt = local.updatedAt ?? .distantPast
        let remoteUpdatedAt = remote.updatedAt ?? .distantPast
        if remoteUpdatedAt > localUpdatedAt {
            return (remote.records, remoteUpdatedAt)
        }
        return (local.records, localUpdatedAt == .distantPast ? Date() : localUpdatedAt)
    }

    private func persistToICloud(data: Data, updatedAt: Date) {
        iCloudStore.set(data, forKey: WorkoutICloudKey.data)
        iCloudStore.set(updatedAt.timeIntervalSince1970, forKey: WorkoutICloudKey.updatedAt)
        iCloudStore.synchronize()
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
