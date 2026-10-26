import XCTest
import UIKit
import SwiftUI
@testable import BPM

final class WorkoutShareSnapshotTests: XCTestCase {
    private func record(samples: [(Double, Int)], duration: Double = 600, pauses: [WorkoutPause]? = nil,
                        usesWorkoutTime: Bool = true, zones: [WorkoutZoneSummary] = [],
                        zoneConfig: HeartRateZoneConfig? = nil) -> WorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return WorkoutRecord(id: UUID(), schemaVersion: 3, title: "Intervals", startAt: start,
            endAt: start.addingTimeInterval(duration + 60), durationSeconds: duration,
            avgHr: 123, maxHr: 180, minHr: 75, hrv: nil, hrr: 25, caloriesTotal: 350, caloriesActive: 300,
            hrSamples: samples.map { WorkoutHeartRateSample(timestamp: start.addingTimeInterval($0.0),
                bpm: $0.1, workoutTime: usesWorkoutTime ? $0.0 : nil) },
            zones: zones, sets: [], notes: nil, source: "test", appVersion: "test",
            healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
            createdAt: start, updatedAt: start, pauses: pauses, zoneConfig: zoneConfig)
    }

    func testFullWorkoutKeepsStoredSummaryEvenWhenSamplesWereReduced() {
        let snapshot = WorkoutShareSnapshot(record: record(samples: [(0, 100), (30, 140)]))
        XCTAssertTrue(snapshot.isFullWorkout)
        XCTAssertEqual(snapshot.average, 123)
        XCTAssertEqual(snapshot.maximum, 180)
        XCTAssertEqual(snapshot.minimum, 75)
        XCTAssertEqual(snapshot.activeCalories, 300)
        XCTAssertEqual(snapshot.recovery, 25)
    }

    func testCardTitleOverrideIsTemporaryAndBlankFallsBackToSavedTitle() {
        let workout = record(samples: [(0, 120)])
        let original = workout.jsonString()
        let renamed = WorkoutShareSnapshot(record: workout, titleOverride: "  Tempo session\n")
        XCTAssertEqual(renamed.title, "Tempo session")
        XCTAssertEqual(renamed.record.title, "Intervals")
        XCTAssertEqual(renamed.record.jsonString(), original)
        XCTAssertEqual(WorkoutShareSnapshot(record: workout, titleOverride: " \n").title, "Intervals")
        XCTAssertEqual(WorkoutShareSnapshot(record: workout).title, "Intervals")
    }

    func testTrimExcludesWarmupAndCooldownAndWeightsIrregularSamples() {
        let workout = record(samples: [(0, 80), (100, 120), (101, 160), (104, 140), (500, 90)])
        let snapshot = WorkoutShareSnapshot(record: workout, range: .init(start: 100, end: 106, duration: 600))
        XCTAssertEqual(snapshot.duration, 6)
        XCTAssertEqual(snapshot.average, 147) // (120 × 1 + 160 × 3 + 140 × 2) / 6
        XCTAssertEqual(snapshot.maximum, 160)
        XCTAssertEqual(snapshot.minimum, 120)
        XCTAssertEqual(snapshot.points.map(\.time), [100, 101, 104])
        XCTAssertNil(snapshot.activeCalories)
        XCTAssertNil(snapshot.recovery)
        XCTAssertEqual(workout.durationSeconds, 600)
        XCTAssertEqual(workout.hrSamples.count, 5)
    }

    func testGapDoesNotExtendReadingOrConnectChart() {
        let snapshot = WorkoutShareSnapshot(record: record(samples: [(10, 100), (90, 180)]),
            range: .init(start: 10, end: 91, duration: 600))
        XCTAssertEqual(snapshot.average, 120) // 3 seconds at 100, 1 second at 180.
        XCTAssertNotEqual(snapshot.points[0].segment, snapshot.points[1].segment)
    }

    func testEmptySelectionAndSingleSample() {
        let workout = record(samples: [(10, 110)])
        let empty = WorkoutShareSnapshot(record: workout, range: .init(start: 20, end: 30, duration: 600))
        XCTAssertNil(empty.average)
        XCTAssertNil(empty.maximum)
        XCTAssertNil(empty.minimum)
        let single = WorkoutShareSnapshot(record: workout, range: .init(start: 5, end: 10, duration: 600))
        XCTAssertEqual(single.average, 110)
        XCTAssertEqual(single.maximum, 110)
    }

    func testLegacyTimestampsSubtractPausesAndRejectPausedSamples() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let pause = WorkoutPause(start: start.addingTimeInterval(20), end: start.addingTimeInterval(80))
        let workout = record(samples: [(10, 100), (40, 220), (80, 140), (90, 150)],
                             pauses: [pause], usesWorkoutTime: false)
        let snapshot = WorkoutShareSnapshot(record: workout, range: .init(start: 19, end: 31, duration: 600))
        XCTAssertEqual(snapshot.points.map(\.time), [20, 30])
        XCTAssertEqual(snapshot.maximum, 150)
    }

    func testInvalidSamplesAndBoundsAreSafe() {
        let snapshot = WorkoutShareSnapshot(record: record(samples: [(-5, 99), (10, 0), (20, -1), (601, 130), (5, 120)]))
        XCTAssertEqual(snapshot.points.map(\.bpm), [120])
        XCTAssertEqual(WorkoutShareRange(start: -20, end: 700, duration: 600), .full(600))
        XCTAssertEqual(WorkoutShareRange(start: 500, end: 100, duration: 600).duration, 0)
        XCTAssertEqual(WorkoutShareRange.full(.nan).duration, 0)
    }

    func testTopZoneUsesTimeRatherThanHighestReadingOrSampleCount() {
        let workout = record(samples: [(0, 180), (0.1, 180), (0.2, 180), (0.3, 120), (3.3, 120), (6.3, 180)],
                             zoneConfig: HeartRateZoneConfig(maxHeartRate: 200))
        let snapshot = WorkoutShareSnapshot(record: workout, range: .init(start: 0, end: 7, duration: 600))
        XCTAssertEqual(snapshot.topZone, .zone2)
        let intense = WorkoutShareSnapshot(record: workout, range: .init(start: 6.3, end: 7, duration: 600))
        XCTAssertEqual(intense.topZone, .zone5)
    }

    func testTopZoneUsesSavedSummaryAndSavedThresholdsForSelectedRange() {
        let workout = record(samples: [(10, 140), (11, 140)], zones: [
            .init(id: UUID(), zone: 2, duration: 400), .init(id: UUID(), zone: 5, duration: 10)
        ], zoneConfig: HeartRateZoneConfig(maxHeartRate: 200))
        XCTAssertEqual(WorkoutShareSnapshot(record: workout).topZone, .zone2)
        let selected = WorkoutShareSnapshot(record: workout, range: .init(start: 10, end: 12, duration: 600),
                                           fallbackZoneConfig: HeartRateZoneConfig(maxHeartRate: 160))
        XCTAssertEqual(selected.topZone, .zone3)
    }

    func testTopZoneDoesNotFillGapsAndUsesLowerZoneForEqualTime() {
        let workout = record(samples: [(0, 120), (50, 180)], zoneConfig: HeartRateZoneConfig(maxHeartRate: 200))
        let selected = WorkoutShareSnapshot(record: workout, range: .init(start: 0, end: 53, duration: 600))
        XCTAssertEqual(selected.topZone, .zone2)
        let empty = WorkoutShareSnapshot(record: workout, range: .init(start: 10, end: 40, duration: 600))
        XCTAssertNil(empty.topZone)
    }

    func testPlotReductionPreservesPeakAndOriginalStatistics() {
        var samples = (0...2000).map { (Double($0), 120) }
        samples[1234].1 = 190
        samples[1235].1 = 80
        let snapshot = WorkoutShareSnapshot(record: record(samples: samples, duration: 2000),
            range: .init(start: 1, end: 1999, duration: 2000))
        XCTAssertEqual(snapshot.maximum, 190)
        XCTAssertEqual(snapshot.minimum, 80)
        XCTAssertTrue(snapshot.plotPoints.contains { $0.bpm == 190 })
        XCTAssertTrue(snapshot.plotPoints.contains { $0.bpm == 80 })
        XCTAssertLessThan(snapshot.plotPoints.count, snapshot.points.count)
    }

    @MainActor func testBothStylesExportFullSizeImagesForFullAndTrimmedWorkouts() throws {
        XCTAssertNotNil(ShareSheet.appIconImage(), "Use the actual bundled BPM app icon.")
        let record = WorkoutSharePreviewFixture.record
        for style in WorkoutShareStyle.allCases {
            for range in [WorkoutShareRange.full(record.durationSeconds), .init(start: 300, end: 2220, duration: record.durationSeconds)] {
                let snapshot = WorkoutShareSnapshot(record: record, range: range)
                let image = try XCTUnwrap(WorkoutShareCardRenderer.image(snapshot: snapshot, style: style))
                XCTAssertEqual(image.cgImage?.width, 1080)
                XCTAssertEqual(image.cgImage?.height, 1350)
                XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
                let item = try WorkoutShareImageItem(image: image, title: snapshot.title)
                let attachmentImage = try XCTUnwrap(UIImage(contentsOfFile: item.fileURL.path))
                XCTAssertEqual(attachmentImage.cgImage?.width, 1080)
                XCTAssertEqual(attachmentImage.cgImage?.height, 1350)
                try FileManager.default.removeItem(at: item.fileURL)
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(style.rawValue)-\(snapshot.isFullWorkout ? "full" : "trimmed")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let preview = HStack(spacing: 20) {
            WorkoutShareCard(snapshot: WorkoutShareSnapshot(record: record), style: .chart)
            WorkoutShareCard(snapshot: WorkoutShareSnapshot(record: record,
                range: .init(start: 300, end: 2220, duration: record.durationSeconds)), style: .stats)
        }
        .padding(20)
        .background(Color.black)
        let comparison = ImageRenderer(content: preview)
        comparison.scale = 1.5
        let attachment = XCTAttachment(image: try XCTUnwrap(comparison.uiImage))
        attachment.name = "Workout share card designs"
        attachment.lifetime = .keepAlways
        add(attachment)
        let historyPreview = HStack(spacing: 20) {
            WorkoutShareCard(snapshot: WorkoutShareSnapshot(record: record), style: .chart, compact: true)
            WorkoutShareCard(snapshot: WorkoutShareSnapshot(record: record), style: .stats, compact: true)
        }.padding(20).background(Color.black)
        let historyImage = ImageRenderer(content: historyPreview)
        let historyAttachment = XCTAttachment(image: try XCTUnwrap(historyImage.uiImage))
        historyAttachment.name = "Workout history card designs"
        historyAttachment.lifetime = .keepAlways
        add(historyAttachment)

        let longTitle = WorkoutShareSnapshot(record: record,
            titleOverride: "Morning strength and endurance intervals")
        let longTitlePreview = HStack(spacing: 20) {
            WorkoutShareCard(snapshot: longTitle, style: .chart)
            WorkoutShareCard(snapshot: longTitle, style: .stats)
        }.padding(20).background(Color.black)
        let renderer = ImageRenderer(content: longTitlePreview)
        renderer.scale = 1.5
        let longTitleAttachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        longTitleAttachment.name = "Workout cards with long title"
        longTitleAttachment.lifetime = .keepAlways
        add(longTitleAttachment)
    }
}
