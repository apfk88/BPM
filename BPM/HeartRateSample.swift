import Foundation

enum HeartRateSensorContactStatus: String, Codable, Equatable {
    case unsupported
    case detected
    case notDetected
}

struct HeartRateSample: Identifiable {
    let id = UUID()
    let value: Int
    let timestamp: Date
    let workoutTime: TimeInterval? // Optional workout time (excluding pauses) for chart display
    let sensorContactStatus: HeartRateSensorContactStatus
    // Explicit loss of valid signal ends this reading's support before freshness expires.
    // This is acquisition metadata; the actual measured BPM remains unchanged.
    var invalidatedAt: Date?

    init(
        value: Int,
        timestamp: Date,
        workoutTime: TimeInterval?,
        sensorContactStatus: HeartRateSensorContactStatus = .unsupported,
        invalidatedAt: Date? = nil
    ) {
        self.value = value
        self.timestamp = timestamp
        self.workoutTime = workoutTime
        self.sensorContactStatus = sensorContactStatus
        self.invalidatedAt = invalidatedAt
    }
}
