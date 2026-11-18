import XCTest
@testable import BPM

final class PassiveHeartRateArchiveTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 780_123_456.123456)
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("history.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func reading(_ bpm: Int, at seconds: Double, contact: HeartRateSensorContactStatus = .detected) -> HeartRateSample {
        HeartRateSample(value: bpm, timestamp: start.addingTimeInterval(seconds), workoutTime: nil, sensorContactStatus: contact)
    }

    func testRelaunchPreservesReadingsAndEarliestLossAndStartsNewSession() async throws {
        let clock = start.addingTimeInterval(10)
        let streamID = UUID()
        let before: [PassiveHeartRateSession]
        do {
            let writer = PassiveHeartRateArchive(databaseURL: fileURL, now: { clock })
            writer.append(reading(114, at: 0), streamID: streamID)
            writer.invalidateLastReading(at: start.addingTimeInterval(0.75), streamID: streamID)
            writer.invalidateLastReading(at: start.addingTimeInterval(0.9), streamID: streamID)
            writer.append(reading(0, at: 1), streamID: streamID)
            writer.append(reading(88, at: 2, contact: .notDetected), streamID: streamID)
            writer.append(reading(117, at: 3, contact: .unsupported), streamID: streamID)
            before = try await writer.sessions()
        }

        let reopened = PassiveHeartRateArchive(databaseURL: fileURL, now: { clock })
        reopened.append(reading(125, at: 4), streamID: streamID)
        let after = try await reopened.sessions()
        let original = try XCTUnwrap(before.first)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last?.id, original.id)
        XCTAssertEqual(original.sampleCount, 2)
        XCTAssertEqual(original.startAt, start)
        XCTAssertEqual(original.endAt, start.addingTimeInterval(3))

        let values = try await reopened.samples(for: original.id)
        XCTAssertEqual(values.map(\.value), [114, 117])
        XCTAssertEqual(values.map(\.sensorContactStatus), [.detected, .unsupported])
        XCTAssertEqual(values.first?.invalidatedAt, start.addingTimeInterval(0.75))
        XCTAssertNil(values.last?.invalidatedAt)
    }

    func testSilenceAndStreamChangesSplitSessionsWithoutManufacturingMeasurements() async throws {
        let clock = start.addingTimeInterval(100)
        let archive = PassiveHeartRateArchive(databaseURL: fileURL, now: { clock })
        let first = UUID()
        let second = UUID()
        archive.append(reading(91, at: 0), streamID: first)
        archive.append(reading(92, at: 1), streamID: first)
        archive.append(reading(93, at: 63), streamID: first)
        archive.append(reading(94, at: 64), streamID: second)
        archive.invalidateLastReading(at: start.addingTimeInterval(64.5), streamID: first)
        let sessions = try await archive.sessions()
        XCTAssertEqual(sessions.map(\.sampleCount), [1, 1, 2])
        let newest = try XCTUnwrap(sessions.first)
        let newestReadings = try await archive.samples(for: newest.id)
        XCTAssertNil(newestReadings.first?.invalidatedAt)
    }

    func testRetentionAppliesToSamplesWithinAnExistingSession() async throws {
        let streamID = UUID()
        let archive = PassiveHeartRateArchive(databaseURL: fileURL, now: { self.start })
        archive.append(reading(90, at: 0), streamID: streamID)
        archive.append(reading(100, at: 2), streamID: streamID)
        let initial = try await archive.sessions()
        let session = try XCTUnwrap(initial.first)
        let oneWeekLater = start.addingTimeInterval(Double(PassiveHeartRateArchive.retentionDays) * 86_400 + 1)
        let reopened = PassiveHeartRateArchive(databaseURL: fileURL, now: { oneWeekLater })
        let sessions = try await reopened.sessions()
        XCTAssertEqual(sessions.first?.id, session.id)
        XCTAssertEqual(sessions.first?.sampleCount, 1)
        let retained = try await reopened.samples(for: session.id)
        XCTAssertEqual(retained.map(\.value), [100])
    }
}
