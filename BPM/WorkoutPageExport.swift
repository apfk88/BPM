import Foundation
import zlib

enum WorkoutPageError: LocalizedError {
    case updateRequired
    case busy
    case invalidWorkout(String)
    case tooLarge
    case secureStorage
    case localStorage
    case invalidRecoveryCode
    case unavailable
    case attestationUnavailable
    case invalidResponse
    case missingPage
    case server(String, code: String)

    var errorDescription: String? {
        switch self {
        case .updateRequired: return "This workout already has a page with different contents. Choose Update Page to replace its shared details."
        case .busy: return "Another workout-page action is still in progress. Please try again when it finishes."
        case .invalidWorkout(let message): return message
        case .tooLarge: return "This workout is too large to upload without reducing its recorded data. You can still share the workout without a link."
        case .secureStorage: return "BPM couldn’t securely save your page-management keys. Unlock this device and try again."
        case .localStorage: return "BPM couldn’t save its shared-page registry. A server action may already have completed; retry or refresh Shared Pages to recover its status."
        case .invalidRecoveryCode: return "That recovery code isn’t valid for this BPM server. Check that you copied the entire code."
        case .unavailable: return "Private workout pages aren’t available right now. Try again or share without a link."
        case .attestationUnavailable: return "This device couldn’t verify permission to upload workout pages. Try again or share without a link. Existing pages can still be managed."
        case .invalidResponse: return "The workout-page server returned an unexpected response. Please try again."
        case .missingPage: return "This workout page is no longer available."
        case .server(let message, _): return message
        }
    }
}

/// The only workout fields allowed to leave the device for a private page.
/// This is deliberately independent of the local persistence/diagnostic schema.
struct WorkoutPageExport: Codable, Equatable {
    struct Sample: Codable, Equatable {
        let elapsedSeconds: Double
        let activeSeconds: Double
        let bpm: Int
        let validUntilElapsedSeconds: Double?
        let invalidatedAtElapsedSeconds: Double?
    }

    struct Interval: Codable, Equatable {
        enum Kind: String, Codable { case pause, signalLoss }
        let startElapsedSeconds: Double
        let endElapsedSeconds: Double
        let kind: Kind
    }

    struct Set: Codable, Equatable {
        enum Kind: String, Codable { case work, rest, cooldown }
        let index: Int
        let label: String
        let kind: Kind
        let startElapsedSeconds: Double
        let endElapsedSeconds: Double
        let startActiveSeconds: Double
        let endActiveSeconds: Double
        let durationSeconds: Double
        let avgBPM: Int?
        let minBPM: Int?
        let maxBPM: Int?
    }

    struct Zone: Codable, Equatable {
        let zone: Int
        let durationSeconds: Double
        let lowerBPM: Int?
        let upperBPM: Int?
    }

    struct Summary: Codable, Equatable {
        let avgBPM: Int?
        let minBPM: Int?
        let maxBPM: Int?
        let calories: Double?
        let activeCalories: Double?
        let recoveryBPM: Int?
    }

    struct Quality: Codable, Equatable {
        let sampleFidelity: WorkoutSampleFidelity
        let exportedSampleCount: Int
        let originalSampleCount: Int?
        let rangeMetricsAvailable: Bool
    }

    let schemaVersion: Int
    let calculationVersion: Int
    var title: String
    var description: String?
    var workoutDate: String?
    var recordedAt: String?
    let durationSeconds: Double
    let elapsedDurationSeconds: Double
    let summary: Summary
    let samples: [Sample]
    let intervals: [Interval]
    let sets: [Set]
    let zones: [Zone]
    let quality: Quality

    static let maximumDecodedBytes = 16 * 1_024 * 1_024
    static let maximumCompressedBytes = 2 * 1_024 * 1_024

