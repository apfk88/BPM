#if DEBUG
import Foundation
import HealthKit

/// In-memory reads for UI tests. Never requests access to or writes to HealthKit.
enum CalorieHealthAutofillUITestFixture {
    @MainActor
    static func service() -> CalorieHealthAutofillService? {
        let arguments = ProcessInfo.processInfo.arguments
        let empty = arguments.contains("--calorie-health-autofill-empty-fixture")
        guard empty || arguments.contains("--calorie-health-autofill-fixture") else { return nil }
        let now = Date()
        let reader = CalorieHealthUITestReader(empty: empty, now: now)
        return CalorieHealthAutofillService(healthStore: reader, now: { now })
    }
}

private final class CalorieHealthUITestReader: CalorieHealthDataReading {
    let isHealthDataAvailable = true
    private let empty: Bool
    private let now: Date

    init(empty: Bool, now: Date) {
        self.empty = empty
        self.now = now
    }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}

    func dateOfBirthComponents() throws -> DateComponents {
        guard !empty else { return DateComponents() }
        let calendar = Calendar(identifier: .gregorian)
        guard let birthday = calendar.date(byAdding: .year, value: -37, to: now) else { return DateComponents() }
        return calendar.dateComponents([.year, .month, .day], from: birthday)
    }

    func biologicalSex() throws -> HKBiologicalSex { empty ? .notSet : .male }

    func latestQuantity(for identifier: HKQuantityTypeIdentifier, before date: Date) async throws -> HKQuantitySample? {
        guard !empty, let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let value: Double
        let unit: HKUnit
        switch identifier {
        case .bodyMass:
            value = 80
            unit = .gramUnit(with: .kilo)
        case .restingHeartRate:
            value = 60
            unit = .count().unitDivided(by: .minute())
        case .vo2Max:
            value = 50
            unit = .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())
        default:
            return nil
        }
        return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: now, end: now)
    }
}
#endif
