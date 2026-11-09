import Foundation
import HealthKit
import Testing
@testable import BPM

@MainActor
struct CalorieHealthAutofillTests {
    private let now = healthAutofillDate(2026, 11, 5)

    @Test func requestsOnlyProfileReadsOnExplicitFetch() async throws {
        let reader = CalorieHealthReaderMock()
        let service = CalorieHealthAutofillService(healthStore: reader, now: { now })
        #expect(reader.authorizationRequests == 0)

        _ = try await service.fetch()

        #expect(reader.authorizationRequests == 1)
        #expect(reader.writeTypes.isEmpty)
        #expect(Set(reader.readTypes.map(\.identifier)) == Set([
            HKCharacteristicTypeIdentifier.dateOfBirth.rawValue,
            HKCharacteristicTypeIdentifier.biologicalSex.rawValue,
            HKQuantityTypeIdentifier.bodyMass.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.vo2Max.rawValue
        ]))
        #expect(Set(reader.queries.map { $0.0 }) == Set([
            HKQuantityTypeIdentifier.bodyMass.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.vo2Max.rawValue
        ]))
        #expect(reader.queries.allSatisfy { $0.1 == now })
    }

    @Test func partialAccessKeepsReadableFields() async throws {
        let reader = CalorieHealthReaderMock()
        reader.dateOfBirthError = .readFailed
        reader.sex = .female
        reader.queryErrors = [.restingHeartRate]
        reader.samples[.bodyMass] = sample(.bodyMass, value: 72.5, unit: .gramUnit(with: .kilo))

        let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()

        #expect(snapshot.entries.map(\.field) == [.weight, .sex])
        #expect(snapshot.entries.first(where: { $0.field == .weight })?.value == "72.5")
        #expect(snapshot.entries.first(where: { $0.field == .sex })?.value == "female")
    }

    @Test func absentOrUnreadableDataReturnsEmptySnapshot() async throws {
        let reader = CalorieHealthReaderMock()
        reader.dateOfBirthError = .readFailed
        reader.sexError = .readFailed

        let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()

        #expect(snapshot.entries.isEmpty)
    }

    @Test func convertsSampleUnitsAndRetainsSampleDates() async throws {
        let reader = CalorieHealthReaderMock()
        let sampledAt = now.addingTimeInterval(-86_400)
        reader.samples[.bodyMass] = sample(.bodyMass, value: 180, unit: .pound(), end: sampledAt)
        reader.samples[.restingHeartRate] = sample(
            .restingHeartRate, value: 1, unit: .count().unitDivided(by: .second()), end: sampledAt
        )
        let vo2Unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())
        reader.samples[.vo2Max] = sample(.vo2Max, value: 47.2, unit: vo2Unit, end: sampledAt)

        let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()

        #expect(snapshot.entries.first(where: { $0.field == .weight })?.value == "81.65")
        #expect(snapshot.entries.first(where: { $0.field == .restingHR })?.value == "60")
        #expect(snapshot.entries.first(where: { $0.field == .vo2Max })?.value == "47.2")
        #expect(snapshot.entries.allSatisfy { $0.sampleDate == sampledAt })
    }

    @Test func ageUsesBirthdayBoundaryAndGregorianComponents() async throws {
        let reader = CalorieHealthReaderMock()
        reader.birth = DateComponents(year: 1990, month: 11, day: 5)
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeBirthday = healthAutofillDate(2026, 11, 4)
        let before = try await CalorieHealthAutofillService(
            healthStore: reader, now: { beforeBirthday }, calendar: calendar
        ).fetch()
        let birthday = try await CalorieHealthAutofillService(
            healthStore: reader, now: { now }, calendar: calendar
        ).fetch()

        #expect(before.entries.first(where: { $0.field == .age })?.value == "35")
        #expect(birthday.entries.first(where: { $0.field == .age })?.value == "36")
        #expect(birthday.entries.first(where: { $0.field == .age })?.sampleDate == nil)
    }

    @Test func invalidPartialFutureAndOutOfRangeBirthdaysAreOmitted() async throws {
        let invalidBirthdays = [
            DateComponents(year: 1990, month: 11),
            DateComponents(month: 11, day: 5),
            DateComponents(year: 1990, month: 2, day: 30),
            DateComponents(year: 2027, month: 1, day: 1),
            DateComponents(year: 2026, month: 11, day: 5),
            DateComponents(year: 1890, month: 1, day: 1)
        ]
        for birthday in invalidBirthdays {
            let reader = CalorieHealthReaderMock()
            reader.birth = birthday
            let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()
            #expect(snapshot.entries.allSatisfy { $0.field != .age })
        }
    }

    @Test func importsOnlyExplicitMaleOrFemaleSex() async throws {
        let cases: [(HKBiologicalSex, String?)] = [(.male, "male"), (.female, "female"), (.other, nil), (.notSet, nil)]
        for (sex, expected) in cases {
            let reader = CalorieHealthReaderMock()
            reader.sex = sex
            let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()
            #expect(snapshot.entries.first(where: { $0.field == .sex })?.value == expected)
        }
    }

    @Test func rejectsOutOfRangeAndFutureQuantitiesBeforeRounding() async throws {
        let cases: [(HKQuantityTypeIdentifier, Double, HKUnit)] = [
            (.bodyMass, 0.999, .gramUnit(with: .kilo)),
            (.bodyMass, 1000.001, .gramUnit(with: .kilo)),
            (.restingHeartRate, 19.99, .count().unitDivided(by: .minute())),
            (.restingHeartRate, 250.01, .count().unitDivided(by: .minute())),
            (.vo2Max, 0.99, HKUnit(from: "ml/kg*min")),
            (.vo2Max, 150.001, HKUnit(from: "ml/kg*min"))
        ]
        for (type, value, unit) in cases {
            let reader = CalorieHealthReaderMock()
            reader.samples[type] = sample(type, value: value, unit: unit)
            let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()
            #expect(snapshot.entries.isEmpty)
        }
        let reader = CalorieHealthReaderMock()
        reader.samples[.bodyMass] = sample(
            .bodyMass, value: 70, unit: .gramUnit(with: .kilo), end: now.addingTimeInterval(1)
        )
        let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()
        #expect(snapshot.entries.isEmpty)
    }

    @Test func requestFailureAndUnavailableDeviceHaveUserFacingErrors() async {
        let reader = CalorieHealthReaderMock()
        reader.isHealthDataAvailable = false
        do {
            _ = try await CalorieHealthAutofillService(healthStore: reader).fetch()
            Issue.record("Expected unavailable error")
        } catch {
            #expect(error.localizedDescription.contains("unavailable"))
        }
        #expect(reader.authorizationRequests == 0)
        reader.isHealthDataAvailable = true
        reader.authorizationError = .readFailed
        do {
            _ = try await CalorieHealthAutofillService(healthStore: reader).fetch()
            Issue.record("Expected request failure")
        } catch {
            #expect(error.localizedDescription.contains("Try again"))
            #expect(!error.localizedDescription.lowercased().contains("denied"))
        }
        #expect(reader.queries.isEmpty)
    }

    @Test func fillsOnlyBlanksAndMarksOnlyImportedFieldsLocal() {
        let defaults = makeDefaults()
        defaults.set("invalid manual weight", forKey: CaloriesDefaultsKey.weightKg)
        defaults.set(" \n", forKey: CaloriesDefaultsKey.ageYears)
        defaults.set("female", forKey: CaloriesDefaultsKey.sexAtBirth)
        let snapshot = CalorieHealthAutofillSnapshot(entries: [
            .init(field: .weight, value: "80", sampleDate: now),
            .init(field: .age, value: "36", sampleDate: nil),
            .init(field: .sex, value: "male", sampleDate: nil),
            .init(field: .restingHR, value: "60", sampleDate: now),
            .init(field: .vo2Max, value: "45", sampleDate: now)
        ])

        #expect(snapshot.fillMissingValues(in: defaults) == [.age, .restingHR, .vo2Max])
        #expect(defaults.string(forKey: CaloriesDefaultsKey.weightKg) == "invalid manual weight")
        #expect(defaults.string(forKey: CaloriesDefaultsKey.sexAtBirth) == "female")
        #expect(defaults.string(forKey: CaloriesDefaultsKey.ageYears) == "36")
        for field in [CalorieHealthField.age, .restingHR, .vo2Max] {
            #expect(defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: field.defaultsKey)))
        }
        #expect(!defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.weightKg)))
        #expect(snapshot.fillMissingValues(in: defaults).isEmpty)
    }

    @Test func doesNotOverwriteEditDuringAuthorizationOrAfterPreview() async throws {
        let defaults = makeDefaults()
        let reader = CalorieHealthReaderMock()
        reader.samples[.bodyMass] = sample(.bodyMass, value: 80, unit: .gramUnit(with: .kilo))
        reader.birth = DateComponents(year: 1990, month: 11, day: 5)
        reader.onAuthorization = {
            await Task.yield()
            defaults.set("75", forKey: CaloriesDefaultsKey.weightKg)
        }
        let snapshot = try await CalorieHealthAutofillService(healthStore: reader, now: { now }).fetch()
        defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)

        #expect(snapshot.fillMissingValues(in: defaults).isEmpty)
        #expect(defaults.string(forKey: CaloriesDefaultsKey.weightKg) == "75")
        #expect(defaults.string(forKey: CaloriesDefaultsKey.ageYears) == "40")
    }

    @Test func skipsOptionalValuesThatConflictWithCurrentSettings() {
        let defaults = makeDefaults()
        defaults.set("60", forKey: CaloriesDefaultsKey.maxHrBpm)
        defaults.set("3600", forKey: CaloriesDefaultsKey.rmrKcalPerDay)
        let snapshot = CalorieHealthAutofillSnapshot(entries: [
            .init(field: .weight, value: "50", sampleDate: now),
            .init(field: .restingHR, value: "60", sampleDate: now),
            .init(field: .vo2Max, value: "10", sampleDate: now)
        ])

        #expect(snapshot.fillMissingValues(in: defaults) == [.weight])
        #expect(defaults.string(forKey: CaloriesDefaultsKey.restHrBpm) == nil)
        #expect(defaults.string(forKey: CaloriesDefaultsKey.vo2Max) == nil)
        #expect(!defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.restHrBpm)))
    }

    @Test func validatesSnapshotValuesAndAgeDerivedMaxWhenApplying() {
        let defaults = makeDefaults()
        let invalid = CalorieHealthAutofillSnapshot(entries: [
            .init(field: .weight, value: "nan", sampleDate: nil),
            .init(field: .age, value: "131", sampleDate: nil),
            .init(field: .sex, value: "other", sampleDate: nil),
            .init(field: .restingHR, value: "19", sampleDate: nil),
            .init(field: .vo2Max, value: "inf", sampleDate: nil)
        ])
        #expect(invalid.fillMissingValues(in: defaults).isEmpty)

        let snapshot = CalorieHealthAutofillSnapshot(entries: [
            .init(field: .age, value: "100", sampleDate: nil),
            .init(field: .restingHR, value: "140", sampleDate: now)
        ])
        #expect(snapshot.fillMissingValues(in: defaults) == [.age])
    }

    private func sample(
        _ type: HKQuantityTypeIdentifier, value: Double, unit: HKUnit, end: Date? = nil
    ) -> HKQuantitySample {
        let date = end ?? now.addingTimeInterval(-60)
        return HKQuantitySample(
            type: HKObjectType.quantityType(forIdentifier: type)!,
            quantity: HKQuantity(unit: unit, doubleValue: value), start: date, end: date
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "calorie-health-autofill-\(UUID().uuidString)")!
    }
}