    init(record: WorkoutRecord, title: String, description: String, includeDate: Bool,
         timeZone: TimeZone = .current) throws {
        let text = try Self.checkedText(title: title, description: description)
        let wallDuration = record.endAt.timeIntervalSince(record.startAt)
        guard wallDuration.isFinite, record.durationSeconds.isFinite,
              wallDuration >= 0, record.durationSeconds >= 0,
              max(wallDuration, record.durationSeconds) <= 7 * 24 * 60 * 60,
              record.hrSamples.count <= 200_000, record.sets.count <= 4_096,
              record.originalSampleCount.map({ $0 >= record.hrSamples.count && $0 <= 9_007_199_254_740_991 }) ?? true else {
            throw WorkoutPageError.invalidWorkout("This workout contains unsupported timing or too many measurements to share as a page.")
        }
        schemaVersion = 1
        calculationVersion = 1
        self.title = text.title
        self.description = text.description
        guard let date = WorkoutPageDate.string(from: record.startAt, timeZone: timeZone) else {
            throw WorkoutPageError.invalidWorkout("This workout has an unsupported date.")
        }
        workoutDate = date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        recordedAt = includeDate ? formatter.string(from: record.startAt) : nil
        durationSeconds = record.durationSeconds
        let elapsedDuration = max(wallDuration, record.durationSeconds)
        elapsedDurationSeconds = elapsedDuration

        let pauses = try Self.mergedPauses(record.pauses ?? [], start: record.startAt, duration: elapsedDurationSeconds)
        let fidelity = record.resolvedSampleFidelity
        let full = fidelity == .full && (record.originalSampleCount == nil || record.originalSampleCount == record.hrSamples.count)
        let exportedFidelity: WorkoutSampleFidelity = fidelity == .full && !full ? .reduced : fidelity
        let sortedSamples = record.hrSamples.sorted { $0.timestamp < $1.timestamp }
        var builtSamples: [Sample] = []
        for (index, sample) in sortedSamples.enumerated() {
            let elapsed = sample.timestamp.timeIntervalSince(record.startAt)
            let active = sample.workoutTime ?? Self.activeTime(elapsed, pauses: pauses)
            guard elapsed.isFinite, active.isFinite, sample.bpm > 0, sample.bpm <= 400,
                  elapsed >= -0.001, elapsed <= elapsedDurationSeconds + 0.001,
                  active >= -0.001, active <= durationSeconds + 0.001 else {
                throw WorkoutPageError.invalidWorkout("This workout contains invalid measurements. Its saved data was kept unchanged; share the original logs instead.")
            }
            let elapsedTime = min(elapsedDurationSeconds, max(0, elapsed))
            let activeTime = min(durationSeconds, max(0, active))
            var invalidated: Double?
            if let invalidatedAt = sample.invalidatedAt {
                let offset = invalidatedAt.timeIntervalSince(record.startAt)
                guard offset.isFinite else { throw WorkoutPageError.invalidWorkout("This workout has an invalid sensor-loss time.") }
                invalidated = min(elapsedDurationSeconds, max(elapsedTime, offset))
            }
            var support: Double?
            if full {
                let next = index + 1 < sortedSamples.count
                    ? sortedSamples[index + 1].timestamp.timeIntervalSince(record.startAt)
                    : elapsedDurationSeconds
                let pauseLimit = pauses.first { $0.endElapsedSeconds > elapsedTime }
                    .map { max(elapsedTime, $0.startElapsedSeconds) } ?? elapsedDurationSeconds
                support = max(elapsedTime, min(elapsedDurationSeconds, next, elapsedTime + 3,
                                              pauseLimit, invalidated ?? elapsedDurationSeconds))
            }
            builtSamples.append(Sample(elapsedSeconds: elapsedTime, activeSeconds: activeTime,
                                       bpm: sample.bpm, validUntilElapsedSeconds: support,
                                       invalidatedAtElapsedSeconds: invalidated))
        }
        samples = builtSamples

        var builtIntervals = pauses
        if full {
            // Only an original-resolution trace can prove that an interval has no reading.
            var supportedThrough = 0.0
            for sample in builtSamples {
                if sample.elapsedSeconds > supportedThrough {
                    builtIntervals += Self.subtractPauses(start: supportedThrough, end: sample.elapsedSeconds, pauses: pauses)
                }
                supportedThrough = max(supportedThrough, sample.validUntilElapsedSeconds ?? sample.elapsedSeconds)
            }
            if supportedThrough < elapsedDurationSeconds {
                builtIntervals += Self.subtractPauses(start: supportedThrough, end: elapsedDurationSeconds, pauses: pauses)
            }
        }
        intervals = builtIntervals.sorted {
            $0.startElapsedSeconds == $1.startElapsedSeconds ? $0.kind.rawValue < $1.kind.rawValue : $0.startElapsedSeconds < $1.startElapsedSeconds
        }
        guard intervals.count <= 10_000 else { throw WorkoutPageError.tooLarge }

        sets = try record.sets.enumerated().map { index, set in
            guard set.totalTime.isFinite, set.setTime.isFinite, set.setTime >= 0,
                  set.totalTime >= set.setTime - 0.001, set.totalTime <= record.durationSeconds + 0.001,
                  set.label.utf16.count <= 80 else {
                throw WorkoutPageError.invalidWorkout("This workout contains an invalid set interval.")
            }
            let start = max(0, set.totalTime - set.setTime)
            let end = min(record.durationSeconds, set.totalTime)
            return Set(index: index, label: set.label,
                       kind: set.isCooldownSet ? .cooldown : (set.isRestSet ? .rest : .work),
                       startElapsedSeconds: min(elapsedDuration, Self.elapsedTime(start, pauses: pauses, isEnd: false)),
                       endElapsedSeconds: min(elapsedDuration, Self.elapsedTime(end, pauses: pauses, isEnd: true)),
                       startActiveSeconds: start, endActiveSeconds: end, durationSeconds: max(0, end - start),
                       avgBPM: Self.validBPM(set.avgBpm), minBPM: Self.validBPM(set.minBpm), maxBPM: Self.validBPM(set.maxBpm))
        }

        let zoneDurations = Dictionary(record.zones.filter { (1...5).contains($0.zone) }.map { ($0.zone, $0.duration) }, uniquingKeysWith: +)
        let thresholds: [(Int, Int)]? = record.zoneConfig.map {
            [($0.zone1Min, $0.zone1Max), ($0.zone2Min, $0.zone2Max), ($0.zone3Min, $0.zone3Max),
             ($0.zone4Min, $0.zone4Max), ($0.zone5Min, $0.zone5Max)]
        }
        zones = try (1...5).compactMap { number in
            guard let duration = zoneDurations[number] ?? (thresholds == nil ? nil : 0) else { return nil }
            guard duration.isFinite, duration >= 0, duration <= record.durationSeconds + 0.001 else {
                throw WorkoutPageError.invalidWorkout("This workout contains an invalid zone duration.")
            }
            return Zone(zone: number, durationSeconds: duration,
                        lowerBPM: thresholds?[number - 1].0, upperBPM: thresholds?[number - 1].1)
        }
        summary = Summary(avgBPM: Self.validBPM(record.avgHr), minBPM: Self.validBPM(record.minHr),
                          maxBPM: Self.validBPM(record.maxHr), calories: Self.validCalories(record.caloriesTotal),
                          activeCalories: Self.validCalories(record.caloriesActive), recoveryBPM: record.hrr)
        quality = Quality(sampleFidelity: exportedFidelity, exportedSampleCount: samples.count,
                          originalSampleCount: record.originalSampleCount ?? (full ? samples.count : nil),
                          rangeMetricsAvailable: full && !samples.isEmpty)
    }

