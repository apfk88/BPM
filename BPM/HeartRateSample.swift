import Foundation

struct HeartRateSample: Identifiable {
    let id = UUID()
    let value: Int
    let timestamp: Date
    let workoutTime: TimeInterval? // Optional workout time (excluding pauses) for chart display
}

