import Foundation

enum HeartRateChartXAxis {
    /// Budget labels against the visible plot, not the length of the entire workout.
    /// Keep ticks on a regular elapsed-time grid; never append a crowded end label.
    static func tickValues(
        through maxTime: TimeInterval,
        plotWidth: Double,
        visibleDuration: TimeInterval? = nil,
        scrollPosition: TimeInterval = 0,
        minimumLabelSpacing: Double = 64
    ) -> [TimeInterval] {
        guard maxTime.isFinite, maxTime > 0 else { return [0] }
        let requestedDuration = visibleDuration ?? maxTime
        let duration = requestedDuration.isFinite && requestedDuration > 0
            ? min(requestedDuration, maxTime) : maxTime
        let width = plotWidth.isFinite ? max(0, plotWidth) : 0
        let spacing = minimumLabelSpacing.isFinite ? max(64, minimumLabelSpacing) : 64
        let intervalCount = max(1, min(12, floor(width / spacing)))
        let minimumStep = duration / intervalCount
        let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 >= minimumStep }
            ?? (ceil(minimumStep / 3600) * 3600)
        let offset = scrollPosition.isFinite ? scrollPosition : 0
        let start = min(max(0, offset), max(0, maxTime - duration))
        let end = min(maxTime, start + duration)
        let first = ceil(start / step) * step
        guard first <= end else { return [] }
        return Array(stride(from: first, through: end, by: step))
    }

    static func label(for time: TimeInterval) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max) else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
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
