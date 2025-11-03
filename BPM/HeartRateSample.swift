import Foundation

struct HeartRateSample: Identifiable {
    let id = UUID()
    let value: Int
    let timestamp: Date
}

