import Foundation
import SwiftUI

enum WorkoutDefaultsKey {
    static let retentionDays = "BPM_Workouts_RetentionDays"
}

final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    @Published private(set) var workouts: [WorkoutRecord] = []
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "bpm.workout-store", qos: .utility)

    init(storeURL: URL = WorkoutStore.defaultStoreURL(), userDefaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.userDefaults = userDefaults
        registerDefaults()
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
                let data = try Data(contentsOf: self.storeURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var records = try decoder.decode([WorkoutRecord].self, from: data)
                records = self.pruneRetentionInternal(records: records, now: Date())
                self.persist(records: records)
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

    private func persist(records: [WorkoutRecord]) {
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: storeURL, options: [.atomic])
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
