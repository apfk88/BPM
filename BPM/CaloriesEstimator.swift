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

enum CalorieSetupState: Equatable {
    case notStarted
    case incomplete
    case needsReview
    case unavailable
    case basic
    case personalized
    case complete
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

    private var missingBasicFields: [String] {
        var missing: [String] = []
        if !Self.valid(weightKg, in: 1...1000) { missing.append("Weight") }
        if !(1...130).contains(ageYears ?? 0) { missing.append("Age") }
        if sexAtBirth == nil { missing.append("Sex") }
        return missing
    }

    var missingRequiredFields: [String] {
        var missing = missingBasicFields
        if let restHeartRate, !(20...250).contains(restHeartRate) { missing.append("Resting HR") }
        if let maxHeartRate, !(30...250).contains(maxHeartRate) { missing.append("Max HR") }
        if let restHeartRate, let maxHeartRate, maxHeartRate <= restHeartRate {
            missing.append("Max HR must exceed resting HR")
        }
        if let vo2Max, !Self.valid(vo2Max, in: 1...150) || vo2Max <= vo2RestValue {
            missing.append("VO2max")
        }
        if let rmrKcalPerDay, !Self.valid(rmrKcalPerDay, in: 1...10000) { missing.append("RMR") }
        if medsAffectingHr { missing.append("HR-based calories unavailable with HR-altering medication") }
        return missing
    }

    // Broad input sanity limits, not validation of this model for every accepted person.
    private static func valid(_ value: Double?, in range: ClosedRange<Double>) -> Bool {
        guard let value, value.isFinite else { return false }
        return range.contains(value)
    }

    var hasRequiredInputs: Bool {
        missingRequiredFields.isEmpty
    }

    var setupState: CalorieSetupState {
        if !missingBasicFields.isEmpty {
            return weightKg == nil && ageYears == nil && sexAtBirth == nil ? .notStarted : .incomplete
        }
        if medsAffectingHr { return .unavailable }
        if !hasRequiredInputs { return .needsReview }
        guard CaloriesEstimator.preferredMethod(for: self) == .hrrVO2 else { return .basic }
        return maxHeartRate != nil && rmrKcalPerDay != nil ? .complete : .personalized
    }

    var needsCalorieSetupAttention: Bool {
        switch setupState {
        case .notStarted, .incomplete, .needsReview:
            return true
        case .unavailable, .basic, .personalized, .complete:
            return false
        }
    }

    var setupTitle: String {
        switch setupState {
        case .notStarted: return "Not set up"
        case .incomplete: return "Setup incomplete"
        case .needsReview: return "Check details"
        case .unavailable: return "Unavailable"
        case .basic: return "Basic"
        case .personalized: return "Personalized"
        case .complete: return "Complete"
        }
    }

