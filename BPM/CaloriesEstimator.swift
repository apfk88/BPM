import Foundation

enum CaloriesDefaultsKey {
    static let weightKg = "BPM_Calories_WeightKg"
    static let ageYears = "BPM_Calories_AgeYears"
    static let sexAtBirth = "BPM_Calories_SexAtBirth"
    static let heightCm = "BPM_Calories_HeightCm"
    static let restHrBpm = "BPM_Calories_RestHR"
    static let maxHrBpm = "BPM_Calories_MaxHR"
    static let vo2Max = "BPM_Calories_VO2Max"
    static let rmrKcalPerDay = "BPM_Calories_RMR"
    static let bodyFatPercent = "BPM_Calories_BodyFat"
    static let medsAffectingHr = "BPM_Calories_MedsAffectingHR"
}

enum SexAtBirth: String, CaseIterable, Identifiable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male:
            return "Male"
        case .female:
            return "Female"
        }
    }
}

struct UserEnergyProfile {
    var weightKg: Double?
    var ageYears: Int?
    var sexAtBirth: SexAtBirth?
    var heightCm: Double?
    var restHeartRate: Int?
    var maxHeartRate: Int?
    var vo2Max: Double?
    var rmrKcalPerDay: Double?
    var bodyFatPercent: Double?
    var medsAffectingHr: Bool

    var missingRequiredFields: [String] {
        var missing: [String] = []
        if weightKg == nil || (weightKg ?? 0) <= 0 { missing.append("Weight") }
        if ageYears == nil || (ageYears ?? 0) <= 0 { missing.append("Age") }
        if sexAtBirth == nil { missing.append("Sex at birth") }
        if heightCm == nil || (heightCm ?? 0) <= 0 { missing.append("Height") }
        return missing
    }

    var hasRequiredInputs: Bool {
        missingRequiredFields.isEmpty
    }

    var derivedMaxHeartRate: Double? {
        if let maxHeartRate {
            return Double(maxHeartRate)
        }
        guard let ageYears, ageYears > 0 else { return nil }
        return 208 - 0.7 * Double(ageYears)
    }

    var restHeartRateValue: Double? {
        restHeartRate.map(Double.init)
    }

    var vo2RestValue: Double {
        guard let rmrKcalPerDay, let weightKg, weightKg > 0 else { return 3.5 }
        let kcalPerMinute = rmrKcalPerDay / 1440.0
        return (kcalPerMinute * 200.0) / weightKg
    }
}

struct CaloriesSession: Codable {
    let startAt: Date
    let endAt: Date
    let totalKcal: Double
    let activeKcal: Double
    let methodUsed: String
    let confidence: Double
}

final class CaloriesSessionStore {
    static let shared = CaloriesSessionStore()

    private let key = "BPM_Calories_LastSession"
    private let defaults = UserDefaults.standard

    private init() {}

    func save(_ session: CaloriesSession) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            defaults.set(data, forKey: key)
        }
    }

    func load() -> CaloriesSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(CaloriesSession.self, from: data)
    }
}

enum CaloriesMethod: String {
    case hrrVO2 = "hrr_vo2"
    case hrRegression = "hr_regression"
    case hrRegressionUnsexed = "hr_regression_unsexed"
}

struct CaloriesEstimate {
    let activeKcal: Double
    let totalKcal: Double
    let method: CaloriesMethod
    let confidence: Double
    let hrSampleCount: Int
    let gapCount: Int
    let usableDuration: TimeInterval
}

enum CaloriesEstimateStatus {
    case disabled(missingFields: [String])
    case insufficient(remaining: TimeInterval)
    case available(CaloriesEstimate)
}

struct UserEnergyProfileStore {
    static func currentProfile(defaults: UserDefaults = .standard) -> UserEnergyProfile {
        let weightKg = parseDouble(defaults.string(forKey: CaloriesDefaultsKey.weightKg))
        let ageYears = parseInt(defaults.string(forKey: CaloriesDefaultsKey.ageYears))
        let heightCm = parseDouble(defaults.string(forKey: CaloriesDefaultsKey.heightCm))
        let restHeartRate = parseInt(defaults.string(forKey: CaloriesDefaultsKey.restHrBpm))
        let maxHeartRate = parseInt(defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm))
        let vo2Max = parseDouble(defaults.string(forKey: CaloriesDefaultsKey.vo2Max))
        let rmrKcalPerDay = parseDouble(defaults.string(forKey: CaloriesDefaultsKey.rmrKcalPerDay))
        let bodyFatPercent = parseDouble(defaults.string(forKey: CaloriesDefaultsKey.bodyFatPercent))
        let sexRaw = defaults.string(forKey: CaloriesDefaultsKey.sexAtBirth)
        let sexAtBirth = sexRaw.flatMap(SexAtBirth.init(rawValue:)) ?? .male

