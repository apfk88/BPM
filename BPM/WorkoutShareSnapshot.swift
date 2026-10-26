import Foundation

/// A presentation-only selection in active workout time. Never edits the saved record.
struct WorkoutShareRange: Equatable {
    let start: TimeInterval
    let end: TimeInterval

    init(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        let duration = duration.isFinite ? max(0, duration) : 0
        self.start = min(max(0, start.isFinite ? start : 0), duration)
        self.end = min(max(self.start, end.isFinite ? end : duration), duration)
    }

    static func full(_ duration: TimeInterval) -> Self {
        Self(start: 0, end: duration, duration: duration)
    }

    var duration: TimeInterval { end - start }
}

struct WorkoutSharePoint: Identifiable {
    let id: Int
    let time: TimeInterval
    let bpm: Int
    let segment: Int
}

struct WorkoutShareSnapshot {
    let record: WorkoutRecord
    let range: WorkoutShareRange
    let points: [WorkoutSharePoint]
    let average: Int?
    let maximum: Int?
    let minimum: Int?
    let topZone: HeartRateZone?
    let title: String

    var isFullWorkout: Bool { range == .full(record.durationSeconds) }
    var duration: TimeInterval { range.duration }
    var activeCalories: Double? { isFullWorkout ? record.caloriesActive : nil }
    var recovery: Int? { isFullWorkout ? record.hrr : nil }
    init(record: WorkoutRecord, range requestedRange: WorkoutShareRange? = nil,
         titleOverride: String? = nil,
         fallbackZoneConfig: HeartRateZoneConfig = HeartRateZoneStorage.shared.effectiveConfig) {
        self.record = record
        title = [titleOverride, record.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Workout"
        let range = requestedRange.map {
            WorkoutShareRange(start: $0.start, end: $0.end, duration: record.durationSeconds)
        } ?? .full(record.durationSeconds)
        self.range = range
        let allPoints = Self.timeline(record)
        let selected = allPoints.filter { $0.time >= range.start && $0.time <= range.end }
        var visible = selected
        if selected.first?.time != range.start,
           let preceding = allPoints.last(where: { $0.time < range.start }),
           range.start - preceding.time < Self.freshnessInterval {
            visible.insert(WorkoutSharePoint(id: preceding.id, time: range.start, bpm: preceding.bpm, segment: preceding.segment), at: 0)
        }
        points = visible

        let zoneConfig = record.zoneConfig ?? fallbackZoneConfig
        var zoneDurations: [HeartRateZone: TimeInterval] = [:]
        var weightedTotal = 0.0
        var coveredDuration = 0.0
        for (index, point) in allPoints.enumerated() {
            let next = index + 1 < allPoints.count ? allPoints[index + 1].time : range.end
            let stop = min(range.end, next, point.time + Self.freshnessInterval)
            let weight = max(0, stop - max(range.start, point.time))
            guard weight > 0 else { continue }
            weightedTotal += Double(point.bpm) * weight
            coveredDuration += weight
            if let zone = HeartRateZone.zone(for: point.bpm, config: zoneConfig) {
                zoneDurations[zone, default: 0] += weight
            }
        }

        if range == .full(record.durationSeconds) {
            // The saved summary is authoritative, including records with reduced iCloud samples.
            average = record.avgHr
            maximum = record.maxHr
            minimum = record.minHr
            // Saved zone durations also remain authoritative when samples were reduced.
            let savedZones = record.zones.filter { $0.duration.isFinite && $0.duration > 0 && HeartRateZone(rawValue: $0.zone) != nil }
            if !savedZones.isEmpty {
                zoneDurations = [:]
                for summary in savedZones {
                    if let zone = HeartRateZone(rawValue: summary.zone) {
                        zoneDurations[zone, default: 0] += summary.duration
                    }
                }
            }
        } else {
            average = coveredDuration > 0 ? Int((weightedTotal / coveredDuration).rounded()) : selected.last?.bpm
            maximum = visible.map(\.bpm).max()
            minimum = visible.map(\.bpm).min()
        }
        // Prefer the lower zone on ties so a brief high reading never wins by order alone.
        topZone = zoneDurations.keys.sorted { $0.rawValue < $1.rawValue }.max {
            zoneDurations[$0, default: 0] < zoneDurations[$1, default: 0]
        }
    }

    // Match the live measurement freshness window. A gap must never acquire invented data.
    static let freshnessInterval = HeartRateBluetoothManager.defaultHeartRateFreshnessInterval

    static func timeline(_ record: WorkoutRecord) -> [WorkoutSharePoint] {
        let pauses = (record.pauses ?? []).filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [WorkoutPause] = []
        for pause in pauses {
            if let last = merged.last, pause.start <= last.end {
                merged[merged.count - 1] = WorkoutPause(start: last.start, end: max(last.end, pause.end))
            } else {
                merged.append(pause)
            }
        }
        let samples: [(time: TimeInterval, bpm: Int, timestamp: Date)] = record.hrSamples.compactMap { sample in
            guard sample.bpm > 0, sample.timestamp >= record.startAt, sample.timestamp <= record.endAt,
                  !merged.contains(where: { sample.timestamp >= $0.start && sample.timestamp < $0.end }) else { return nil }
            let paused = merged.reduce(0.0) { total, pause in
                total + max(0, min(sample.timestamp, pause.end).timeIntervalSince(max(record.startAt, pause.start)))
            }
            let time = sample.workoutTime ?? (sample.timestamp.timeIntervalSince(record.startAt) - paused)
            guard time.isFinite, time >= 0, time <= record.durationSeconds else { return nil }
            return (time, sample.bpm, sample.timestamp)
        }.sorted { $0.time == $1.time ? $0.timestamp < $1.timestamp : $0.time < $1.time }
        var result: [WorkoutSharePoint] = []
        var segment = 0
        for (index, sample) in samples.enumerated() {
            if index > 0 {
                let previous = samples[index - 1]
                if sample.time - previous.time > freshnessInterval ||
                    sample.timestamp.timeIntervalSince(previous.timestamp) > freshnessInterval {
                    segment += 1
                }
            }
            result.append(WorkoutSharePoint(id: index, time: sample.time, bpm: sample.bpm, segment: segment))
        }
        return result
    }

    /// Keep peaks and troughs when drawing long recordings; statistics always use all saved samples.
    var plotPoints: [WorkoutSharePoint] {
        guard points.count > 720, duration > 0 else { return points }
        let buckets = Dictionary(grouping: points) { Int(($0.time - range.start) / duration * 240) }
        return buckets.keys.sorted().flatMap { key -> [WorkoutSharePoint] in
            let bucket = buckets[key]!
            let candidates = [bucket.first!, bucket.min { $0.bpm < $1.bpm }!,
                              bucket.max { $0.bpm < $1.bpm }!, bucket.last!]
            var seen = Set<Int>()
            return candidates.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
        }
    }

    static func time(_ time: TimeInterval) -> String { HeartRateChartXAxis.label(for: time) }
}
