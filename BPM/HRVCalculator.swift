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

    /// Fixed diagnostics describe acquisition failures without exporting beat data.
    enum QualityIssue: String, CaseIterable {
        case invalidWindow = "invalid_window"
        case insufficientIntervals = "insufficient_intervals"
        case invalidInterval = "invalid_interval"
        case invalidTimestamp = "invalid_timestamp"
        case outsideWindow = "outside_window"
        case lateStart = "late_start"
        case earlyEnd = "early_end"
        case coverageMismatch = "coverage_mismatch"
        case receiptOrder = "receipt_order"
        case receiptGap = "receipt_gap"
        case rollingCoverageMismatch = "rolling_coverage_mismatch"
        case abruptVariation = "abrupt_variation"

        var message: String {
            let retry = "Keep still, check your strap contact, and measure again."
            switch self {
            case .insufficientIntervals:
                return "Not enough beat intervals for HRV. \(retry)"
            case .invalidInterval:
                return "Unreliable beat intervals detected. \(retry)"
            case .abruptVariation:
                return "Beat intervals varied too abruptly for a reliable result. \(retry)"
            default:
                return "Beat data was interrupted or incomplete. \(retry)"
            }
        }
    }

    /// Conservative acquisition checks, not ECG beat classification or clinical validation.
    /// Reject a suspect recording instead of silently changing its variability.
    static func qualityIssue(intervals: [RRInterval], start: TimeInterval, duration: TimeInterval) -> QualityIssue? {
        guard start.isFinite, duration.isFinite, duration > 0 else { return .invalidWindow }
        guard intervals.count >= 30, let first = intervals.first, let last = intervals.last else {
            return .insufficientIntervals
        }
        let values = intervals.map(\.value)
        guard values.allSatisfy({ $0.isFinite && (250...2500).contains($0) }) else {
            return .invalidInterval
        }
        guard intervals.allSatisfy({ $0.receivedTicks.isFinite }) else { return .invalidTimestamp }
        guard intervals.allSatisfy({ $0.receivedTicks > start && $0.receivedTicks <= start + duration }) else {
            return .outsideWindow
        }
        guard first.receivedTicks - start <= 5 else { return .lateStart }
        guard start + duration - last.receivedTicks <= 5 else { return .earlyEnd }
        let coverage = values.reduce(0, +) / 1000
        guard abs(coverage - duration) <= 5 else { return .coverageMismatch }
        for (previous, next) in zip(intervals, intervals.dropFirst()) {
            let gap = next.receivedTicks - previous.receivedTicks
            guard gap >= 0 else { return .receiptOrder }
            guard gap <= 5 else { return .receiptGap }
        }

        // Check coverage throughout the recording, not only the final sum. Missing
        // beats in one part must not be cancelled by extra intervals in another.
        // A notification can contain several intervals with the same receipt time;
        // compare only after its final interval. The five-second allowance is the
        // same acquisition tolerance used above, not a clinical quality threshold.
        var elapsedBeatTime: TimeInterval = 0
        for index in intervals.indices {
            elapsedBeatTime += intervals[index].value / 1000
            let isPacketEnd = index == intervals.count - 1
                || intervals[index + 1].receivedTicks != intervals[index].receivedTicks
            if isPacketEnd && abs(elapsedBeatTime - (intervals[index].receivedTicks - start)) > 5 {
                return .rollingCoverageMismatch
            }
        }
        for index in values.indices {
            let neighbors = values[max(0, index - 5)...min(values.count - 1, index + 5)].sorted()
            let median = neighbors[neighbors.count / 2]
            if abs(values[index] - median) / median > 0.30 {
                return .abruptVariation
            }
        }
        return nil
    }

    static func qualityError(intervals: [RRInterval], start: TimeInterval, duration: TimeInterval) -> String? {
        qualityIssue(intervals: intervals, start: start, duration: duration)?.message
    }
}
