import Foundation
import HealthKit
import Testing
@testable import BPM

struct HealthKitWorkoutSyncServiceTests {
    @Test func requestAuthorizationTransitionsToAuthorized() async throws {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .notDetermined
        mockStore.onRequestAuthorization = {
            mockStore.authorizationStatusValue = .sharingAuthorized
        }

        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }
        try await service.requestWriteAuthorization()

        let state = await MainActor.run { service.authorizationState }
        #expect(state == .authorized)
        #expect(mockStore.requestAuthorizationCalled)
    }

    @Test func deniedAuthorizationThrowsNotAuthorized() async {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .sharingDenied

        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }

        do {
            try await service.requestWriteAuthorization()
            #expect(Bool(false), "Expected authorization to fail")
        } catch let error as HealthKitSyncError {
            switch error {
            case .notAuthorized:
                let state = await MainActor.run { service.authorizationState }
                #expect(state == .denied)
            default:
                #expect(Bool(false), "Unexpected HealthKitSyncError")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
    }

    @Test func syncFiltersInvalidHeartRateSamples() async throws {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .sharingAuthorized
        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }

        let now = Date()
        let record = makeRecord(
            start: now,
            end: now.addingTimeInterval(120),
            caloriesTotal: 90,
            caloriesActive: nil,
            samples: [
                WorkoutHeartRateSample(timestamp: now.addingTimeInterval(1), bpm: 130, workoutTime: 1),
                WorkoutHeartRateSample(timestamp: now.addingTimeInterval(2), bpm: 0, workoutTime: 2),
                WorkoutHeartRateSample(timestamp: now.addingTimeInterval(3), bpm: -5, workoutTime: 3),
                WorkoutHeartRateSample(timestamp: now.addingTimeInterval(130), bpm: 145, workoutTime: 130),
                WorkoutHeartRateSample(timestamp: now.addingTimeInterval(4), bpm: 142, workoutTime: 4)
            ]
        )

        _ = try await service.syncWorkout(record: record, activityType: .functionalStrengthTraining)

        let heartRateSamples = mockStore.savedSamples.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.heartRate.rawValue }
        #expect(heartRateSamples.count == 2)
    }

    @Test func syncUsesFullSessionStartAndEnd() async throws {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .sharingAuthorized
        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }

        let start = Date().addingTimeInterval(-600)
        let end = start.addingTimeInterval(540)
        let record = makeRecord(start: start, end: end, caloriesTotal: nil, caloriesActive: nil, samples: [])

        _ = try await service.syncWorkout(record: record, activityType: .running)

        #expect(mockStore.savedStart == start)
        #expect(mockStore.savedEnd == end)
    }

    @Test func syncSetsTotalCaloriesOnWorkout() async throws {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .sharingAuthorized
        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }

        let start = Date()
        let end = start.addingTimeInterval(180)
        let record = makeRecord(start: start, end: end, caloriesTotal: 123.4, caloriesActive: nil, samples: [])

        _ = try await service.syncWorkout(record: record, activityType: .cycling)

        let energySamples = mockStore.savedSamples.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType.identifier == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue }
        #expect(energySamples.count == 1)
        let totalEnergy = energySamples.first?.quantity.doubleValue(for: .kilocalorie())
        #expect(totalEnergy != nil)
        #expect(abs((totalEnergy ?? 0) - 123.4) < 0.01)
    }

    @Test func syncReturnsWorkoutUUID() async throws {
        let mockStore = MockHealthStore()
        mockStore.authorizationStatusValue = .sharingAuthorized
        let service = await MainActor.run { HealthKitWorkoutSyncService(healthStore: mockStore) }

        let start = Date()
        let end = start.addingTimeInterval(60)
        let record = makeRecord(start: start, end: end, caloriesTotal: nil, caloriesActive: nil, samples: [])

        let result = try await service.syncWorkout(record: record, activityType: .other)
        #expect(result.workoutUUID == mockStore.savedWorkoutUUID)
    }

    private func makeRecord(
        start: Date,
        end: Date,
        caloriesTotal: Double?,
        caloriesActive: Double?,
        samples: [WorkoutHeartRateSample]
    ) -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(),
            schemaVersion: WorkoutRecord.schemaVersion,
            title: "Session",
            startAt: start,
            endAt: end,
            durationSeconds: end.timeIntervalSince(start),
            avgHr: 130,
            maxHr: 150,
            minHr: 115,
            hrv: nil,
            hrr: nil,
            caloriesTotal: caloriesTotal,
            caloriesActive: caloriesActive,
            hrSamples: samples,
            zones: [],
            sets: [],
            notes: nil,
            source: "phone",
            appVersion: "1.9 (1)",
            healthKitWorkoutUUID: nil,
            healthKitSyncedAt: nil,
            healthKitLastError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

private final class MockHealthStore: HealthStoreWriting {
    var isHealthDataAvailable: Bool = true
    var authorizationStatusValue: HKAuthorizationStatus = .sharingAuthorized
    var requestAuthorizationCalled = false
    var requestAuthorizationError: Error?
    var saveWorkoutError: Error?
    var savedWorkoutUUID = UUID()
    var savedActivityType: HKWorkoutActivityType?
    var savedStart: Date?
    var savedEnd: Date?
    var savedMetadata: [String: Any] = [:]
    var savedSamples: [HKSample] = []
    var onRequestAuthorization: (() -> Void)?

    func authorizationStatus(for objectType: HKObjectType) -> HKAuthorizationStatus {
        authorizationStatusValue
    }

    func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>?) async throws {
        requestAuthorizationCalled = true
        onRequestAuthorization?()
        if let requestAuthorizationError {
            throw requestAuthorizationError
        }
    }

    func saveWorkout(
        activityType: HKWorkoutActivityType,
        start: Date,
        end: Date,
        metadata: [String: Any],
        samples: [HKSample]
    ) async throws -> UUID {
        if let saveWorkoutError {
            throw saveWorkoutError
        }
        savedActivityType = activityType
        savedStart = start
        savedEnd = end
        savedMetadata = metadata
        savedSamples = samples
        return savedWorkoutUUID
    }
}
