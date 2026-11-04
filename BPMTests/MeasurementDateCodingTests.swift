import Foundation
import XCTest
@testable import BPM

final class MeasurementDateCodingTests: XCTestCase {
    private struct Dates: Codable {
        let values: [Date]
    }

    func testRoundTripPreservesSubmillisecondDatesAcrossSecondBoundaries() throws {
        let dates = Dates(values: [
            Date(timeIntervalSinceReferenceDate: 821_692_800.1234567),
            Date(timeIntervalSinceReferenceDate: 821_692_800.1239876),
            Date(timeIntervalSinceReferenceDate: 821_692_800.9999999),
            Date(timeIntervalSinceReferenceDate: -0.0000012)
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = MeasurementDateCoding.encodingStrategy
        let data = try encoder.encode(dates)
        let decoded = try decoder().decode(Dates.self, from: data)
        for (original, roundTrip) in zip(dates.values, decoded.values) {
            XCTAssertEqual(roundTrip.timeIntervalSince(original), 0, accuracy: 0.000000001)
        }
        XCTAssertNotEqual(decoded.values[0], decoded.values[1])

        // Export remains readable by Foundation's standard current ISO 8601 decoder.
        let standardDecoder = JSONDecoder()
        standardDecoder.dateDecodingStrategy = .iso8601
        let standard = try standardDecoder.decode(Dates.self, from: data)
        for (original, roundTrip) in zip(dates.values, standard.values) {
            XCTAssertEqual(roundTrip.timeIntervalSince(original), 0, accuracy: 0.000001)
        }
    }

    func testDecoderAcceptsLegacyWholeSecondsAndFractionalTimezoneOffsets() throws {
        let data = Data("""
        {"values":["2027-01-15T08:00:00Z","2027-01-15T00:00:00.123456789-08:00"]}
        """.utf8)
        let values = try decoder().decode(Dates.self, from: data).values
        XCTAssertEqual(values[0], Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(values[1].timeIntervalSince(values[0]), 0.123456789, accuracy: 0.000001)
        for timestamp in ["not-a-date", "2027-01-15T08:00:00.Z", "2027-01-15T08:00:00.nanZ"] {
            XCTAssertThrowsError(try decoder().decode(Dates.self, from: Data("{\"values\":[\"\(timestamp)\"]}".utf8)))
        }
    }

    @MainActor func testWorkoutDiskCloudAndExportPreserveRapidSamplesAndPauseBoundaries() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("date-precision-workout-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cloud = InMemoryICloudKeyValueStore()
        let store = WorkoutStore(storeURL: url, userDefaults: UserDefaults(suiteName: "dates-\(UUID())")!, iCloudStore: cloud)
        let record = workout()
        let saved: Result<WorkoutRecord, WorkoutStore.DetailEditError> = await withCheckedContinuation { continuation in
            store.saveWorkout(record) { continuation.resume(returning: $0) }
        }
        _ = try saved.get()
        let disk = try decoder().decode([WorkoutRecord].self, from: Data(contentsOf: url))[0]
        let cloudData = try XCTUnwrap(cloud.data(forKey: WorkoutICloudKey.data))
        let remote = try decoder().decode([WorkoutRecord].self, from: MeasurementDateCoding.restoringCloudPrecision(in: cloudData))[0]
        let exported = try decoder().decode(WorkoutRecord.self, from: Data(record.jsonString().utf8))
        for copy in [disk, remote, exported] {
            XCTAssertEqual(copy.hrSamples.map(\.timestamp), record.hrSamples.map(\.timestamp))
            XCTAssertEqual(copy.hrSamples.map(\.invalidatedAt), record.hrSamples.map(\.invalidatedAt))
            XCTAssertEqual(copy.pauses, record.pauses)
            XCTAssertEqual(copy.startAt, record.startAt)
            XCTAssertEqual(copy.endAt, record.endAt)
        }

        // Simulate the older iOS ISO parser, which rejects fractional dates.
        let strictLegacyDecoder = JSONDecoder()
        strictLegacyDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Legacy parser requires whole seconds")
            }
            return date
        }
        XCTAssertThrowsError(try strictLegacyDecoder.decode(WorkoutRecord.self, from: Data(record.jsonString().utf8)))
        let legacyCopy = try strictLegacyDecoder.decode([WorkoutRecord].self, from: cloudData)[0]
        XCTAssertEqual(legacyCopy.id, record.id)
        XCTAssertEqual(legacyCopy.hrSamples.map(\.bpm), record.hrSamples.map(\.bpm))
        for sample in legacyCopy.hrSamples {
            XCTAssertEqual(sample.timestamp.timeIntervalSinceReferenceDate, floor(sample.timestamp.timeIntervalSinceReferenceDate))
        }

        // Prove the store's cloud loading path restores the companion data too.
        let cloudOnlyURL = FileManager.default.temporaryDirectory.appendingPathComponent("date-precision-cloud-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cloudOnlyURL) }
        let cloudOnlyStore = WorkoutStore(storeURL: cloudOnlyURL, userDefaults: UserDefaults(suiteName: "dates-\(UUID())")!, iCloudStore: cloud)
        for _ in 0..<100 where cloudOnlyStore.workouts.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let loaded = try XCTUnwrap(cloudOnlyStore.workouts.first)
        XCTAssertEqual(loaded.hrSamples.map(\.timestamp), record.hrSamples.map(\.timestamp))
        XCTAssertEqual(loaded.hrSamples.map(\.invalidatedAt), record.hrSamples.map(\.invalidatedAt))
        XCTAssertEqual(loaded.pauses, record.pauses)
    }

    func testCloudPrecisionCannotOverrideUnrelatedFieldsOrDifferentWholeSeconds() throws {
        let data = Data("""
        {"timestamp":"2027-01-15T08:00:00Z","title":"Keep this","bpm":120,
         "_bpmDatePrecision":{"timestamp":"2027-01-15T08:00:01.123456789Z",
                              "title":"2027-01-15T08:00:00.123456789Z","bpm":0,
                              "absent":"2027-01-15T08:00:00.123456789Z"}}
        """.utf8)
        let restored = try MeasurementDateCoding.restoringCloudPrecision(in: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        XCTAssertEqual(object["timestamp"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(object["title"] as? String, "Keep this")
        XCTAssertEqual(object["bpm"] as? Int, 120)
        XCTAssertNil(object["absent"])
        XCTAssertNil(object["_bpmDatePrecision"])

        let wholeSecondData = Data("[{\"timestamp\":\"2027-01-15T08:00:00Z\"}]".utf8)
        let compatible = try MeasurementDateCoding.legacyCompatibleCloudData(from: wholeSecondData)
        XCTAssertFalse(String(decoding: compatible, as: UTF8.self).contains("_bpmDatePrecision"))
    }

    @MainActor func testHRVDiskAndExportPreserveSampleDatesAndRawIntervals() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("date-precision-hrv-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HRVStore(storeURL: url, userDefaults: UserDefaults(suiteName: "dates-\(UUID())")!)
        let start = Date().addingTimeInterval(-120.1234567)
        let record = HRVRecord(
            id: UUID(), schemaVersion: HRVRecord.schemaVersion,
            startAt: start, endAt: start.addingTimeInterval(120), durationSeconds: 120,
            hrvValue: 20, avgHr: 60, minHr: 59, maxHr: 61,
            hrSamples: [HRVHeartRateSample(timestamp: start.addingTimeInterval(0.1234567), bpm: 60),
                        HRVHeartRateSample(timestamp: start.addingTimeInterval(0.2345678), bpm: 61)],
            rrIntervalsMs: [1000.9765625, 990.234375], source: "phone", appVersion: "test",
            createdAt: start, updatedAt: start
        )
        let saved: Bool = await withCheckedContinuation { continuation in
            store.saveRecord(record) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(saved)
        let disk = try decoder().decode([HRVRecord].self, from: Data(contentsOf: url))[0]
        let exported = try decoder().decode(HRVRecord.self, from: Data(record.jsonString().utf8))
        for copy in [disk, exported] {
            XCTAssertEqual(copy.hrSamples.map(\.timestamp), record.hrSamples.map(\.timestamp))
            XCTAssertEqual(copy.rrIntervalsMs, record.rrIntervalsMs)
            XCTAssertEqual(copy.startAt, record.startAt)
            XCTAssertEqual(copy.endAt, record.endAt)
        }
    }

    @MainActor func testStoresReadLegacyWholeSecondHistory() async throws {
        let workoutURL = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-workout-\(UUID()).json")
        let hrvURL = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-hrv-\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: workoutURL)
            try? FileManager.default.removeItem(at: hrvURL)
        }
        let oldEncoder = JSONEncoder()
        oldEncoder.dateEncodingStrategy = .iso8601
        let oldWorkout = workout()
        let start = Date().addingTimeInterval(-120)
        let oldHRV = HRVRecord(
            id: UUID(), schemaVersion: 1, startAt: start, endAt: start.addingTimeInterval(120),
            durationSeconds: 120, hrvValue: 20, avgHr: 60, minHr: 59, maxHr: 61,
            hrSamples: [], rrIntervalsMs: [990, 1010], source: "phone", appVersion: "legacy",
            createdAt: start, updatedAt: start
        )
        try oldEncoder.encode([oldWorkout]).write(to: workoutURL)
        try oldEncoder.encode([oldHRV]).write(to: hrvURL)
        let workoutStore = WorkoutStore(storeURL: workoutURL, userDefaults: UserDefaults(suiteName: "dates-\(UUID())")!, iCloudStore: InMemoryICloudKeyValueStore())
        let hrvStore = HRVStore(storeURL: hrvURL, userDefaults: UserDefaults(suiteName: "dates-\(UUID())")!)
        for _ in 0..<100 where workoutStore.workouts.isEmpty || hrvStore.records.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(workoutStore.workouts.first?.id, oldWorkout.id)
        XCTAssertEqual(hrvStore.records.first?.id, oldHRV.id)
        XCTAssertNil(workoutStore.lastError)
        XCTAssertNil(hrvStore.lastError)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeasurementDateCoding.decodingStrategy
        return decoder
    }

    private func workout() -> WorkoutRecord {
        let start = Date().addingTimeInterval(-120.1234567)
        return WorkoutRecord(
            id: UUID(), schemaVersion: WorkoutRecord.schemaVersion, title: nil,
            startAt: start, endAt: start.addingTimeInterval(10.2345678), durationSeconds: 9.1111111,
            avgHr: 120, maxHr: 150, minHr: 100, hrv: nil, hrr: nil, caloriesTotal: nil, caloriesActive: nil,
            hrSamples: [WorkoutHeartRateSample(timestamp: start.addingTimeInterval(0.1234567), bpm: 100, workoutTime: 0.1234567),
                        WorkoutHeartRateSample(timestamp: start.addingTimeInterval(0.1239876), bpm: 150, workoutTime: 0.1239876, invalidatedAt: start.addingTimeInterval(0.2345678))],
            zones: [], sets: [], notes: nil, source: "phone", appVersion: "test",
            healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
            createdAt: start, updatedAt: start,
            pauses: [WorkoutPause(start: start.addingTimeInterval(1.2345678), end: start.addingTimeInterval(2.3580245))]
        )
    }
}
