import Foundation
import Testing
@testable import BPM

struct HRVStoreTests {
    @Test func savesAndLoadsRecords() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hrv-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "hrv-store-\(UUID().uuidString)")!
        defaults.set(365, forKey: HRVDefaultsKey.retentionDays)

        let store = HRVStore(storeURL: tempURL, userDefaults: defaults)
        let record = sampleRecord(startOffset: -120, duration: 120)
        store.saveRecord(record)
        try await Task.sleep(nanoseconds: 200_000_000)

        let reloaded = HRVStore(storeURL: tempURL, userDefaults: defaults)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.id == record.id)
    }

    @Test @MainActor func consecutiveSavesRetainEveryMeasurement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hrv-sequential-\(UUID()).json")
        let store = HRVStore(storeURL: url, userDefaults: UserDefaults(suiteName: "hrv-\(UUID())")!)
        let records = (0..<10).map { sampleRecord(startOffset: Double(-120 - $0 * 120), duration: 120) }
        let saved: Bool = await withCheckedContinuation { continuation in
            for record in records.dropLast() { store.saveRecord(record) }
            store.saveRecord(records.last!) { continuation.resume(returning: $0) }
        }
        #expect(saved)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode([HRVRecord].self, from: Data(contentsOf: url))
        #expect(Set(reloaded.map(\.id)) == Set(records.map(\.id)))
    }

    @Test @MainActor func failedSaveDoesNotReportSuccess() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hrv-blocked-\(UUID())")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = HRVStore(storeURL: file.appendingPathComponent("history.json"), userDefaults: UserDefaults(suiteName: "hrv-\(UUID())")!)
        let saved: Bool = await withCheckedContinuation { continuation in
            store.saveRecord(sampleRecord(startOffset: -120, duration: 120)) { continuation.resume(returning: $0) }
        }
        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(store.records.isEmpty)
    }

    private func sampleRecord(startOffset: TimeInterval, duration: TimeInterval) -> HRVRecord {
        let start = Date().addingTimeInterval(startOffset)
        let end = start.addingTimeInterval(duration)
        return HRVRecord(
            id: UUID(),
            schemaVersion: HRVRecord.schemaVersion,
            startAt: start,
            endAt: end,
            durationSeconds: duration,
            hrvValue: 52.0,
            avgHr: 60,
            minHr: 55,
            maxHr: 70,
            hrSamples: [],
            rrIntervalsMs: [],
            source: "phone",
            appVersion: "1.0 (1)",
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
