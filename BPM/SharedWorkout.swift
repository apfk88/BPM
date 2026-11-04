import Foundation

enum SharedWorkoutAction: String, Codable, CaseIterable {
    case work
    case rest
    case start
    case startIncludingHistory
    case pause
    case resume
    case end
    case reset
    case cool
    case loadPreset
    case clearPreset
}

struct SharedWorkoutCommand: Codable, Equatable {
    let id: String
    let workoutID: String
    let controlRevision: String
    let action: SharedWorkoutAction
    let createdAt: Int64
    var preset: TimerPreset? = nil
}

/// Presentation data only. The broadcaster remains the source of workout measurements
/// and applies remote controls to its own timer. Saving remains local to that device.
struct SharedWorkoutSnapshot: Codable, Equatable {
    enum Screen: String, Codable { case home, workout }
    enum Page: String, Codable, CaseIterable { case table, bpm, stats, chart }

    struct Row: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        var kind: String
        var isActive: Bool
        var duration: TimeInterval
        var totalTime: TimeInterval
        var avgBPM: Int?
        var maxBPM: Int?
        var minBPM: Int?
    }

    struct ChartPoint: Codable, Equatable {
        var time: TimeInterval
        var bpm: Int
        var segment: Int
        var validUntil: TimeInterval
    }

    struct Segment: Codable, Equatable {
        var startTime: TimeInterval
        var endTime: TimeInterval
        var kind: String
    }

    struct ZoneDuration: Codable, Equatable {
        var zone: Int
        var duration: TimeInterval
    }

    var schemaVersion = 1
    var sequence: Int64 = 0
    var workoutID: String
    var controlRevision: String
    var screen: Screen
    var page: Page
    var state: TimerState
    var isCompleted: Bool
    var isPresetMode: Bool
    var canWork: Bool
    var canRest: Bool
    var totalTime: TimeInterval
    var setTime: TimeInterval
    var totalTimeAdvances: Bool
    var setTimeDirection: Int
    var showTenths: Bool
    var isEmpty: Bool
    var avgWorkTime: TimeInterval?
    var avgBPM: Int?
    var maxBPM: Int?
    var minBPM: Int?
    var zone: Int?
    var setNumber: String
    var calories: String
    var primaryBPM: String
    var rows: [Row]
    var chart: [ChartPoint]
    var segments: [Segment]
    var chartMaxTime: TimeInterval
    var zones: [ZoneDuration]
    var allowedActions: [SharedWorkoutAction]? = nil
    var activePreset: TimerPreset? = nil
    var recoverableHistorySeconds: TimeInterval? = nil

    func permits(_ action: SharedWorkoutAction) -> Bool {
        if let allowedActions { return allowedActions.contains(action) }
        // Older broadcasters advertised only manual set controls.
        guard state == .running, !isCompleted, !isPresetMode else { return false }
        switch action {
        case .work: return canWork
        case .rest: return canRest
        default: return false
        }
    }

    func totalTime(after age: TimeInterval) -> TimeInterval {
        totalTime + (totalTimeAdvances ? boundedAge(age) : 0)
    }

    func setTime(after age: TimeInterval) -> TimeInterval {
        max(0, setTime + Double(setTimeDirection) * boundedAge(age))
    }

    var rowTimeAdvances: Bool { totalTimeAdvances || setTimeDirection != 0 }

    private func boundedAge(_ age: TimeInterval) -> TimeInterval {
        age.isFinite ? min(5, max(0, age)) : 0
    }
}
