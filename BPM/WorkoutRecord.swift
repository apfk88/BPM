import Foundation

struct WorkoutHeartRateSample: Codable {
    let timestamp: Date
    let bpm: Int
    let workoutTime: TimeInterval?
}

struct WorkoutZoneSummary: Codable, Identifiable {
    let id: UUID
    let zone: Int
    let duration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case id, zone, duration
    }

    init(id: UUID, zone: Int, duration: TimeInterval) {
        self.id = id
        self.zone = zone
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        zone = try container.decode(Int.self, forKey: .zone)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }
}

struct WorkoutSetSummary: Codable, Identifiable {
    let id: UUID
    let label: String
    let setTime: TimeInterval
    let totalTime: TimeInterval
    let isRestSet: Bool
    let isCooldownSet: Bool
    let associatedWorkSetNumber: Int?
    let avgBpm: Int?
    let minBpm: Int?
    let maxBpm: Int?

    enum CodingKeys: String, CodingKey {
        case id, label, setTime, totalTime, isRestSet, isCooldownSet, associatedWorkSetNumber, avgBpm, minBpm, maxBpm
    }

    init(id: UUID,
         label: String,
         setTime: TimeInterval,
         totalTime: TimeInterval,
         isRestSet: Bool,
         isCooldownSet: Bool,
         associatedWorkSetNumber: Int?,
         avgBpm: Int?,
         minBpm: Int?,
         maxBpm: Int?) {
        self.id = id
        self.label = label
        self.setTime = setTime
        self.totalTime = totalTime
        self.isRestSet = isRestSet
        self.isCooldownSet = isCooldownSet
        self.associatedWorkSetNumber = associatedWorkSetNumber
        self.avgBpm = avgBpm
        self.minBpm = minBpm
        self.maxBpm = maxBpm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decode(String.self, forKey: .label)
        setTime = try container.decode(TimeInterval.self, forKey: .setTime)
        totalTime = try container.decode(TimeInterval.self, forKey: .totalTime)
        isRestSet = try container.decode(Bool.self, forKey: .isRestSet)
        isCooldownSet = try container.decode(Bool.self, forKey: .isCooldownSet)
        associatedWorkSetNumber = try container.decodeIfPresent(Int.self, forKey: .associatedWorkSetNumber)
        avgBpm = try container.decodeIfPresent(Int.self, forKey: .avgBpm)
        minBpm = try container.decodeIfPresent(Int.self, forKey: .minBpm)
        maxBpm = try container.decodeIfPresent(Int.self, forKey: .maxBpm)
    }
}

struct WorkoutRecord: Codable, Identifiable {
    static let schemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let title: String?
    let startAt: Date
    let endAt: Date
    let durationSeconds: TimeInterval
    let avgHr: Int?
    let maxHr: Int?
    let minHr: Int?
    let hrv: Double?
    let caloriesTotal: Double?
    let caloriesActive: Double?
    let hrSamples: [WorkoutHeartRateSample]
    let zones: [WorkoutZoneSummary]
    let sets: [WorkoutSetSummary]
    let notes: String?
    let source: String
    let appVersion: String
    let createdAt: Date
    let updatedAt: Date
}

extension WorkoutRecord {
    func summaryText() -> String {
        var lines: [String] = []
        lines.append("🏁 Workout Summary")
        lines.append("")
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("🏷 \(title)")
        }
        lines.append("⏱ Total time: \(formatDuration(durationSeconds))")
        if let avgHr {
            lines.append("❤️ Avg BPM: \(avgHr)")
        }
        if let maxHr {
            lines.append("⬆️ Max BPM: \(maxHr)")
        }
        if let total = caloriesTotal {
            let activeText = caloriesActive.map { String(Int(round($0))) } ?? "n/a"
            lines.append("🔥 Calories: \(Int(round(total))) (active \(activeText))")
        }
        if !zones.isEmpty {
            let zoneText = zones.map { zone in
                "Z\(zone.zone) \(formatDuration(zone.duration))"
            }.joined(separator: ", ")
            lines.append("🗺 Zones: \(zoneText)")
        }
        return lines.joined(separator: "\n")
    }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func formatDuration(_ time: TimeInterval) -> String {
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
