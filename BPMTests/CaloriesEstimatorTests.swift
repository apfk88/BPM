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
        let samples = makeSamples(bpm: 60, count: 300)

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
        let samples = makeSamples(bpm: 150, count: 300)

        let status = CaloriesEstimator.estimate(samples: samples, profile: profile)
        guard case let .available(estimate) = status else {
            #expect(Bool(false), "Expected available calories estimate")
            return
        }

        #expect(estimate.method == .hrRegression)
        let expectedPerMin = 0.239 * (-55.097 + 0.631 * 150 + 0.199 * 80 + 0.202 * 40)
        #expect(abs(estimate.totalKcal - expectedPerMin * 5) < 0.2)
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
