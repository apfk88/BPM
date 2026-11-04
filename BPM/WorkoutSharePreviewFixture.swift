#if DEBUG
import SwiftUI

/// Synthetic data used only by previews and the explicit UI-test launch argument.
enum WorkoutSharePreviewFixture {
    static let record = makeRecord()
    static let noHeartRateRecord = makeRecord(includesHeartRate: false)

    private static func makeRecord(includesHeartRate: Bool = true) -> WorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_793_030_400)
        let duration = 2_520.0
        let config = HeartRateZoneConfig(maxHeartRate: 190)
        let samples: [WorkoutHeartRateSample] = includesHeartRate ? stride(from: 0.0, through: duration, by: 1).map { time in
            let base: Double
            if time < 300 { base = 88 + time / 300 * 48 }
            else if time > 2220 { base = 137 - (time - 2220) / 300 * 42 }
            else { base = 143 + 17 * sin(time / 90) + 5 * sin(time / 19) }
            return WorkoutHeartRateSample(timestamp: start.addingTimeInterval(time),
                                          bpm: Int(base + 2 * sin(time / 3)), workoutTime: time)
        } : []
        // Each sample covers the following second; the last sample is the endpoint.
        let zoneDurations = samples.dropLast().reduce(into: [HeartRateZone: TimeInterval]()) { result, sample in
            if let zone = HeartRateZone.zone(for: sample.bpm, config: config) {
                result[zone, default: 0] += 1
            }
        }
        let zones = HeartRateZone.allCases.compactMap { zone -> WorkoutZoneSummary? in
            guard let duration = zoneDurations[zone], duration > 0 else { return nil }
            return WorkoutZoneSummary(id: UUID(), zone: zone.rawValue, duration: duration)
        }
        func set(_ label: String, from lower: TimeInterval, to upper: TimeInterval,
                 rest: Bool = false, cooldown: Bool = false, workNumber: Int? = nil) -> WorkoutSetSummary {
            let values = samples.filter {
                let time = $0.workoutTime ?? 0
                return time >= lower && time < upper
            }.map(\.bpm)
            let average = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            return WorkoutSetSummary(id: UUID(), label: label, setTime: upper - lower, totalTime: upper,
                                     isRestSet: rest, isCooldownSet: cooldown,
                                     associatedWorkSetNumber: workNumber,
                                     avgBpm: average, minBpm: values.min(), maxBpm: values.max())
        }
        let sets = [
            set("Warm-up", from: 0, to: 300),
            set("1", from: 300, to: 900),
            set("1R", from: 900, to: 1020, rest: true, workNumber: 1),
            set("2", from: 1020, to: 1620),
            set("2R", from: 1620, to: 1740, rest: true, workNumber: 2),
            set("3", from: 1740, to: 2220),
            set("Cooldown", from: 2220, to: duration, rest: true, cooldown: true)
        ]
        return WorkoutRecord(id: UUID(), schemaVersion: WorkoutRecord.schemaVersion,
            title: "Morning intervals", startAt: start, endAt: start.addingTimeInterval(duration),
            durationSeconds: duration, avgHr: includesHeartRate ? 135 : nil,
            maxHr: includesHeartRate ? 167 : nil, minHr: includesHeartRate ? 88 : nil,
            hrv: nil, hrr: includesHeartRate ? 28 : nil,
            caloriesTotal: includesHeartRate ? 418 : nil, caloriesActive: includesHeartRate ? 362 : nil,
            hrSamples: samples, zones: zones, sets: sets,
            notes: "Synthetic workout for share-card previews.", source: "preview", appVersion: "preview",
            healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
            createdAt: start, updatedAt: start, zoneConfig: config)
    }
}

struct WorkoutSharePreviewScene: View {
    @StateObject private var store: WorkoutStore

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutSharePreview-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "BPMSharePreview")!
        defaults.set(36_500, forKey: WorkoutDefaultsKey.retentionDays)
        let store = WorkoutStore(storeURL: root.appendingPathComponent("workouts.json"), userDefaults: defaults,
                                 iCloudStore: WorkoutSharePreviewCloud())
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains("--workout-history-empty") {
            let record = arguments.contains("--workout-history-no-heart-rate")
                ? WorkoutSharePreviewFixture.noHeartRateRecord : WorkoutSharePreviewFixture.record
            store.saveWorkout(record)
        }
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
    @Previewable @State var accent: WorkoutShareAccent = .white
    WorkoutShareCardEditor(record: WorkoutSharePreviewFixture.record, style: .chart, source: .workoutDetail,
                           accent: $accent)
        .preferredColorScheme(.dark)
}
#endif