        return UserEnergyProfile(
            weightKg: weightKg,
            ageYears: ageYears,
            sexAtBirth: sexAtBirth,
            heightCm: heightCm,
            restHeartRate: restHeartRate,
            maxHeartRate: maxHeartRate,
            vo2Max: vo2Max,
            rmrKcalPerDay: rmrKcalPerDay,
            bodyFatPercent: bodyFatPercent,
            medsAffectingHr: false
        )
    }

    private static func parseDouble(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        return Int(value)
    }
}

final class CaloriesEstimator {
    private struct ProcessedSample {
        let timestamp: Date
        let bpm: Double
        let duration: TimeInterval
    }

    private struct PreprocessResult {
        let samples: [ProcessedSample]
        let gapCount: Int
        let usableDuration: TimeInterval
    }

    static func estimate(samples: [HeartRateSample], profile: UserEnergyProfile) -> CaloriesEstimateStatus {
        let missing = profile.missingRequiredFields
        guard missing.isEmpty else { return .disabled(missingFields: missing) }

        let preprocess = preprocess(samples: samples)
        guard !preprocess.samples.isEmpty else { return .insufficient(remaining: 10) }
        guard preprocess.usableDuration >= 10 else {
            return .insufficient(remaining: max(0, 10 - preprocess.usableDuration))
        }

        guard let weightKg = profile.weightKg, let ageYears = profile.ageYears else {
            return .disabled(missingFields: profile.missingRequiredFields)
        }

        var method = preferredMethod(for: profile)
        if method == .hrrVO2 {
            if profile.restHeartRateValue == nil || profile.derivedMaxHeartRate == nil || profile.vo2Max == nil {
                method = regressionMethod(for: profile)
            } else if let hrRest = profile.restHeartRateValue, let hrMax = profile.derivedMaxHeartRate, hrMax <= hrRest {
                method = regressionMethod(for: profile)
            }
        }

        let restKcalPerMinute = 3.5 * weightKg / 200.0
        var totalKcal = 0.0
        var activeKcal = 0.0

        for sample in preprocess.samples {
            let kcalPerMinute: Double

            switch method {
            case .hrrVO2:
                guard let hrRest = profile.restHeartRateValue,
                      let hrMax = profile.derivedMaxHeartRate,
                      let vo2Max = profile.vo2Max else {
                    continue
                }
                let hrr = hrMax - hrRest
                guard hrr > 0 else { continue }
                let pctHrr = max(0, min(1, (sample.bpm - hrRest) / hrr))
                let vo2Rest = profile.vo2RestValue
                let vo2 = vo2Rest + pctHrr * (vo2Max - vo2Rest)
                let met = vo2 / vo2Rest
                kcalPerMinute = max(met * 3.5 * weightKg / 200.0, 0)

            case .hrRegression, .hrRegressionUnsexed:
                kcalPerMinute = regressionKcalPerMinute(
                    bpm: sample.bpm,
                    weightKg: weightKg,
                    ageYears: Double(ageYears),
                    sex: profile.sexAtBirth ?? .male
                )
            }

            let minutes = sample.duration / 60.0
            let gross = kcalPerMinute * minutes
            let active = max((kcalPerMinute - restKcalPerMinute) * minutes, 0)
            totalKcal += gross
            activeKcal += active
        }

        let confidence = confidence(for: profile, method: method)
        let estimate = CaloriesEstimate(
            activeKcal: activeKcal,
            totalKcal: totalKcal,
            method: method,
            confidence: confidence,
            hrSampleCount: preprocess.samples.count,
            gapCount: preprocess.gapCount,
            usableDuration: preprocess.usableDuration
        )
        return .available(estimate)
    }

