#if DEBUG
import SwiftUI

/// Synthetic data used only by previews and the explicit UI-test launch argument.
enum WorkoutSharePreviewFixture {
    static let record: WorkoutRecord = {
        let start = Date(timeIntervalSince1970: 1_793_030_400)
        let duration = 2_520.0
        let samples = stride(from: 0.0, through: duration, by: 1).map { time in
            let base: Double
            if time < 300 { base = 88 + time / 300 * 48 }
            else if time > 2220 { base = 137 - (time - 2220) / 300 * 42 }
            else { base = 143 + 17 * sin(time / 90) + 5 * sin(time / 19) }
            return WorkoutHeartRateSample(timestamp: start.addingTimeInterval(time),
                                          bpm: Int(base + 2 * sin(time / 3)), workoutTime: time)
        }
        return WorkoutRecord(id: UUID(), schemaVersion: WorkoutRecord.schemaVersion,
            title: "Morning intervals", startAt: start, endAt: start.addingTimeInterval(duration),
            durationSeconds: duration, avgHr: 135, maxHr: 167, minHr: 88, hrv: nil, hrr: 28,
            caloriesTotal: 418, caloriesActive: 362, hrSamples: samples, zones: [], sets: [],
            notes: "Synthetic workout for share-card previews.", source: "preview", appVersion: "preview",
            healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
            createdAt: start, updatedAt: start, zoneConfig: HeartRateZoneConfig(maxHeartRate: 190))
    }()
}

struct WorkoutSharePreviewScene: View {
    @StateObject private var store: WorkoutStore

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutSharePreview-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "BPMSharePreview")!
        defaults.set(36_500, forKey: WorkoutDefaultsKey.retentionDays)
        let store = WorkoutStore(storeURL: root.appendingPathComponent("workouts.json"), userDefaults: defaults,
                                 iCloudStore: WorkoutSharePreviewCloud())
        store.saveWorkout(WorkoutSharePreviewFixture.record)
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        NavigationStack { WorkoutHistoryView(store: store) }
    }
}

private final class WorkoutSharePreviewCloud: ICloudKeyValueStore {
    func synchronize() -> Bool { true }
    func object(forKey aKey: String) -> Any? { nil }
    func string(forKey aKey: String) -> String? { nil }
    func bool(forKey aKey: String) -> Bool { false }
    func data(forKey aKey: String) -> Data? { nil }
    func set(_ anObject: Any?, forKey aKey: String) { }
    func removeObject(forKey aKey: String) { }
}

#Preview("Workout share card") {
    WorkoutShareCardEditor(record: WorkoutSharePreviewFixture.record, style: .chart, source: .workoutDetail)
        .preferredColorScheme(.dark)
}
#endif
