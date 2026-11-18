import CryptoKit
import Foundation

enum RetrospectiveWorkout {
    static func makeRecord(
        sessionID: UUID,
        startAt: Date,
        endAt: Date,
        samples: [HeartRateSample],
        zoneConfig: HeartRateZoneConfig
    ) -> WorkoutRecord? {
        let selected = samples.filter {
            $0.value > 0 && $0.sensorContactStatus != .notDetected &&
            $0.timestamp.timeIntervalSinceReferenceDate.isFinite &&
            $0.timestamp >= startAt && $0.timestamp <= endAt
        }.sorted { $0.timestamp < $1.timestamp }
        guard let first = selected.first, let last = selected.last, last.timestamp > first.timestamp else {
            return nil
        }

        let start = first.timestamp
        let end = last.timestamp
        let duration = end.timeIntervalSince(start)
        let readings = selected.map { sample in
            WorkoutHeartRateSample(timestamp: sample.timestamp, bpm: sample.value,
                                   workoutTime: sample.timestamp.timeIntervalSince(start),
                                   invalidatedAt: sample.invalidatedAt.flatMap { loss in
                                       loss <= end ? max(loss, sample.timestamp) : nil
                                   })
        }
        var zoneDurations: [HeartRateZone: TimeInterval] = [:]
        var weightedBPM = 0.0
        var covered = 0.0
        for (sample, next) in zip(readings, readings.dropFirst()) {
            // Use the same support window as the live workout. A disconnected strap
            // still contributes to elapsed time, but no heart rate is assigned to the gap.
            let stop = min(next.timestamp, sample.invalidatedAt ?? end,
                           sample.timestamp.addingTimeInterval(HeartRateBluetoothManager.defaultHeartRateFreshnessInterval))
            let weight = stop.timeIntervalSince(sample.timestamp)
            guard weight > 0 else { continue }
            weightedBPM += Double(sample.bpm) * weight
            covered += weight
            if let zone = HeartRateZone.zone(for: sample.bpm, config: zoneConfig) {
                zoneDurations[zone, default: 0] += weight
            }
        }
        let zones = HeartRateZone.allCases.compactMap { zone -> WorkoutZoneSummary? in
            guard let duration = zoneDurations[zone] else { return nil }
            return WorkoutZoneSummary(id: UUID(), zone: zone.rawValue, duration: duration)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let now = Date()
        return WorkoutRecord(
            id: recordID(sessionID: sessionID, start: start, end: end),
            schemaVersion: WorkoutRecord.schemaVersion, title: nil,
            startAt: start, endAt: end, durationSeconds: duration,
            avgHr: covered > 0 ? Int((weightedBPM / covered).rounded()) : last.value,
            maxHr: selected.map(\.value).max(), minHr: selected.map(\.value).min(),
            hrv: nil, hrr: nil, caloriesTotal: nil, caloriesActive: nil,
            hrSamples: readings, zones: zones, sets: [], notes: nil, source: "monitorHistory",
            appVersion: "\(version) (\(build))", healthKitWorkoutUUID: nil, healthKitSyncedAt: nil,
            healthKitLastError: nil, createdAt: now, updatedAt: now, zoneConfig: zoneConfig,
            sampleFidelity: .full, originalSampleCount: readings.count
        )
    }

    private static func recordID(sessionID: UUID, start: Date, end: Date) -> UUID {
        // Identical readings selected through different UI bounds represent one workout.
        let first = start.timeIntervalSinceReferenceDate.bitPattern
        let last = end.timeIntervalSinceReferenceDate.bitPattern
        let identity = "\(sessionID.uuidString)/\(first)/\(last)"
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUIDv8, application-defined payload.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