    mutating func setDetails(title: String, description: String) throws {
        let text = try Self.checkedText(title: title, description: description)
        self.title = text.title
        self.description = text.description
    }

    func encoded() throws -> Data {
        let data = try Self.encoder().encode(self)
        guard data.count <= Self.maximumDecodedBytes else { throw WorkoutPageError.tooLarge }
        return data
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func checkedText(title: String, description: String) throws -> (title: String, description: String?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.utf16.count <= 120, description.utf16.count <= 8_000 else {
            throw WorkoutPageError.invalidWorkout("The shared title or description is too long. Shorten it and try again; some emoji count as more than one character.")
        }
        guard !hasDisallowedControls(title, multiline: false), !hasDisallowedControls(description, multiline: true) else {
            throw WorkoutPageError.invalidWorkout("Remove unsupported control characters from the shared title or description. Titles must fit on one line.")
        }
        return (title.isEmpty ? "Workout" : title, description.isEmpty ? nil : description)
    }

    private static func hasDisallowedControls(_ text: String, multiline: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if multiline && [9, 10, 13].contains(value) { return false }
            return value <= 31 || value == 127 || (0x202a...0x202e).contains(value) || (0x2066...0x2069).contains(value)
        }
    }

    private static func validBPM(_ bpm: Int?) -> Int? {
        bpm.flatMap { (1...400).contains($0) ? $0 : nil }
    }

