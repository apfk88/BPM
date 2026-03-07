import Foundation

struct PersistedSetRecord: Codable, Equatable {
    let setNumber: Int
    let setTime: TimeInterval
    let heartRate: Int?
    let totalTime: TimeInterval
    let isRestSet: Bool
    let isCooldownSet: Bool
    let associatedWorkSetNumber: Int?
}

struct PersistedHeartRateSample: Codable, Equatable {
    let value: Int
    let timestamp: Date
    let workoutTime: TimeInterval?
}

struct ActiveWorkoutSessionSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: TimerState
    let elapsedTime: TimeInterval
    let currentSetTime: TimeInterval
    let sets: [PersistedSetRecord]
    let cooldownTime: TimeInterval
    let frozenElapsedTime: TimeInterval
    let isTimingRestSet: Bool
    let activePreset: TimerPreset?
    let presetPhase: PresetPhase
    let presetCurrentSet: Int
    let presetPhaseTimeRemaining: TimeInterval
    let isPresetPrestartCountdownActive: Bool
    let defaultWorkoutTitle: String?
    let startTime: Date?
    let pauseStartTime: Date?
    let cooldownStartTime: Date?
    let cooldownPauseStartTime: Date?
    let setCounter: Int
    let restSetCounter: Int
    let lastSetEndTime: TimeInterval
    let currentRestAssociatedWorkSetNumber: Int?
    let restStartTime: Date?
    let heartRateSamples: [PersistedHeartRateSample]
    let cooldownStartHeartRate: Int?
    let cooldownEndHeartRate: Int?
    let presetPhaseStartTime: Date?
    let presetStartCountdownRemainingOnPause: TimeInterval
    let presetStartCountdownEndTime: Date?

    var hasSession: Bool {
        startTime != nil || !sets.isEmpty || activePreset != nil || isPresetPrestartCountdownActive
    }
}

final class ActiveWorkoutSessionStore {
    static let shared = ActiveWorkoutSessionStore()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = ActiveWorkoutSessionStore.defaultStoreURL()) {
        self.fileURL = fileURL
    }

    func save(_ snapshot: ActiveWorkoutSessionSnapshot) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to persist active workout session: \(error.localizedDescription)")
        }
    }

    func load() -> ActiveWorkoutSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(ActiveWorkoutSessionSnapshot.self, from: data)
            guard snapshot.schemaVersion == ActiveWorkoutSessionSnapshot.currentSchemaVersion else {
                clear()
                return nil
            }
            return snapshot
        } catch {
            clear()
            print("⚠️ Failed to load active workout session: \(error.localizedDescription)")
            return nil
        }
    }

    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directory = support?.appendingPathComponent("BPM", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory.appendingPathComponent("active-workout-session.json")
    }
}
