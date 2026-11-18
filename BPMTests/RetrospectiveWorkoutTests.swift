import Foundation
import Testing
@testable import BPM

struct RetrospectiveWorkoutTests {
    @Test func availableRangesExcludeSavedTimeEvenAcrossGaps() {
        let origin = Date()
        func time(_ second: Int) -> Date { origin.addingTimeInterval(Double(second)) }
        let samples = [0, 1, 3, 4, 5, 10, 11, 12, 15, 16].map {
            HeartRateSample(value: 100, timestamp: time($0), workoutTime: nil)
        }
        let windows = RecoveryWindow.available(sessionID: UUID(), samples: samples, excluding: [
            DateInterval(start: time(8), end: time(9)),
            DateInterval(start: time(4), end: time(6)),
            DateInterval(start: time(12), end: time(15))
        ])
        #expect(windows.map(\.start) == [time(0), time(10)])
        #expect(windows.map(\.end) == [time(3), time(11)])

        let gapOnly = RecoveryWindow.available(sessionID: UUID(), samples: samples, excluding: [
            DateInterval(start: time(6), end: time(9))
        ])
        #expect(gapOnly.map(\.start) == [time(0), time(10)])
        #expect(gapOnly.map(\.end) == [time(5), time(16)])
    }

    @Test func selectionUsesObservedBoundsAndPreservesSignalLoss() throws {
        let start = Date()
        func reading(_ offset: Double, _ bpm: Int, loss: Double? = nil) -> HeartRateSample {
            HeartRateSample(value: bpm, timestamp: start.addingTimeInterval(offset), workoutTime: nil,
                            invalidatedAt: loss.map { start.addingTimeInterval($0) })
        }
        let readings = [
            reading(20, 180), reading(-2, 99), reading(0, 100, loss: 1), reading(4, 160),
            reading(12, 60), reading(18, 0),
            HeartRateSample(value: 240, timestamp: start.addingTimeInterval(10), workoutTime: nil,
                            sensorContactStatus: .notDetected)
        ]
        let id = UUID()
        let config = HeartRateZoneConfig(maxHeartRate: 200)
        let record = try #require(RetrospectiveWorkout.makeRecord(
            sessionID: id, startAt: start.addingTimeInterval(-1), endAt: start.addingTimeInterval(18),
            samples: readings, zoneConfig: config))
        #expect(record.startAt == start)
        #expect(record.endAt == start.addingTimeInterval(12))
        #expect(record.durationSeconds == 12)
        #expect(record.hrSamples.map(\.bpm) == [100, 160, 60])
        #expect(record.hrSamples.map(\.workoutTime) == [0, 4, 12])
        #expect(record.hrSamples.first?.invalidatedAt == start.addingTimeInterval(1))
        #expect(record.avgHr == 145) // 100 BPM for one second, then 160 for three.
        #expect(record.minHr == 60 && record.maxHr == 160)
        #expect(record.zones.map(\.duration) == [1, 3])
        #expect(record.originalSampleCount == 3 && record.resolvedSampleFidelity == .full)
        #expect(record.hrv == nil && record.caloriesTotal == nil && record.sets.isEmpty)
        let same = RetrospectiveWorkout.makeRecord(
            sessionID: id, startAt: start, endAt: record.endAt, samples: readings, zoneConfig: config)
        #expect(same?.id == record.id)
        let shorter = RetrospectiveWorkout.makeRecord(
            sessionID: id, startAt: start, endAt: start.addingTimeInterval(5), samples: readings, zoneConfig: config)
        #expect(shorter != nil && shorter?.id != record.id)
        #expect(RetrospectiveWorkout.makeRecord(sessionID: id, startAt: start, endAt: start,
                                                samples: readings, zoneConfig: config) == nil)
    }

    @MainActor @Test func saveRejectsOverlapsAndRetainsEditsOnRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retrospective-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "retrospective-\(UUID())")!
        let store = WorkoutStore(storeURL: url, userDefaults: defaults, iCloudStore: InMemoryICloudKeyValueStore())
        let start = Date().addingTimeInterval(-100)
        let first = try makeRecord(from: start, duration: 30)
        let saved = try await save(first, to: store)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.updateDetails(for: saved.id, title: "Morning ride", description: "Steady") {
                continuation.resume(with: $0)
            }
        }
        let retry = try await save(first, to: store)
        #expect(retry.id == first.id && retry.title == "Morning ride" && retry.notes == "Steady")
        do {
            _ = try await save(makeRecord(from: start.addingTimeInterval(20), duration: 20), to: store)
            Issue.record("An overlapping range should fail")
        } catch {
            #expect(error as? WorkoutStore.RetrospectiveSaveError == .overlapsSavedWorkout)
        }
        #expect(store.workouts.count == 1)
        let adjacent = try makeRecord(from: first.endAt, duration: 10)
        _ = try await save(adjacent, to: store)
        #expect(store.workouts.count == 2)
        defaults.set(1, forKey: WorkoutDefaultsKey.retentionDays)
        do {
            _ = try await save(makeRecord(from: start.addingTimeInterval(-172_800), duration: 20), to: store)
            Issue.record("A pruned workout must not be reported as saved")
        } catch {
            #expect(error as? WorkoutStore.RetrospectiveSaveError == .outsideRetention)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeasurementDateCoding.decodingStrategy
        let stored = try decoder.decode([WorkoutRecord].self, from: Data(contentsOf: url))
        #expect(Set(stored.map(\.id)) == [first.id, adjacent.id])
    }

    private func makeRecord(from start: Date, duration: TimeInterval) throws -> WorkoutRecord {
        let end = start.addingTimeInterval(duration)
        return try #require(RetrospectiveWorkout.makeRecord(
            sessionID: UUID(), startAt: start, endAt: end,
            samples: [HeartRateSample(value: 90, timestamp: start, workoutTime: nil),
                      HeartRateSample(value: 120, timestamp: end, workoutTime: nil)],
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190)))
    }

    private func save(_ record: WorkoutRecord, to store: WorkoutStore) async throws -> WorkoutRecord {
        try await withCheckedThrowingContinuation { continuation in
            store.saveRetrospectiveWorkout(record) { continuation.resume(with: $0) }
        }
    }
}
