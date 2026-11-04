import Foundation

/// ISO 8601 dates with subsecond precision for measurement, pause, and loss boundaries.
/// Foundation's `.iso8601` JSON strategy writes whole seconds; its fractional
/// ISO8601DateFormatter also rounds to milliseconds. Keep the fractional component
/// ourselves so a save/reload does not merge distinct sensor receipts.
enum MeasurementDateCoding {
    private static let wholeSecondStyle = Date.ISO8601FormatStyle()
    private static let precisionKey = "_bpmDatePrecision"
    private static let datePropertyNames: Set<String> = [
        "startAt", "endAt", "timestamp", "invalidatedAt", "healthKitSyncedAt",
        "createdAt", "updatedAt", "start", "end"
    ]

    static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw EncodingError.invalidValue(date, .init(
                    codingPath: encoder.codingPath, debugDescription: "Measurement date must be finite"
                ))
            }
            var wholeSeconds = floor(seconds)
            var nanoseconds = Int(((seconds - wholeSeconds) * 1_000_000_000).rounded())
            if nanoseconds == 1_000_000_000 {
                wholeSeconds += 1
                nanoseconds = 0
            }
            let whole = wholeSecondStyle.format(Date(timeIntervalSinceReferenceDate: wholeSeconds))
            let timestamp = String(whole.dropLast()) + String(format: ".%09dZ", nanoseconds)
            var container = encoder.singleValueContainer()
            try container.encode(timestamp)
        }
    }

    static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let timestamp = try container.decode(String.self)
            guard let date = date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 measurement date")
            }
            return date
        }
    }

    /// Keep cloud record fields readable by older app versions whose ISO decoder
    /// accepts only whole seconds. Updated readers recover precision from optional
    /// companion fields, which older Codable models ignore.
    static func legacyCompatibleCloudData(from preciseData: Data) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: preciseData)
        return try JSONSerialization.data(withJSONObject: cloudValue(value, restoringPrecision: false), options: [.sortedKeys])
    }

    static func restoringCloudPrecision(in cloudData: Data) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: cloudData)
        return try JSONSerialization.data(withJSONObject: cloudValue(value, restoringPrecision: true), options: [.sortedKeys])
    }

    private static func cloudValue(_ value: Any, restoringPrecision: Bool) -> Any {
        if let array = value as? [Any] {
            return array.map { cloudValue($0, restoringPrecision: restoringPrecision) }
        }
        guard var object = value as? [String: Any] else { return value }
        let companion = object.removeValue(forKey: precisionKey) as? [String: Any] ?? [:]
        var encodedPrecision: [String: String] = [:]
        for (key, value) in object {
            guard datePropertyNames.contains(key), let timestamp = value as? String,
                  let originalDate = date(from: timestamp) else {
                object[key] = cloudValue(value, restoringPrecision: restoringPrecision)
                continue
            }
            if restoringPrecision {
                // Only replace an existing known date field with a valid precise
                // date in that same whole second. Other metadata cannot overwrite
                // titles, numbers, absent fields, or a different date.
                if let preciseTimestamp = companion[key] as? String,
                   let preciseDate = date(from: preciseTimestamp),
                   floor(preciseDate.timeIntervalSinceReferenceDate) == originalDate.timeIntervalSinceReferenceDate {
                    object[key] = preciseTimestamp
                }
            } else {
                let seconds = originalDate.timeIntervalSinceReferenceDate
                object[key] = wholeSecondStyle.format(Date(timeIntervalSinceReferenceDate: floor(seconds)))
                if seconds != floor(seconds) { encodedPrecision[key] = timestamp }
            }
        }
        if !encodedPrecision.isEmpty { object[precisionKey] = encodedPrecision }
        return object
    }

    private static func date(from timestamp: String) -> Date? {
        var whole = timestamp
        var fraction: TimeInterval = 0
        if let dot = timestamp.firstIndex(of: ".") {
            let fractionStart = timestamp.index(after: dot)
            let digits = timestamp[fractionStart...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Double("0." + digits), value.isFinite else { return nil }
            let suffixStart = timestamp.index(fractionStart, offsetBy: digits.count)
            whole = String(timestamp[..<dot]) + timestamp[suffixStart...]
            fraction = value
        }
        return (try? wholeSecondStyle.parse(whole))?.addingTimeInterval(fraction)
    }
}
