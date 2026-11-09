import Foundation
import Testing
@testable import BPM

struct CaloriesEstimatorTests {
    @Test func hrrModelAtRestProducesRestCalories() {
        let profile = UserEnergyProfile(
            weightKg: 70,
            ageYears: 30,
            sexAtBirth: .male,
            heightCm: 175,
            restHeartRate: 60,
            maxHeartRate: 190,
            vo2Max: 50,
            rmrKcalPerDay: nil,
            bodyFatPercent: nil,
            medsAffectingHr: false
        )
        let samples = makeSamples(bpm: 60, count: 301)

        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
        guard case let .available(estimate) = status else {
            #expect(Bool(false), "Expected available calories estimate")
            return
        }

        #expect(estimate.method == .hrrVO2)
        let expectedRestPerMin = 3.5 * 70 / 200.0
        #expect(abs(estimate.totalKcal - expectedRestPerMin * 5) < 0.1)
        #expect(estimate.activeKcal < 0.1)
    }

    @Test func regressionUsesMaleFormula() {
        let profile = UserEnergyProfile(
            weightKg: 80,
            ageYears: 40,
            sexAtBirth: .male,
            heightCm: 180,
            restHeartRate: nil,
            maxHeartRate: nil,
            vo2Max: nil,
            rmrKcalPerDay: nil,
            bodyFatPercent: nil,
            medsAffectingHr: false
        )
        let samples = makeSamples(bpm: 150, count: 301)

        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
        guard case let .available(estimate) = status else {
            #expect(Bool(false), "Expected available calories estimate")
            return
        }

        #expect(estimate.method == .hrRegression)
        let base = -55.0969
        let hrComponent = 0.6309 * 150.0
        let weightComponent = 0.1988 * 80.0
        let ageComponent = 0.2017 * 40.0
        let expectedPerMin = (base + hrComponent + weightComponent + ageComponent) / 4.184
        #expect(abs(estimate.totalKcal - expectedPerMin * 5) < 0.2)
    }

    @Test func currentProfileRequiresExplicitSexSelection() {
        let defaults = UserDefaults(suiteName: "calories-\(UUID().uuidString)")!
        defaults.set("80", forKey: CaloriesDefaultsKey.weightKg)
        defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)
        defaults.set("180", forKey: CaloriesDefaultsKey.heightCm)

        let profile = UserEnergyProfileStore.currentProfile(defaults: defaults)

