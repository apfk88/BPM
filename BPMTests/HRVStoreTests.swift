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
