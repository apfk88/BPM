import Foundation
import SwiftUI

enum HRVDefaultsKey {
    static let retentionDays = "BPM_HRV_RetentionDays"
}

final class HRVStore: ObservableObject {
    static let shared = HRVStore()

    @Published private(set) var records: [HRVRecord] = []
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let userDefaults: UserDefaults
    private let queue = DispatchQueue(label: "bpm.hrv-store", qos: .utility)

    init(storeURL: URL = HRVStore.defaultStoreURL(), userDefaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.userDefaults = userDefaults
        registerDefaults()
        load()
    }

    var retentionDays: Int {
        let value = userDefaults.integer(forKey: HRVDefaultsKey.retentionDays)
        return value > 0 ? value : 365
    }

    func saveRecord(_ record: HRVRecord) {
        queue.async {
            var records = self.records
            let now = Date()

            if let existingIndex = records.firstIndex(where: { $0.id == record.id }) {
                let updated = HRVRecord(
                    id: record.id,
                    schemaVersion: record.schemaVersion,
                    startAt: record.startAt,
                    endAt: record.endAt,
                    durationSeconds: record.durationSeconds,
                    hrvValue: record.hrvValue,
                    avgHr: record.avgHr,
                    minHr: record.minHr,
                    maxHr: record.maxHr,
                    hrSamples: record.hrSamples,
                    rrIntervalsMs: record.rrIntervalsMs,
                    source: record.source,
                    appVersion: record.appVersion,
                    createdAt: records[existingIndex].createdAt,
                    updatedAt: now
                )
                records[existingIndex] = updated
            } else {
                let updated = HRVRecord(
                    id: record.id,
                    schemaVersion: record.schemaVersion,
                    startAt: record.startAt,
                    endAt: record.endAt,
                    durationSeconds: record.durationSeconds,
                    hrvValue: record.hrvValue,
                    avgHr: record.avgHr,
                    minHr: record.minHr,
                    maxHr: record.maxHr,
                    hrSamples: record.hrSamples,
                    rrIntervalsMs: record.rrIntervalsMs,
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
                self.records = self.sorted(records)
            }
        }
    }

    func deleteRecord(_ record: HRVRecord) {
        queue.async {
            var records = self.records
            records.removeAll { $0.id == record.id }
            self.persist(records: records)
            DispatchQueue.main.async {
                self.lastError = nil
                self.records = self.sorted(records)
            }
        }
    }

    func exportAllJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func load() {
        queue.async {
            do {
                let data = try Data(contentsOf: self.storeURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var records = try decoder.decode([HRVRecord].self, from: data)
                records = self.pruneRetentionInternal(records: records, now: Date())
                self.persist(records: records)
                DispatchQueue.main.async {
                    self.lastError = nil
                    self.records = self.sorted(records)
                }
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    DispatchQueue.main.async {
                        self.lastError = "Failed to load HRV history"
                    }
                }
            }
        }
    }

    private func persist(records: [HRVRecord]) {
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Failed to save HRV history"
            }
        }
    }

    private func pruneRetentionInternal(records: [HRVRecord], now: Date) -> [HRVRecord] {
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

    private func sorted(_ records: [HRVRecord]) -> [HRVRecord] {
        records.sorted { $0.startAt > $1.startAt }
    }

    private func registerDefaults() {
        userDefaults.register(defaults: [
            HRVDefaultsKey.retentionDays: 365
        ])
    }

    static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = support?.appendingPathComponent("BPM", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory.appendingPathComponent("hrv-history.json")
    }
}