    var setupDetail: String {
        switch setupState {
        case .notStarted:
            return "Add weight, age and sex to enable calorie estimates."
        case .incomplete:
            return "Add or correct: \(missingBasicFields.joined(separator: ", "))."
        case .needsReview:
            return "Review: \(missingRequiredFields.joined(separator: ", "))."
        case .unavailable:
            return "HR-based calorie estimates are unavailable when medication affects your heart rate."
        case .basic:
            return "Uses weight, age and sex."
        case .personalized:
            return maxHeartRate == nil
                ? "Uses resting HR and VO2max, with max HR estimated from age."
                : "Uses resting HR, VO2max and your entered max HR."
        case .complete:
            return "Uses your heart-rate range, VO2max and resting metabolic rate."
        }
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
        guard let rmrKcalPerDay, rmrKcalPerDay.isFinite, rmrKcalPerDay > 0,
              let weightKg, weightKg.isFinite, weightKg > 0 else { return 3.5 }
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
        let sexAtBirth = sexRaw.flatMap(SexAtBirth.init(rawValue:))

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
            medsAffectingHr: defaults.bool(forKey: CaloriesDefaultsKey.medsAffectingHr)
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

    static func estimate(
        samples: [HeartRateSample],
        profile: UserEnergyProfile,
        workoutDuration: TimeInterval? = nil,
        pauses: [WorkoutPause] = []
    ) -> CaloriesEstimateStatus {
        let missing = profile.missingRequiredFields
        guard missing.isEmpty else { return .disabled(missingFields: missing) }

        let preprocess = preprocess(samples: samples, workoutDuration: workoutDuration, pauses: pauses)
        guard !preprocess.samples.isEmpty else { return .insufficient(remaining: 10) }
        guard preprocess.usableDuration >= 10 else {
            return .insufficient(remaining: max(0, 10 - preprocess.usableDuration))
        }

        guard let weightKg = profile.weightKg, let ageYears = profile.ageYears,
              let sexAtBirth = profile.sexAtBirth else {
            return .disabled(missingFields: profile.missingRequiredFields)
        }

        let method = preferredMethod(for: profile)
        // VO2 is ml/kg/min. At the assumed 5 kcal/litre O2, kcal/min = VO2 * kg / 200.
        let restKcalPerMinute = profile.vo2RestValue * weightKg / 200.0
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
                kcalPerMinute = max(vo2 * weightKg / 200.0, 0)

            case .hrRegression, .hrRegressionUnsexed:
                kcalPerMinute = regressionKcalPerMinute(
                    bpm: sample.bpm,
                    weightKg: weightKg,
                    ageYears: Double(ageYears),
                    sex: sexAtBirth
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
        if let resting = profile.restHeartRateValue,
           let maximum = profile.derivedMaxHeartRate, maximum > resting,
           let vo2Max = profile.vo2Max, vo2Max.isFinite, vo2Max > profile.vo2RestValue {
            return .hrrVO2
        }
        return regressionMethod(for: profile)
    }

    static func regressionMethod(for profile: UserEnergyProfile) -> CaloriesMethod {
        return .hrRegression
    }

    static func confidence(for profile: UserEnergyProfile, method: CaloriesMethod) -> Double {
        // Kept for stored-session compatibility. No individual error/confidence model has
        // been validated; field completeness cannot justify a probability of accuracy.
        0
    }

    static func confidenceLabel(for confidence: Double) -> String {
        "Not validated"
    }

    private static func preprocess(
        samples: [HeartRateSample],
        workoutDuration: TimeInterval?,
        pauses: [WorkoutPause]
    ) -> PreprocessResult {
        let freshness = HeartRateBluetoothManager.defaultHeartRateFreshnessInterval
        let usesActiveTime = samples.contains { $0.workoutTime != nil }
        let validPauses = pauses.filter {
            $0.start.timeIntervalSinceReferenceDate.isFinite &&
            $0.end.timeIntervalSinceReferenceDate.isFinite && $0.end > $0.start
        }.sorted { $0.start < $1.start }
        let timeline = samples.enumerated().compactMap { index, sample -> (index: Int, sample: HeartRateSample, time: TimeInterval)? in
            guard sample.timestamp.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let time: TimeInterval
            if usesActiveTime {
                guard let active = sample.workoutTime, active.isFinite, active >= 0 else { return nil }
                time = active
            } else {
                time = sample.timestamp.timeIntervalSinceReferenceDate
            }
            return (index, sample, time)
        }.sorted { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time }
        guard let last = timeline.last else {
            return PreprocessResult(samples: [], gapCount: 0, usableDuration: 0)
        }
        // A sample has no duration by itself. Only a known workout boundary permits
        // a final held value, and never longer than the sensor freshness window.
        let end = usesActiveTime ? (workoutDuration ?? last.time) : last.time
        guard end.isFinite, !usesActiveTime || end >= 0 else {
            return PreprocessResult(samples: [], gapCount: 0, usableDuration: 0)
        }
        var processed: [ProcessedSample] = []
        var gapCount = 0
        var usableDuration: TimeInterval = 0
        for (index, entry) in timeline.enumerated() {
            let sample = entry.sample
            guard entry.time < end else { continue }
            let next = index + 1 < timeline.count ? timeline[index + 1] : nil
            let nextTime = min(next?.time ?? end, end)
            let elapsed = max(0, nextTime - entry.time)
            guard elapsed > 0 else { continue }
            // Retain invalid samples as boundaries so removing one cannot bridge
            // an explicit no-contact or invalid-HR period.
            guard (30...230).contains(sample.value), sample.sensorContactStatus != .notDetected,
                  !validPauses.contains(where: { sample.timestamp >= $0.start && sample.timestamp < $0.end }) else {
                gapCount += 1
                continue
            }
            var duration = min(elapsed, freshness)
            if let invalidatedAt = sample.invalidatedAt {
                let validDuration = invalidatedAt.timeIntervalSince(sample.timestamp)
                duration = validDuration.isFinite ? min(duration, max(0, validDuration)) : 0
            }
            let upcomingPause = validPauses.first { $0.start >= sample.timestamp }
            if let upcomingPause {
                duration = min(duration, upcomingPause.start.timeIntervalSince(sample.timestamp))
            }
            if usesActiveTime, let next {
                let wallElapsed = next.sample.timestamp.timeIntervalSince(sample.timestamp)
                let activeElapsed = next.time - entry.time
                let knownPause = upcomingPause.map { $0.start <= next.sample.timestamp } ?? false
                if abs(wallElapsed - activeElapsed) > 1, !knownPause {
                    // Without pause metadata or a continuous clock, no valid duration
                    // can be assigned across the discontinuity.
                    duration = 0
                }
            }
            if duration < elapsed { gapCount += 1 }
            guard duration > 0 else { continue }
            processed.append(ProcessedSample(timestamp: sample.timestamp, bpm: Double(sample.value), duration: duration))
            usableDuration += duration
        }
        return PreprocessResult(samples: processed, gapCount: gapCount, usableDuration: usableDuration)
    }

    private static func regressionKcalPerMinute(bpm: Double, weightKg: Double, ageYears: Double, sex: SexAtBirth) -> Double {
        // Keytel et al. (2005), no-VO2max regression. Original output is kJ/min.
        // https://doi.org/10.1080/02640410470001730089
        let male = (-55.0969 + 0.6309 * bpm + 0.1988 * weightKg + 0.2017 * ageYears) / 4.184
        let female = (-20.4022 + 0.4472 * bpm - 0.1263 * weightKg + 0.074 * ageYears) / 4.184
        let value = (sex == .female) ? female : male
        return max(value, 0)
    }
}
