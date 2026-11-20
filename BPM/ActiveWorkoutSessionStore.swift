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

extension PersistedSetRecord {
    init(_ set: SetRecord) {
        self.init(setNumber: set.setNumber, setTime: set.setTime, heartRate: set.heartRate,
                  totalTime: set.totalTime, isRestSet: set.isRestSet, isCooldownSet: set.isCooldownSet,
                  associatedWorkSetNumber: set.associatedWorkSetNumber)
    }

    var record: SetRecord {
        SetRecord(setNumber: setNumber, setTime: setTime, heartRate: heartRate,
                  totalTime: totalTime, isRestSet: isRestSet, isCooldownSet: isCooldownSet,
                  associatedWorkSetNumber: associatedWorkSetNumber)
    }
}

/// The end of the set table just before a Work Set or Rest Set tap.
struct ManualSetChange: Codable, Equatable, Identifiable {
    let id: UUID
    let completedRowCount: Int
    let activeRestRow: PersistedSetRecord?
    let setCounter: Int
    let lastSetEndTime: TimeInterval
}

struct PersistedHeartRateSample: Codable, Equatable {
    let value: Int
    let timestamp: Date
    let workoutTime: TimeInterval?
    var invalidatedAt: Date? = nil
}

/// The active set and preset state immediately before a manual End action.
/// Measurements remain in the session; only the end action's bookkeeping is undone.
struct WorkoutEndRecovery: Codable, Equatable {
    let state: TimerState
    let stoppedAt: Date
    let sets: [PersistedSetRecord]
    let currentSetTime: TimeInterval
    let frozenElapsedTime: TimeInterval
    let isTimingRestSet: Bool
    let setCounter: Int
    let restSetCounter: Int
    let lastSetEndTime: TimeInterval
    let currentRestAssociatedWorkSetNumber: Int?
    let activePreset: TimerPreset?
    let presetPhaseTimeRemaining: TimeInterval
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

    var clockDate: Date? = nil
    var clockTicks: TimeInterval? = nil
    var clockBootSessionID: String? = nil
    var pauses: [WorkoutPause]? = nil
    var workoutStartedAt: Date? = nil
    var workoutEndedAt: Date? = nil
    var endRecovery: WorkoutEndRecovery? = nil
    var manualSetChanges: [ManualSetChange]? = nil

    var hasSession: Bool {
        startTime != nil || !sets.isEmpty || activePreset != nil || isPresetPrestartCountdownActive
    }

    func restoredClock() -> MeasurementClock {
        if let clockDate, let clockTicks, let clockBootSessionID,
           clockBootSessionID == MeasurementClock.bootSessionID, MeasurementClock.ticks >= clockTicks {
            return MeasurementClock(anchorDate: clockDate, anchorTicks: clockTicks)
        }
        return MeasurementClock()
    }

    /// Resolve recording deadlines before a restored Bluetooth connection has a live workout timer.
    func isRecordingHeartRate(at date: Date) -> Bool? {
        switch state {
        case .idle, .paused, .cooldownPaused:
            return false
        case .cooldown:
            guard let cooldownStartTime else { return nil }
            return date.timeIntervalSince(cooldownStartTime) < TimerViewModel.cooldownDuration
        case .running:
            guard let preset = activePreset else {
                return startTime != nil && !isPresetPrestartCountdownActive ? true : nil
            }
            // Pausing a preset shifts its startTime. Its total duration already includes cooldown.
            let recordingStart = isPresetPrestartCountdownActive ? presetStartCountdownEndTime : startTime
            guard let recordingStart, preset.numberOfSets > 0,
                  preset.totalDuration.isFinite, preset.totalDuration > 0 else { return nil }
            let elapsed = date.timeIntervalSince(recordingStart)
            return elapsed >= 0 && elapsed < preset.totalDuration
        }
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
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("⚠️ Failed to persist active workout session: \(error.localizedDescription)")
        }
    }

    func load() -> ActiveWorkoutSessionSnapshot? {
        do {
            return try readSnapshot()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            print("⚠️ Failed to load active workout session: \(error.localizedDescription)")
            return nil
        }
    }

    func recordingWorkoutHeartRate() -> Bool? {
        do {
            guard let snapshot = try readSnapshot() else { return nil }
            return snapshot.isRecordingHeartRate(at: snapshot.restoredClock().now())
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false
        } catch {
            // A locked, unreadable or incompatible session does not establish that the timer was idle.
            return nil
        }
    }

    private func readSnapshot() throws -> ActiveWorkoutSessionSnapshot? {
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(ActiveWorkoutSessionSnapshot.self, from: data)
        return snapshot.schemaVersion == ActiveWorkoutSessionSnapshot.currentSchemaVersion ? snapshot : nil
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
