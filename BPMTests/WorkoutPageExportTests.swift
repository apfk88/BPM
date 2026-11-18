import XCTest
import zlib
@testable import BPM

enum WorkoutPageTestFixtures {
    static func record(fidelity: WorkoutSampleFidelity? = .full, sampleCount: Int = 120,
                       invalidatedSampleIndex: Int? = nil, startAt: Date? = nil) -> WorkoutRecord {
        let start = startAt ?? Date(timeIntervalSince1970: 1_800_000_000.123)
        return WorkoutRecord(id: UUID(), schemaVersion: 4, title: "Original title", startAt: start,
            endAt: start.addingTimeInterval(180), durationSeconds: 120,
            avgHr: 137, maxHr: 180, minHr: 90, hrv: nil, hrr: 25, caloriesTotal: 150, caloriesActive: 120,
            hrSamples: (0..<sampleCount).map { index in
                let active = Double(index) * 120 / Double(max(1, sampleCount))
                let elapsed = active >= 20 ? active + 60 : active
                return WorkoutHeartRateSample(timestamp: start.addingTimeInterval(elapsed), bpm: 100 + index % 50,
                                              workoutTime: active,
                                              invalidatedAt: index == invalidatedSampleIndex ? start.addingTimeInterval(elapsed + 0.25) : nil)
            },
            zones: [.init(id: UUID(), zone: 2, duration: 100)],
            sets: [.init(id: UUID(), label: "1", setTime: 60, totalTime: 60, isRestSet: false, isCooldownSet: false,
                         associatedWorkSetNumber: nil, avgBpm: 132, minBpm: 100, maxBpm: 170),
                   .init(id: UUID(), label: "C1", setTime: 60, totalTime: 120, isRestSet: true, isCooldownSet: true,
                         associatedWorkSetNumber: nil, avgBpm: 120, minBpm: 90, maxBpm: 150)],
            notes: "Unshared original notes", source: "private-device-source", appVersion: "test-version",
            healthKitWorkoutUUID: UUID(), healthKitSyncedAt: start, healthKitLastError: "private diagnostic details",
            createdAt: start, updatedAt: start,
            pauses: [.init(start: start.addingTimeInterval(20), end: start.addingTimeInterval(80))],
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 200), sampleFidelity: fidelity,
            originalSampleCount: fidelity == .full ? sampleCount : nil)
    }

    static func ungzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WorkoutPageError.invalidResponse
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            var status = Z_OK
            repeat {
                let count = buffer.count
                status = buffer.withUnsafeMutableBufferPointer { bytes in
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw WorkoutPageError.invalidResponse }
                output.append(buffer, count: count - Int(stream.avail_out))
                guard output.count <= WorkoutPageExport.maximumDecodedBytes else { throw WorkoutPageError.tooLarge }
            } while status != Z_STREAM_END
            return output
        }
    }
}

final class WorkoutPageExportTests: XCTestCase {
    func testAllowlistExcludesLocalIdentifiersDiagnosticsAndExactTimes() throws {
        let record = WorkoutPageTestFixtures.record()
        let export = try WorkoutPageExport(record: record, title: "Shared title", description: "Only these words", includeDate: false)
        let json = try XCTUnwrap(String(data: export.encoded(), encoding: .utf8))
        for hidden in [record.id.uuidString, record.healthKitWorkoutUUID!.uuidString, "healthKit", "private diagnostic details",
                       "private-device-source", "test-version", "Unshared original notes", "startAt", "endAt", "createdAt", "updatedAt"] {
            XCTAssertFalse(json.contains(hidden), hidden)
        }
        XCTAssertNil(export.recordedAt)
        XCTAssertNotNil(export.workoutDate)
        XCTAssertEqual(export.title, "Shared title")
        XCTAssertEqual(export.description, "Only these words")
        XCTAssertEqual(export.samples.count, record.hrSamples.count)
        XCTAssertEqual(export.samples.map(\.bpm), record.hrSamples.map(\.bpm))
        XCTAssertEqual(export.summary.avgBPM, record.avgHr)
    }

