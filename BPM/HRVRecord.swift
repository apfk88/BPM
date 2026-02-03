import Foundation

struct HRVHeartRateSample: Codable {
    let timestamp: Date
    let bpm: Int
}

struct HRVRecord: Codable, Identifiable {
    static let schemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let startAt: Date
    let endAt: Date
    let durationSeconds: TimeInterval
    let hrvValue: Double?
    let avgHr: Int?
    let minHr: Int?
    let maxHr: Int?
    let hrSamples: [HRVHeartRateSample]
    let rrIntervalsMs: [Double]
    let source: String
    let appVersion: String
    let createdAt: Date
    let updatedAt: Date
}

extension HRVRecord {
    func summaryText() -> String {
        var lines: [String] = []
        lines.append("🧘 HRV Summary")
        lines.append("")
        lines.append("⏱ Duration: \(formatDuration(durationSeconds))")
        if let hrvValue {
            lines.append("💓 HRV (RMSSD): \(Int(hrvValue.rounded())) ms")
        }
        if let avgHr {
            lines.append("❤️ Avg BPM: \(avgHr)")
        }
        if let minHr {
            lines.append("⬇️ Min BPM: \(minHr)")
        }
        if let maxHr {
            lines.append("⬆️ Max BPM: \(maxHr)")
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
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