private func healthAutofillDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private enum HealthAutofillTestError: Error {
    case readFailed
}

private final class CalorieHealthReaderMock: CalorieHealthDataReading {
    var isHealthDataAvailable = true
    var authorizationRequests = 0
    var readTypes: Set<HKObjectType> = []
    var writeTypes: Set<HKSampleType> = []
    var authorizationError: HealthAutofillTestError?
    var onAuthorization: (() async -> Void)?
    var dateOfBirthError: HealthAutofillTestError?
    var sexError: HealthAutofillTestError?
    var birth = DateComponents()
    var sex = HKBiologicalSex.notSet
    var queryErrors: Set<HKQuantityTypeIdentifier> = []
    var samples: [HKQuantityTypeIdentifier: HKQuantitySample] = [:]
    var queries: [(String, Date)] = []

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        authorizationRequests += 1
        writeTypes = toShare
        readTypes = read
        await onAuthorization?()
        if let authorizationError { throw authorizationError }
    }

    func dateOfBirthComponents() throws -> DateComponents {
        if let dateOfBirthError { throw dateOfBirthError }
        return birth
    }

    func biologicalSex() throws -> HKBiologicalSex {
        if let sexError { throw sexError }
        return sex
    }

    func latestQuantity(for identifier: HKQuantityTypeIdentifier, before date: Date) async throws -> HKQuantitySample? {
        queries.append((identifier.rawValue, date))
        if queryErrors.contains(identifier) { throw HealthAutofillTestError.readFailed }
        return samples[identifier]
    }
}
