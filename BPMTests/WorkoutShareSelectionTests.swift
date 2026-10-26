import XCTest
import SwiftUI
@testable import BPM

final class WorkoutShareSelectionTests: XCTestCase {
    func testTrimRecalculatesWeightedStatsAndOmitsWholeWorkoutMetrics() {
        let record = fixture(duration: 10, samples: [(0, 90), (2, 150), (4, 170), (7, 130), (8, 110)])
        let snapshot = WorkoutShareSnapshot(record: record, range: .init(start: 2, end: 8, duration: 10))
        XCTAssertEqual(snapshot.duration, 6)
        XCTAssertEqual(snapshot.average, 157)
        XCTAssertEqual(snapshot.maximum, 170)
        XCTAssertEqual(snapshot.minimum, 110)
        XCTAssertNil(snapshot.activeCalories)
        XCTAssertNil(snapshot.recovery)
        XCTAssertEqual(snapshot.points.first?.time, 2)
        XCTAssertEqual(snapshot.points.last?.time, 8)
        XCTAssertEqual(record.durationSeconds, 10)
        XCTAssertEqual(record.hrSamples.count, 5)
    }

    func testRangeBetweenReadingsUsesOnlyStillFreshPrecedingReading() {
        let record = fixture(duration: 20, samples: [(0, 100), (2, 150), (10, 180)])
        let fresh = WorkoutShareSnapshot(record: record, range: .init(start: 2.5, end: 3.5, duration: 20))
        XCTAssertEqual(fresh.average, 150)
        XCTAssertEqual(fresh.minimum, 150)
        XCTAssertEqual(fresh.maximum, 150)
        XCTAssertEqual(fresh.points.first?.time, 2.5)
        let stale = WorkoutShareSnapshot(record: record, range: .init(start: 6, end: 9, duration: 20))
        XCTAssertNil(stale.average)
        XCTAssertNil(stale.minimum)
        XCTAssertNil(stale.maximum)
        XCTAssertTrue(stale.points.isEmpty)
    }

    func testFullWorkoutKeepsSavedSummaryForDownsampledHistory() {
        let record = fixture(duration: 300, samples: [(0, 100), (200, 140)])
        let snapshot = WorkoutShareSnapshot(record: record)
        XCTAssertEqual(snapshot.average, 142)
        XCTAssertEqual(snapshot.maximum, 181)
        XCTAssertEqual(snapshot.minimum, 82)
        XCTAssertEqual(snapshot.activeCalories, 354)
        XCTAssertEqual(snapshot.recovery, 28)
        XCTAssertTrue(snapshot.isFullWorkout)
    }

    func testLegacyTimelineRemovesPausedSamplesAndOverlappingPauseTime() {
        var record = fixture(duration: 20, samples: [])
        let start = record.startAt
        record.pauses = [WorkoutPause(start: start.addingTimeInterval(4), end: start.addingTimeInterval(8)),
                         WorkoutPause(start: start.addingTimeInterval(6), end: start.addingTimeInterval(10))]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var json = try! JSONSerialization.jsonObject(with: Data(record.jsonString().utf8)) as! [String: Any]
        let formatter = ISO8601DateFormatter()
        json["hrSamples"] = [(2, 100), (5, 200), (12, 150)].map { offset, bpm in
            ["timestamp": formatter.string(from: start.addingTimeInterval(Double(offset))), "bpm": bpm] as [String: Any]
        }
        let legacy = try! decoder.decode(WorkoutRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let points = WorkoutShareSnapshot.timeline(legacy)
        XCTAssertEqual(points.map(\.time), [2, 6])
        XCTAssertEqual(points.map(\.bpm), [100, 150])
        XCTAssertNotEqual(points.first?.segment, points.last?.segment)
    }

    func testInvalidRangeIsClampedAndEmptySignalHasNoInventedStats() {
        let range = WorkoutShareRange(start: -100, end: 500, duration: 20)
        XCTAssertEqual(range, .full(20))
        let record = fixture(duration: 20, samples: [])
        let empty = WorkoutShareSnapshot(record: record, range: .init(start: 5, end: 10, duration: 20))
        XCTAssertNil(empty.average)
        XCTAssertNil(empty.minimum)
        XCTAssertTrue(empty.points.isEmpty)
        XCTAssertEqual(WorkoutShareRange(start: .nan, end: .infinity, duration: 20), .full(20))
    }

    @MainActor func testBothCardImagesAndHistoryLayoutsRender() throws {
        let samples = (0...1800).map { second -> (Double, Int) in
            let base = second < 240 ? 85 + Double(second) / 5 : (second > 1500 ? 165 - Double(second - 1500) / 5 : 158)
            return (Double(second), Int(base + 8 * sin(Double(second) / 35)))
        }
        let record = fixture(duration: 1800, samples: samples)
        for style in WorkoutShareStyle.allCases {
            let snapshot = WorkoutShareSnapshot(record: record)
            let image = try XCTUnwrap(WorkoutShareCardRenderer.image(snapshot: snapshot, style: style))
            XCTAssertEqual(image.cgImage?.width, 1080)
            XCTAssertEqual(image.cgImage?.height, 1350)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Workout share \(style.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Workout-\(style.rawValue).png")
            try image.pngData()?.write(to: url)
            print("CARD_PREVIEW_PATH \(url.path)")
            let trimmed = WorkoutShareSnapshot(record: record, range: .init(start: 240, end: 1500, duration: 1800))
            let trimmedImage = try XCTUnwrap(WorkoutShareCardRenderer.image(snapshot: trimmed, style: style))
            XCTAssertNotEqual(image.pngData(), trimmedImage.pngData())
            let compact = ImageRenderer(content: WorkoutShareCard(snapshot: snapshot, style: style, compact: true))
            XCTAssertNotNil(compact.uiImage)
        }
    }

    private func fixture(duration: Double, samples: [(Double, Int)]) -> WorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_793_008_800)
        return WorkoutRecord(id: UUID(), schemaVersion: WorkoutRecord.schemaVersion, title: "Morning strength",
                             startAt: start, endAt: start.addingTimeInterval(duration), durationSeconds: duration,
                             avgHr: 142, maxHr: 181, minHr: 82, hrv: nil, hrr: 28,
                             caloriesTotal: 418, caloriesActive: 354,
                             hrSamples: samples.map { .init(timestamp: start.addingTimeInterval($0.0), bpm: $0.1, workoutTime: $0.0) },
                             zones: [], sets: [], notes: "Private note, excluded from cards", source: "phone", appVersion: "test",
                             healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
                             createdAt: start, updatedAt: start)
    }
}
