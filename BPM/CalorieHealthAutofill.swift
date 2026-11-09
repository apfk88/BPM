import Foundation
import HealthKit

enum HealthKitImportedPreferences {
    static func localOnlyKey(for defaultsKey: String) -> String {
        "BPM_HealthImported_LocalOnly_" + defaultsKey
    }
}

enum CalorieHealthField: String, CaseIterable, Identifiable {
    case weight, age, sex, restingHR, vo2Max

    var id: Self { self }

    var defaultsKey: String {
        switch self {
        case .weight: return CaloriesDefaultsKey.weightKg
        case .age: return CaloriesDefaultsKey.ageYears
        case .sex: return CaloriesDefaultsKey.sexAtBirth
        case .restingHR: return CaloriesDefaultsKey.restHrBpm
        case .vo2Max: return CaloriesDefaultsKey.vo2Max
        }
    }

    var title: String {
        switch self {
        case .weight: return "Weight"
        case .age: return "Age"
        case .sex: return "Sex"
        case .restingHR: return "Resting HR"
        case .vo2Max: return "VO2max"
        }
    }

    fileprivate func accepts(_ value: String) -> Bool {
        switch self {
        case .weight: return Self.validDouble(value, in: 1...1000)
        case .age: return Int(value).map { (1...130).contains($0) } ?? false
        case .sex: return SexAtBirth(rawValue: value) != nil
        case .restingHR: return Int(value).map { (20...250).contains($0) } ?? false
        case .vo2Max: return Self.validDouble(value, in: 1...150)
        }
    }

    private static func validDouble(_ text: String, in range: ClosedRange<Double>) -> Bool {
        guard let value = Double(text), value.isFinite else { return false }
        return range.contains(value)
    }
}

struct CalorieHealthAutofillEntry: Identifiable {
    let field: CalorieHealthField
    let value: String
    let sampleDate: Date?

    var id: CalorieHealthField { field }
}

struct CalorieHealthAutofillSnapshot {
    let entries: [CalorieHealthAutofillEntry]

    /// Recheck at confirmation time so an in-flight read cannot overwrite an edit.
    @discardableResult
    func fillMissingValues(in defaults: UserDefaults) -> [CalorieHealthField] {
        var filled: [CalorieHealthField] = []
        // Apply basics first so optional values are checked against the resulting profile.
        for field in CalorieHealthField.allCases {
            guard Self.isBlank(defaults.object(forKey: field.defaultsKey)),
                  let entry = entries.first(where: { $0.field == field }),
                  field.accepts(entry.value) else { continue }

            let profile = UserEnergyProfileStore.currentProfile(defaults: defaults)
            if field == .restingHR,
               let maximum = profile.derivedMaxHeartRate,
               let resting = Double(entry.value), resting >= maximum {
                continue
            }
            if field == .vo2Max,
               let maximum = Double(entry.value), maximum <= profile.vo2RestValue {
                continue
            }
            defaults.set(true, forKey: HealthKitImportedPreferences.localOnlyKey(for: field.defaultsKey))
            defaults.set(entry.value, forKey: field.defaultsKey)
            filled.append(field)
        }
        return filled
    }

    private static func isBlank(_ object: Any?) -> Bool {
        guard let object else { return true }
        guard let text = object as? String else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum CalorieHealthAutofillError: LocalizedError {
    case unavailable
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health is unavailable on this device. Enter your details manually."
        case .requestFailed: return "Could not load details from Apple Health. Try again or enter them manually."
        }
    }
}

protocol CalorieHealthDataReading {
    var isHealthDataAvailable: Bool { get }
    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws
    func dateOfBirthComponents() throws -> DateComponents
    func biologicalSex() throws -> HKBiologicalSex
    func latestQuantity(for identifier: HKQuantityTypeIdentifier, before date: Date) async throws -> HKQuantitySample?
}

final class HKCalorieHealthStoreAdapter: CalorieHealthDataReading {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: toShare, read: read) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CalorieHealthAutofillError.requestFailed)
                }
            }
        }
    }

    func dateOfBirthComponents() throws -> DateComponents {
        try healthStore.dateOfBirthComponents()
    }

    func biologicalSex() throws -> HKBiologicalSex {
        try healthStore.biologicalSex().biologicalSex
    }

    func latestQuantity(for identifier: HKQuantityTypeIdentifier, before date: Date) async throws -> HKQuantitySample? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: date, options: .strictEndDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples?.first as? HKQuantitySample)
                }
            }
            healthStore.execute(query)
        }
    }
}

