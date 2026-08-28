import Foundation

enum HeartRateChartXAxis {
    static let detailedTickInterval: TimeInterval = 30
    static let detailedVisibleDuration: TimeInterval = 60

    static func usesDetailedMarks(
        visibleDuration: TimeInterval,
        allowsHorizontalScrolling: Bool
    ) -> Bool {
        allowsHorizontalScrolling && visibleDuration <= detailedVisibleDuration
    }

    static func label(for time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if seconds == 0 {
            return "\(minutes)m"
        }
        if minutes == 0 {
            return "\(seconds)s"
        }
        return "\(minutes)m\(seconds)s"
    }
}

enum HeartRateChartPeaks {
    static let targetLabelsPerVisibleDomain = 5.0
    static let minimumBucketDuration: TimeInterval = 15

    static func majorPeaks(
        in dataPoints: [HeartRateChartDataPoint],
        visibleDuration: TimeInterval
    ) -> [HeartRateChartDataPoint] {
        guard dataPoints.count >= 3 else { return [] }

        let sortedPoints = dataPoints.sorted { $0.time < $1.time }
        let localPeaks = sortedPoints.indices.dropFirst().dropLast().compactMap { index in
            let previous = sortedPoints[index - 1]
            let current = sortedPoints[index]
            let next = sortedPoints[index + 1]
            let isPeak = current.bpm >= previous.bpm && current.bpm > next.bpm
            return isPeak ? current : nil
        }
        let bucketDuration = max(
            minimumBucketDuration,
            visibleDuration / targetLabelsPerVisibleDomain
        )

        let peaksByBucket = localPeaks.reduce(into: [Int: HeartRateChartDataPoint]()) { result, point in
            let bucket = Int(floor(point.time / bucketDuration))
            guard let existing = result[bucket] else {
                result[bucket] = point
                return
            }
            if point.bpm > existing.bpm {
                result[bucket] = point
            }
        }

        return peaksByBucket.values.sorted { $0.time < $1.time }
    }
}