    func testExactTimeIsAnExplicitChoiceAndNeverAppearsOnEachSample() throws {
        let record = WorkoutPageTestFixtures.record()
        let export = try WorkoutPageExport(record: record, title: "Workout", description: "", includeDate: true)
        let date = try XCTUnwrap(export.recordedAt.flatMap(MeasurementDateCoding.date(from:)))
        XCTAssertEqual(date.timeIntervalSince1970, record.startAt.timeIntervalSince1970, accuracy: 0.001)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: export.encoded()) as? [String: Any])
        let sample = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        XCTAssertNil(sample["timestamp"])
        XCTAssertNil(sample["id"])
        XCTAssertNil(export.description)
    }

    func testDateOnlyExportUsesLocalGregorianDayAcrossTimezoneBoundaries() throws {
        let start = try XCTUnwrap(MeasurementDateCoding.date(from: "2026-11-12T01:30:00.000Z"))
        let record = WorkoutPageTestFixtures.record(startAt: start)
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let west = try WorkoutPageExport(record: record, title: "Original title", description: "", includeDate: false, timeZone: pacific)
        let east = try WorkoutPageExport(record: record, title: "Original title", description: "", includeDate: false, timeZone: tokyo)
        XCTAssertEqual(west.workoutDate, "2026-11-11")
        XCTAssertEqual(east.workoutDate, "2026-11-12")
        XCTAssertNil(west.recordedAt)
        XCTAssertNil(east.recordedAt)
        XCTAssertEqual(west.title, record.title)
        let timed = try WorkoutPageExport(record: record, title: "Original title", description: "", includeDate: true, timeZone: pacific)
        XCTAssertEqual(timed.workoutDate, west.workoutDate)
        XCTAssertEqual(timed.recordedAt.flatMap(MeasurementDateCoding.date(from:)), start)
    }

    func testCalendarDateValidationAndFormattingDoNotInventMidnightOrRollInvalidDates() throws {
        XCTAssertNotNil(WorkoutPageDate.date(from: "2024-02-29"))
        XCTAssertNil(WorkoutPageDate.date(from: "2026-02-29"))
        XCTAssertNil(WorkoutPageDate.date(from: "2026-04-31"))
        XCTAssertNil(WorkoutPageDate.date(from: "2026-11-11T00:00:00Z"))
        XCTAssertEqual(WorkoutPageDate.formatted("2026-11-11", locale: Locale(identifier: "en_US")), "November 11, 2026")
        let start = try XCTUnwrap(MeasurementDateCoding.date(from: "2027-01-01T01:00:00.000Z"))
        XCTAssertEqual(WorkoutPageDate.string(from: start, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))), "2026-12-31")
    }

    func testDetailsEditPreservesDateAndOlderExportWithoutDateStillDecodes() throws {
        var export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(), title: "Workout", description: "Original", includeDate: false)
        let originalDate = export.workoutDate
        try export.setDetails(title: "Updated", description: "New description")
        XCTAssertEqual(export.workoutDate, originalDate)
        XCTAssertNil(export.recordedAt)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: export.encoded()) as? [String: Any])
        legacy.removeValue(forKey: "workoutDate")
        let restored = try JSONDecoder().decode(WorkoutPageExport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.workoutDate)
        XCTAssertEqual(restored.title, "Updated")
    }

    func testPauseAndSetOffsetsPreserveActiveAndElapsedTime() throws {
        let export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(), title: "Intervals", description: "", includeDate: false)
        let beforePause = try XCTUnwrap(export.samples.first { $0.activeSeconds == 19 })
        let afterPause = try XCTUnwrap(export.samples.first { $0.activeSeconds == 20 })
        XCTAssertEqual(beforePause.validUntilElapsedSeconds, 20)
        XCTAssertEqual(afterPause.elapsedSeconds, 80)
        XCTAssertEqual(export.durationSeconds, 120)
        XCTAssertEqual(export.elapsedDurationSeconds, 180)
        XCTAssertEqual(export.intervals.filter { $0.kind == .pause }, [.init(startElapsedSeconds: 20, endElapsedSeconds: 80, kind: .pause)])
        XCTAssertEqual(export.sets[0].startElapsedSeconds, 0)
        XCTAssertEqual(export.sets[0].endElapsedSeconds, 120)
        XCTAssertEqual(export.sets[1].startActiveSeconds, 60)
        XCTAssertEqual(export.sets[1].startElapsedSeconds, 120)
        XCTAssertEqual(export.sets[1].kind, .cooldown)
    }

    func testReducedAndUnknownRecordsNeverInventSensorLossFromSparseSamples() throws {
        for fidelity in [WorkoutSampleFidelity?.some(.reduced), nil] {
            let export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(fidelity: fidelity, sampleCount: 4),
                                               title: "Workout", description: "", includeDate: false)
            XCTAssertEqual(export.quality.sampleFidelity, fidelity ?? .unknown)
            XCTAssertFalse(export.quality.rangeMetricsAvailable)
            XCTAssertTrue(export.samples.allSatisfy { $0.validUntilElapsedSeconds == nil })
            XCTAssertFalse(export.intervals.contains { $0.kind == .signalLoss })
            XCTAssertEqual(export.summary.avgBPM, 137)
        }
    }

    func testFullTraceUsesThreeSecondSupportAndKnownLoss() throws {
        var record = WorkoutPageTestFixtures.record(sampleCount: 4)
        // Reduction provenance is deliberately inconsistent: it must be downgraded.
        record.originalSampleCount = 120
        let export = try WorkoutPageExport(record: record, title: "Workout", description: "", includeDate: false)
        XCTAssertEqual(export.quality.sampleFidelity, .reduced)
        XCTAssertFalse(export.quality.rangeMetricsAvailable)
        let full = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(sampleCount: 4), title: "Workout", description: "", includeDate: false)
        XCTAssertTrue(full.samples.allSatisfy { ($0.validUntilElapsedSeconds ?? .infinity) <= $0.elapsedSeconds + 3 })
        XCTAssertTrue(full.intervals.contains { $0.kind == .signalLoss })
        let lost = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(invalidatedSampleIndex: 10),
                                         title: "Workout", description: "", includeDate: false)
        XCTAssertEqual(lost.samples[10].validUntilElapsedSeconds ?? 0, 10.25, accuracy: 0.001)
        XCTAssertEqual(lost.samples[10].invalidatedAtElapsedSeconds ?? 0, 10.25, accuracy: 0.001)
    }

    func testNoHeartRateWorkoutDoesNotOfferRangeMeasurements() throws {
        let export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(sampleCount: 0), title: "Timer", description: "", includeDate: false)
        XCTAssertEqual(export.quality.sampleFidelity, .full)
        XCTAssertEqual(export.quality.exportedSampleCount, 0)
        XCTAssertFalse(export.quality.rangeMetricsAvailable)
        XCTAssertTrue(export.samples.isEmpty)
    }

    func testOldRecordsRemainUnknownAndSyncUpdatesPreserveProvenance() throws {
        let record = WorkoutPageTestFixtures.record()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.jsonString().utf8)) as? [String: Any])
        json.removeValue(forKey: "sampleFidelity")
        json.removeValue(forKey: "originalSampleCount")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeasurementDateCoding.decodingStrategy
        let legacy = try decoder.decode(WorkoutRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.resolvedSampleFidelity, .unknown)
        XCTAssertNil(legacy.originalSampleCount)
        let updated = record.updatingHealthKitSync(workoutUUID: UUID(), syncedAt: Date(), lastError: nil)
        XCTAssertEqual(updated.sampleFidelity, .full)
        XCTAssertEqual(updated.originalSampleCount, record.hrSamples.count)
    }

    func testMissingHistoricalZoneThresholdsStayMissing() throws {
        var record = WorkoutPageTestFixtures.record()
        record.zoneConfig = nil
        let export = try WorkoutPageExport(record: record, title: "Workout", description: "", includeDate: false)
        XCTAssertEqual(export.zones.count, 1)
        XCTAssertEqual(export.zones[0].durationSeconds, 100)
        XCTAssertNil(export.zones[0].lowerBPM)
        XCTAssertNil(export.zones[0].upperBPM)
    }

    func testGzipRoundTripPreservesEverySampleAndBoundedInputRejects() throws {
        let export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(sampleCount: 3_600), title: "Workout", description: "", includeDate: false)
        let original = try export.encoded()
        let compressed = try WorkoutPageCompression.gzip(original)
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(try WorkoutPageTestFixtures.ungzip(compressed), original)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutPageExport.self, from: original), export)
        XCTAssertThrowsError(try WorkoutPageCompression.gzip(Data(repeating: 1, count: WorkoutPageExport.maximumDecodedBytes + 1)))
    }

    func testUnicodeBoundsMatchTheServerAndDetailsAreNotTruncated() throws {
        XCTAssertThrowsError(try WorkoutPageExport(record: WorkoutPageTestFixtures.record(),
                                                   title: String(repeating: "😀", count: 61), description: "", includeDate: false))
        let title = String(repeating: "😀", count: 60)
        let export = try WorkoutPageExport(record: WorkoutPageTestFixtures.record(), title: title, description: "", includeDate: false)
        XCTAssertEqual(export.title, title)
    }
}