@MainActor
final class CalorieHealthAutofillService {
    private let healthStore: CalorieHealthDataReading
    private let failureReporter: AppFailureReporter
    private let now: () -> Date
    private let calendar: Calendar

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    init(
        healthStore: CalorieHealthDataReading = HKCalorieHealthStoreAdapter(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = Calendar(identifier: .gregorian),
        failureReporter: AppFailureReporter = AppFailureReporter()
    ) {
        self.healthStore = healthStore
        self.failureReporter = failureReporter
        self.now = now
        // HealthKit birthdays contain Gregorian year/month/day components.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
    }

    func fetch() async throws -> CalorieHealthAutofillSnapshot {
        guard healthStore.isHealthDataAvailable else {
            failureReporter.report(.healthAutofill, .authorize, category: .unavailable)
            throw CalorieHealthAutofillError.unavailable
        }
        let optionalTypes: [HKObjectType?] = [
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth),
            HKObjectType.characteristicType(forIdentifier: .biologicalSex),
            HKObjectType.quantityType(forIdentifier: .bodyMass),
            HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            HKObjectType.quantityType(forIdentifier: .vo2Max)
        ]
        let types = Set(optionalTypes.compactMap { $0 })
        do {
            try await healthStore.requestAuthorization(toShare: [], read: types)
        } catch {
            if AppFailureCategory.isCancellation(error) { throw error }
            failureReporter.report(.healthAutofill, .authorize, error: error)
            throw CalorieHealthAutofillError.requestFailed
        }
        failureReporter.recovered(.healthAutofill, .authorize)

        let date = now()
        var entries: [CalorieHealthAutofillEntry] = []
        // Read failures and empty results are indistinguishable from unavailable data.
        // Keep other fields usable without claiming permission was denied.
        if let birth = try? healthStore.dateOfBirthComponents(), let age = age(from: birth, at: date) {
            entries.append(.init(field: .age, value: String(age), sampleDate: nil))
        }
        if let sex = try? healthStore.biologicalSex() {
            switch sex {
            case .male: entries.append(.init(field: .sex, value: SexAtBirth.male.rawValue, sampleDate: nil))
            case .female: entries.append(.init(field: .sex, value: SexAtBirth.female.rawValue, sampleDate: nil))
            default: break
            }
        }
        let quantities: [(CalorieHealthField, HKQuantityTypeIdentifier, HKUnit)] = [
            (.weight, .bodyMass, .gramUnit(with: .kilo)),
            (.restingHR, .restingHeartRate, .count().unitDivided(by: .minute())),
            (.vo2Max, .vo2Max, .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute()))
        ]
        for (field, identifier, unit) in quantities {
            guard let sample = try? await healthStore.latestQuantity(for: identifier, before: date),
                  sample.quantityType.identifier == identifier.rawValue,
                  sample.endDate <= date,
                  sample.startDate <= sample.endDate,
                  sample.quantity.is(compatibleWith: unit) else { continue }
            let value = sample.quantity.doubleValue(for: unit)
            guard value.isFinite else { continue }
            let text: String
            if field == .restingHR {
                guard (20...250).contains(value) else { continue }
                text = String(Int(value.rounded()))
            } else if field == .weight {
                guard (1...1000).contains(value) else { continue }
                text = Self.decimalString(value)
            } else {
                guard (1...150).contains(value) else { continue }
                text = Self.decimalString(value)
            }
            guard field.accepts(text) else { continue }
            entries.append(.init(field: field, value: text, sampleDate: sample.endDate))
        }
        return .init(entries: entries.sorted { $0.field.order < $1.field.order })
    }

    private func age(from components: DateComponents, at now: Date) -> Int? {
        guard let year = components.year, let month = components.month, let day = components.day,
              year > 0,
              let birthday = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              birthday <= now else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: birthday)
        guard actual.year == year, actual.month == month, actual.day == day,
              let age = calendar.dateComponents([.year], from: birthday, to: now).year,
              (1...130).contains(age) else { return nil }
        return age
    }

    private static func decimalString(_ value: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

private extension CalorieHealthField {
    var order: Int { Self.allCases.firstIndex(of: self)! }
}