    private static func validCalories(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100_000 ? $0 : nil }
    }

    private static func mergedPauses(_ pauses: [WorkoutPause], start: Date, duration: Double) throws -> [Interval] {
        let sorted = try pauses.compactMap { pause -> Interval? in
            let lower = pause.start.timeIntervalSince(start), upper = pause.end.timeIntervalSince(start)
            guard lower.isFinite, upper.isFinite, upper >= lower else {
                throw WorkoutPageError.invalidWorkout("This workout contains an invalid pause interval.")
            }
            let a = max(0, lower), b = min(duration, upper)
            return b > a ? Interval(startElapsedSeconds: a, endElapsedSeconds: b, kind: .pause) : nil
        }.sorted { $0.startElapsedSeconds < $1.startElapsedSeconds }
        var merged: [Interval] = []
        for pause in sorted {
            if let previous = merged.last, pause.startElapsedSeconds <= previous.endElapsedSeconds {
                merged[merged.count - 1] = Interval(startElapsedSeconds: previous.startElapsedSeconds,
                                                  endElapsedSeconds: max(previous.endElapsedSeconds, pause.endElapsedSeconds), kind: .pause)
            } else { merged.append(pause) }
        }
        return merged
    }

    private static func activeTime(_ elapsed: Double, pauses: [Interval]) -> Double {
        elapsed - pauses.reduce(0) { $0 + max(0, min(elapsed, $1.endElapsedSeconds) - $1.startElapsedSeconds) }
    }

    private static func elapsedTime(_ active: Double, pauses: [Interval], isEnd: Bool) -> Double {
        var elapsed = active
        for pause in pauses {
            if isEnd ? elapsed > pause.startElapsedSeconds : elapsed >= pause.startElapsedSeconds {
                elapsed += pause.endElapsedSeconds - pause.startElapsedSeconds
            }
        }
        return elapsed
    }

    private static func subtractPauses(start: Double, end: Double, pauses: [Interval]) -> [Interval] {
        var cursor = start
        var result: [Interval] = []
        for pause in pauses where pause.endElapsedSeconds > start && pause.startElapsedSeconds < end {
            if pause.startElapsedSeconds > cursor {
                result.append(Interval(startElapsedSeconds: cursor, endElapsedSeconds: min(end, pause.startElapsedSeconds), kind: .signalLoss))
            }
            cursor = max(cursor, pause.endElapsedSeconds)
        }
        if cursor < end { result.append(Interval(startElapsedSeconds: cursor, endElapsedSeconds: end, kind: .signalLoss)) }
        return result
    }
}

/// A calendar date has no implied midnight, UTC offset, or exact workout time.
/// Older records do not store their recording timezone, so first sharing uses
/// the device's timezone and keeps that date in the shared snapshot afterward.
enum WorkoutPageDate {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, (1...9_999).contains(year), let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(from value: String) -> Date? {
        guard value.utf8.count == 10, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9_999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              string(from: date, timeZone: calendar.timeZone) == value else { return nil }
        return date
    }

    static func formatted(_ value: String, locale: Locale = .current) -> String {
        guard let date = date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

enum WorkoutPageCompression {
    /// RFC 1952 gzip, bounded both before and during compression.
    static func gzip(_ data: Data) throws -> Data {
        guard data.count <= WorkoutPageExport.maximumDecodedBytes else { throw WorkoutPageError.tooLarge }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                            MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WorkoutPageError.invalidResponse
        }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { raw -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            var status = Z_OK
            repeat {
                let count = buffer.count
                status = buffer.withUnsafeMutableBufferPointer { bytes in
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(count)
                    return deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw WorkoutPageError.invalidResponse }
                output.append(buffer, count: count - Int(stream.avail_out))
                guard output.count <= WorkoutPageExport.maximumCompressedBytes else { throw WorkoutPageError.tooLarge }
            } while status != Z_STREAM_END
            return output
        }
    }
}