    static func preferredMethod(for profile: UserEnergyProfile) -> CaloriesMethod {
        if profile.restHeartRateValue != nil, profile.vo2Max != nil, profile.derivedMaxHeartRate != nil {
            return .hrrVO2
        }
        return regressionMethod(for: profile)
    }

    static func regressionMethod(for profile: UserEnergyProfile) -> CaloriesMethod {
        return .hrRegression
    }

    static func confidence(for profile: UserEnergyProfile, method: CaloriesMethod) -> Double {
        var value = 0.5
        if profile.maxHeartRate != nil {
            value += 0.2
        }
        if profile.vo2Max != nil {
            value += 0.2
        }
        if profile.rmrKcalPerDay != nil {
            value += 0.1
        }
        if method == .hrRegressionUnsexed {
            value -= 0.2
        }
        return min(max(value, 0), 1)
    }

    static func confidenceLabel(for confidence: Double) -> String {
        if confidence >= 0.75 { return "High" }
        if confidence >= 0.55 { return "Medium" }
        return "Low"
    }

    private static func preprocess(samples: [HeartRateSample]) -> PreprocessResult {
        let minBpm = 30
        let maxBpm = 230

        let filtered = samples
            .filter { $0.value >= minBpm && $0.value <= maxBpm }
            .sorted { $0.timestamp < $1.timestamp }

        guard !filtered.isEmpty else {
            return PreprocessResult(samples: [], gapCount: 0, usableDuration: 0)
        }

        var segments: [[HeartRateSample]] = []
        var current: [HeartRateSample] = []
        var gapCount = 0

        for sample in filtered {
            if let last = current.last {
                let gap = sample.timestamp.timeIntervalSince(last.timestamp)
                if gap > 30 {
                    if !current.isEmpty {
                        segments.append(current)
                    }
                    current = []
                    gapCount += 1
                }
            }
            current.append(sample)
        }

        if !current.isEmpty {
            segments.append(current)
        }

        var processed: [ProcessedSample] = []
        var usableDuration: TimeInterval = 0

        for segment in segments {
            let smoothed = smoothSegment(segment)
            guard !smoothed.isEmpty else { continue }

            for index in smoothed.indices {
                let currentSample = smoothed[index]
                let nextTimestamp: Date
                if index < smoothed.count - 1 {
                    nextTimestamp = smoothed[index + 1].timestamp
                } else {
                    nextTimestamp = currentSample.timestamp.addingTimeInterval(1)
                }
                let delta = max(0, nextTimestamp.timeIntervalSince(currentSample.timestamp))
                usableDuration += delta
                processed.append(ProcessedSample(timestamp: currentSample.timestamp, bpm: currentSample.bpm, duration: delta))
            }
        }

        return PreprocessResult(samples: processed, gapCount: gapCount, usableDuration: usableDuration)
    }

    private static func smoothSegment(_ segment: [HeartRateSample]) -> [(timestamp: Date, bpm: Double)] {
        guard !segment.isEmpty else { return [] }

        var medians: [Double] = []
        var window: [HeartRateSample] = []

        for sample in segment {
            window.append(sample)
            while let first = window.first, sample.timestamp.timeIntervalSince(first.timestamp) > 5 {
                window.removeFirst()
            }
            let medianValue = median(of: window.map { Double($0.value) })
            medians.append(medianValue)
        }

        let alpha = 2.0 / (15.0 + 1.0)
        var ema: Double = medians.first ?? 0
        var smoothed: [(timestamp: Date, bpm: Double)] = []

        for (index, medianValue) in medians.enumerated() {
            if index == 0 {
                ema = medianValue
            } else {
                ema = alpha * medianValue + (1 - alpha) * ema
            }
            smoothed.append((timestamp: segment[index].timestamp, bpm: ema))
        }

        return smoothed
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func regressionKcalPerMinute(bpm: Double, weightKg: Double, ageYears: Double, sex: SexAtBirth) -> Double {
        let male = 0.239 * (-55.097 + 0.631 * bpm + 0.199 * weightKg + 0.202 * ageYears)
        let female = 0.239 * (-20.402 + 0.447 * bpm - 0.126 * weightKg + 0.070 * ageYears)
        let value = (sex == .female) ? female : male
        return max(value, 0)
    }
}