        #expect(profile.sexAtBirth == nil)
        #expect(profile.missingRequiredFields.contains("Sex"))
    }

    @Test func requiredProfileWithoutRMRStillProducesEstimate() {
        let defaults = UserDefaults(suiteName: "calories-\(UUID().uuidString)")!
        defaults.set("80", forKey: CaloriesDefaultsKey.weightKg)
        defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)
        defaults.set("180", forKey: CaloriesDefaultsKey.heightCm)
        defaults.set("male", forKey: CaloriesDefaultsKey.sexAtBirth)

        let profile = UserEnergyProfileStore.currentProfile(defaults: defaults)
        let samples = makeSamples(bpm: 150, count: 301)
        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)

        guard case let .available(estimate) = status else {
            #expect(Bool(false), "Expected calories without RMR")
            return
        }
        #expect(estimate.method == .hrRegression)
    }

    @Test func missingRequiredFieldsDisablesCalories() {
        let profile = UserEnergyProfile(
            weightKg: nil,
            ageYears: 30,
            sexAtBirth: .female,
            heightCm: 165,
            restHeartRate: nil,
            maxHeartRate: nil,
            vo2Max: nil,
            rmrKcalPerDay: nil,
            bodyFatPercent: nil,
            medsAffectingHr: false
        )
        let samples = makeSamples(bpm: 120, count: 300)

        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
        guard case let .disabled(missingFields) = status else {
            #expect(Bool(false), "Expected disabled calories estimate")
            return
        }

        #expect(missingFields.contains("Weight"))
    }

    @Test func insufficientDataReturnsInsufficient() {
        let profile = UserEnergyProfile(
            weightKg: 70,
            ageYears: 30,
            sexAtBirth: .male,
            heightCm: 175,
            restHeartRate: 60,
            maxHeartRate: 190,
            vo2Max: 50,
            rmrKcalPerDay: nil,
            bodyFatPercent: nil,
            medsAffectingHr: false
        )
        let samples = makeSamples(bpm: 120, count: 5)

        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
        guard case .insufficient = status else {
            #expect(Bool(false), "Expected insufficient calories estimate")
            return
        }
    }

    @Test func measuredRMRIsUsedAtRestAndDoesNotRescaleVO2max() throws {
        var profile = referenceProfile
        profile.restHeartRate = 60
        profile.maxHeartRate = 190
        profile.vo2Max = 50
        profile.rmrKcalPerDay = 1440
        let resting = try estimate(makeSamples(bpm: 60, count: 301), profile: profile)
        #expect(abs(resting.totalKcal - 5) < 0.000_001)
        #expect(abs(resting.activeKcal) < 0.000_001)

        let peak = try estimate(makeSamples(bpm: 190, count: 301), profile: profile)
        // 50 ml/kg/min * 80 kg = 4 L/min; at 5 kcal/L, five minutes = 100 kcal.
        #expect(abs(peak.totalKcal - 100) < 0.000_001)
        #expect(abs(peak.activeKcal - 95) < 0.000_001)
    }

    @Test func regressionUsesFullFemaleCoefficients() throws {
        var profile = referenceProfile
        profile.sexAtBirth = .female
        profile.weightKg = 65
        profile.ageYears = 35
        let result = try estimate(makeSamples(bpm: 145, count: 2401), profile: profile)
        // Keytel's female equation gives 38.8223 kJ/min for these inputs.
        #expect(abs(result.totalKcal - (38.8223 / 4.184 * 40)) < 0.000_001)
    }

    @Test func regressionSubtractsMeasuredRestingEnergy() throws {
        var profile = referenceProfile
        profile.rmrKcalPerDay = 1440
        let result = try estimate(makeSamples(bpm: 150, count: 301), profile: profile)
        #expect(abs(result.totalKcal - result.activeKcal - 5) < 0.000_001)
    }

    @Test func missingMeasurementsAreNotFilledForThirtySeconds() throws {
        let samples = (Array(0...4) + Array(24...29)).map { sample(at: Double($0), bpm: 150) }
        let result = try estimate(samples, duration: 30)
        // 0...4 plus three fresh seconds, then six seconds from 24 to the end.
        #expect(abs(result.usableDuration - 13) < 0.000_001)
        #expect(result.gapCount == 1)
        let continuous = try estimate(makeSamples(bpm: 150, count: 31))
        #expect(abs(result.totalKcal / continuous.totalKcal - 13.0 / 30.0) < 0.000_001)
    }

    @Test func lastSampleDoesNotCreateAnExtraSecond() throws {
        let result = try estimate(makeSamples(bpm: 150, count: 11))
        #expect(result.usableDuration == 10)
        let bounded = try estimate(makeSamples(bpm: 150, count: 11), duration: 10.25)
        #expect(bounded.usableDuration == 10.25)
        let stale = try estimate(makeSamples(bpm: 150, count: 11), duration: 100)
        #expect(stale.usableDuration == 13)
    }

    @Test func estimateDoesNotDependOnNotificationFrequency() throws {
        let sparse = stride(from: 0, through: 30, by: 2).map { sample(at: Double($0), bpm: $0 < 10 ? 100 : 150) }
        let frequent = stride(from: 0.0, through: 30.0, by: 0.25).map { sample(at: $0, bpm: $0 < 10 ? 100 : 150) }
        let sparseResult = try estimate(sparse)
        let frequentResult = try estimate(frequent)
        #expect(abs(sparseResult.totalKcal - frequentResult.totalKcal) < 0.000_001)
        #expect(abs(sparseResult.activeKcal - frequentResult.activeKcal) < 0.000_001)
    }

    @Test func duplicateTimestampsDoNotAddDuration() throws {
        let samples = makeSamples(bpm: 150, count: 31)
        let regular = try estimate(samples)
        let duplicate = try estimate(samples.flatMap { [$0, $0] })
        #expect(abs(regular.totalKcal - duplicate.totalKcal) < 0.000_001)
        #expect(duplicate.usableDuration == 30)
    }

    @Test func contactLossTerminatesPreviouslyHeldValue() throws {
        let samples = (Array(0...9) + Array(20...30)).map { sample(at: Double($0), bpm: 150) }
            + [sample(at: 10, bpm: 150, contact: .notDetected)]
        let result = try estimate(samples)
        #expect(result.usableDuration == 20)
        #expect(result.gapCount >= 1)
    }

    @Test func invalidHeartRateRemainsAGapBoundary() throws {
        let samples = (Array(0...9) + Array(20...30)).map { sample(at: Double($0), bpm: 150) }
            + [sample(at: 10, bpm: 0)]
        let result = try estimate(samples)
        #expect(result.usableDuration == 20)
    }

    @Test func explicitSensorLossEndsTheLastValidCalorieInterval() throws {
        var samples = makeSamples(bpm: 150, count: 31)
        let start = samples[0].timestamp
        samples[0].invalidatedAt = start.addingTimeInterval(0.25)
        let result = try estimate(samples)
        #expect(abs(result.usableDuration - 29.25) < 0.000_001)

        // A lost connection at one second must leave the next second unmeasured,
        // even when a new sensor reading arrives before the usual stale timeout.
        var sparse = (Array(0...0) + Array(2...30)).map { sample(at: Double($0), bpm: 150) }
        sparse[0].invalidatedAt = Date(timeIntervalSince1970: 1001)
        let resumed = try estimate(sparse)
        #expect(resumed.usableDuration == 29)
    }

    @Test func pausesCapHeldReadingsAtTheActualPauseBoundary() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var samples = (0...9).map { sample(at: Double($0), bpm: 150) }
        samples += (11...20).map {
            HeartRateSample(value: 150, timestamp: start.addingTimeInterval(Double($0 + 100)), workoutTime: Double($0))
        }
        let result = try estimate(samples, duration: 21, pauses: [
            WorkoutPause(start: start.addingTimeInterval(10), end: start.addingTimeInterval(110))
        ])
        #expect(result.usableDuration == 20)
    }

    @Test func activeTimelineIgnoresCalendarJumpWithoutInventingTime() throws {
        let samples = (0...30).map { index in
            HeartRateSample(value: 150,
                            timestamp: Date(timeIntervalSince1970: 1000 + Double(index) + (index >= 15 ? 3600 : 0)),
                            workoutTime: Double(index))
        }
        let result = try estimate(samples)
        #expect(result.usableDuration == 29)
    }

    @Test func invalidProfileNumbersNeverProduceAnAvailableEstimate() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1, 1e100] {
            for field in 0...2 {
                var profile = referenceProfile
                switch field {
                case 0: profile.weightKg = value
                case 1: profile.rmrKcalPerDay = value
                default: profile.vo2Max = value
                }
                guard case .disabled = CaloriesEstimator.estimate(samples: makeSamples(bpm: 150, count: 31), profile: profile) else {
                    #expect(Bool(false), "Invalid profile must be disabled")
                    continue
                }
            }
        }
    }

    @Test func inconsistentHeartRateInputsAreRejected() {
        var profile = referenceProfile
        profile.restHeartRate = 100
        profile.maxHeartRate = 90
        profile.vo2Max = 50
        guard case .disabled = CaloriesEstimator.estimate(samples: makeSamples(bpm: 150, count: 31), profile: profile) else {
            #expect(Bool(false), "Resting HR cannot exceed maximum HR")
            return
        }
    }

    @Test func medicationFlagIsLoadedAndDisablesUncalibratedHREstimates() {
        let suite = "calories-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("80", forKey: CaloriesDefaultsKey.weightKg)
        defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)
        defaults.set("180", forKey: CaloriesDefaultsKey.heightCm)
        defaults.set("male", forKey: CaloriesDefaultsKey.sexAtBirth)
        defaults.set(true, forKey: CaloriesDefaultsKey.medsAffectingHr)
        let profile = UserEnergyProfileStore.currentProfile(defaults: defaults)
        #expect(profile.medsAffectingHr)
        #expect(!profile.hasRequiredInputs)
    }

    @Test func calorieSetupProgressesFromMissingBasicsToPersonalizedModel() {
        var profile = referenceProfile
        profile.weightKg = nil
        profile.ageYears = nil
        profile.sexAtBirth = nil
        #expect(profile.setupState == .notStarted)
        #expect(profile.setupTitle == "Not set up")
        #expect(profile.needsCalorieSetupAttention)

        profile.weightKg = 80
        #expect(profile.setupState == .incomplete)
        #expect(profile.setupDetail.contains("Age"))
        #expect(profile.setupDetail.contains("Sex"))
        #expect(!profile.setupDetail.contains("Weight"))
        #expect(profile.needsCalorieSetupAttention)

        profile.ageYears = 40
        profile.sexAtBirth = .male
        #expect(profile.setupState == .basic)
        #expect(!profile.needsCalorieSetupAttention)

        profile.restHeartRate = 60
        #expect(profile.setupState == .basic)
        profile.vo2Max = 50
        #expect(profile.setupState == .personalized)
        #expect(!profile.needsCalorieSetupAttention)
        #expect(profile.setupDetail.contains("estimated from age"))

        profile.maxHeartRate = 190
        #expect(profile.setupDetail.contains("entered max HR"))
    }

    @Test func completeSetupRequiresInputsUsedByThePersonalizedModel() throws {
        var profile = referenceProfile
        let samples = makeSamples(bpm: 150, count: 31)
        let basicEstimate = try estimate(samples, profile: profile)
        profile.restHeartRate = 60
        profile.maxHeartRate = 195
        #expect(profile.setupState == .basic)
        let withHeartRates = try estimate(samples, profile: profile)
        #expect(withHeartRates.totalKcal == basicEstimate.totalKcal)
        #expect(withHeartRates.activeKcal == basicEstimate.activeKcal)

        profile.vo2Max = 50
        #expect(profile.setupState == .personalized)
        profile.rmrKcalPerDay = 1700
        #expect(profile.setupState == .complete)
        #expect(profile.setupTitle == "Complete")
        #expect(!profile.needsCalorieSetupAttention)
        profile.maxHeartRate = nil
        #expect(profile.setupState == .personalized)
        profile.restHeartRate = nil
        #expect(profile.setupState == .basic)
    }

    @Test func invalidBasicsRemainIncompleteRatherThanReady() {
        var profile = referenceProfile
        profile.weightKg = 0
        #expect(profile.setupState == .incomplete)
        #expect(profile.setupDetail.contains("Weight"))
        #expect(profile.needsCalorieSetupAttention)

        profile.weightKg = 80
        profile.ageYears = 0
        #expect(profile.setupState == .incomplete)
        #expect(profile.setupDetail.contains("Age"))
    }

    @Test func unusedHeightAndBodyFatNeverBlockCalorieSetupOrChangeEstimates() throws {
        let samples = makeSamples(bpm: 150, count: 31)
        let reference = try estimate(samples)
        for value in [nil, Double.nan, .infinity, -1, 0, 1e100] as [Double?] {
            var profile = referenceProfile
            profile.heightCm = value
            profile.bodyFatPercent = value
            #expect(profile.hasRequiredInputs)
            #expect(profile.setupState == .basic)
            #expect(!profile.needsCalorieSetupAttention)
            let result = try estimate(samples, profile: profile)
            #expect(result.totalKcal == reference.totalKcal)
            #expect(result.activeKcal == reference.activeKcal)
        }
    }

    @Test func invalidAdvancedInputsNeedReviewAfterBasicsAreComplete() {
        var profile = referenceProfile
        profile.restHeartRate = 0
        #expect(profile.setupState == .needsReview)
        #expect(profile.needsCalorieSetupAttention)
        #expect(profile.setupDetail.contains("Resting HR"))

        profile.restHeartRate = 60
        profile.vo2Max = .nan
        #expect(profile.setupState == .needsReview)
        #expect(profile.setupDetail.contains("VO2max"))

        profile.vo2Max = 50
        profile.maxHeartRate = 50
        #expect(profile.setupState == .needsReview)
        #expect(profile.setupDetail.contains("Max HR must exceed resting HR"))

        profile.maxHeartRate = 190
        #expect(profile.setupState == .personalized)
        #expect(!profile.needsCalorieSetupAttention)
    }

    @Test func medicationUnavailabilityDoesNotKeepRequestingSetup() {
        var profile = referenceProfile
        profile.medsAffectingHr = true
        #expect(profile.setupState == .unavailable)
        #expect(!profile.needsCalorieSetupAttention)
        #expect(!profile.hasRequiredInputs)
        #expect(profile.setupDetail.contains("medication"))

        // Missing basics remain actionable even when medication prevents estimates.
        profile.weightKg = nil
        #expect(profile.setupState == .incomplete)
        #expect(profile.needsCalorieSetupAttention)
    }

    @Test func confidenceDoesNotClaimValidationFromProfileCompleteness() {
        var profile = referenceProfile
        profile.maxHeartRate = 190
        profile.restHeartRate = 60
        profile.vo2Max = 50
        profile.rmrKcalPerDay = 1440
        #expect(CaloriesEstimator.confidence(for: profile, method: .hrrVO2) == 0)
        #expect(CaloriesEstimator.confidenceLabel(for: 1) == "Not validated")
    }

    private var referenceProfile: UserEnergyProfile {
        UserEnergyProfile(weightKg: 80, ageYears: 40, sexAtBirth: .male, heightCm: 180,
                          restHeartRate: nil, maxHeartRate: nil, vo2Max: nil,
                          rmrKcalPerDay: nil, bodyFatPercent: nil, medsAffectingHr: false)
    }

    private func sample(at time: TimeInterval, bpm: Int, contact: HeartRateSensorContactStatus = .unsupported) -> HeartRateSample {
        HeartRateSample(value: bpm, timestamp: Date(timeIntervalSince1970: 1000 + time),
                        workoutTime: time, sensorContactStatus: contact)
    }

    private func estimate(_ samples: [HeartRateSample], profile: UserEnergyProfile? = nil,
                          duration: TimeInterval? = nil, pauses: [WorkoutPause] = []) throws -> CaloriesEstimate {
        let status = CaloriesEstimator.estimate(samples: samples, profile: profile ?? referenceProfile,
                                               workoutDuration: duration, pauses: pauses)
        guard case let .available(result) = status else {
            throw EstimateFailure.unavailable
        }
        return result
    }

    private enum EstimateFailure: Error { case unavailable }

    private func makeSamples(bpm: Int, count: Int) -> [HeartRateSample] {
        let start = Date()
        return (0..<count).map { index in
            HeartRateSample(
                value: bpm,
                timestamp: start.addingTimeInterval(Double(index)),
                workoutTime: Double(index)
            )
        }
    }
}
