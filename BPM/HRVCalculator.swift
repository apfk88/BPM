import Foundation

enum HRVCalculator {
    /// RMSSD in milliseconds, using every adjacent pair in the original beat order.
    /// Never derive these intervals from rounded BPM or join across removed beats.
    static func rmssd(_ intervals: [Double]) -> Double? {
        guard intervals.count >= 2,
              intervals.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sum = zip(intervals, intervals.dropFirst()).reduce(0.0) {
            let difference = $1.1 - $1.0
            return $0 + difference * difference
        }
        let result = sqrt(sum / Double(intervals.count - 1))
        return result.isFinite ? result : nil
    }

    /// Conservative acquisition checks, not ECG beat classification or clinical validation.
    /// Reject a suspect recording instead of silently changing its variability.
    static func qualityError(intervals: [RRInterval], start: TimeInterval, duration: TimeInterval) -> String? {
        let retry = "Keep still, check your strap contact, and measure again."
        guard intervals.count >= 30, let first = intervals.first, let last = intervals.last else {
            return "Not enough beat intervals for HRV. \(retry)"
        }
        let values = intervals.map(\.value)
        guard values.allSatisfy({ $0.isFinite && (250...2500).contains($0) }) else {
            return "Unreliable beat intervals detected. \(retry)"
        }
        let coverage = values.reduce(0, +) / 1000
        guard first.receivedTicks - start <= 5,
              start + duration - last.receivedTicks <= 5,
              abs(coverage - duration) <= 5,
              zip(intervals, intervals.dropFirst()).allSatisfy({
                  let gap = $1.receivedTicks - $0.receivedTicks
                  return gap >= 0 && gap <= 5
              }) else {
            return "Beat data was interrupted or incomplete. \(retry)"
        }
        for index in values.indices {
            let neighbors = values[max(0, index - 5)...min(values.count - 1, index + 5)].sorted()
            let median = neighbors[neighbors.count / 2]
            if abs(values[index] - median) / median > 0.30 {
                return "Beat intervals varied too abruptly for a reliable result. \(retry)"
            }
        }
        return nil
    }
}
