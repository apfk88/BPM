//
//  HealthKitWorkoutSyncService.swift
//  BPM
//

import Foundation
import HealthKit

enum HealthKitAuthorizationState: Equatable {
    case unknown
    case requesting
    case authorized
    case denied
    case unavailable
}

enum HealthKitSyncError: Error {
    case unavailable
    case notAuthorized
    case authorizationFailed(String)
    case writeFailed(String)

    var userFacingMessage: String {
        switch self {
        case .unavailable:
            return "Apple Health is unavailable on this device."
        case .notAuthorized:
            return "Apple Health permissions are not enabled. Check iOS Settings."
        case let .authorizationFailed(message):
            return message.isEmpty
                ? "Could not authorize Apple Health."
                : "Could not authorize Apple Health: \(message)"
        case let .writeFailed(message):
            return message.isEmpty
                ? "Could not save workout to Apple Health."
                : "Could not save workout to Apple Health: \(message)"
        }
    }
}

struct HealthKitSyncResult {
    let workoutUUID: UUID
}

protocol HealthStoreWriting {
    var isHealthDataAvailable: Bool { get }
    func authorizationStatus(for objectType: HKObjectType) -> HKAuthorizationStatus
    func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>?) async throws
    func saveWorkout(
        activityType: HKWorkoutActivityType,
        start: Date,
        end: Date,
        metadata: [String: Any],
        samples: [HKSample]
    ) async throws -> UUID
}

final class HKHealthStoreAdapter: HealthStoreWriting {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func authorizationStatus(for objectType: HKObjectType) -> HKAuthorizationStatus {
        healthStore.authorizationStatus(for: objectType)
    }

    func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.notAuthorized)
                }
            }
        }
    }

    func saveWorkout(
        activityType: HKWorkoutActivityType,
        start: Date,
        end: Date,
        metadata: [String: Any],
        samples: [HKSample]
    ) async throws -> UUID {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = .unknown

        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: configuration,
            device: nil
        )

        try await beginCollection(for: builder, at: start)
        if !metadata.isEmpty {
            try await addMetadata(metadata, to: builder)
        }
        if !samples.isEmpty {
            try await add(samples, to: builder)
        }
        try await endCollection(for: builder, at: end)
        return try await finishWorkout(for: builder)
    }

    private func beginCollection(for builder: HKWorkoutBuilder, at start: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: start) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.writeFailed(""))
                }
            }
        }
    }

    private func addMetadata(_ metadata: [String: Any], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addMetadata(metadata) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.writeFailed(""))
                }
            }
        }
    }

    private func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.writeFailed(""))
                }
            }
        }
    }

    private func endCollection(for builder: HKWorkoutBuilder, at end: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: end) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitSyncError.writeFailed(""))
                }
            }
        }
    }

    private func finishWorkout(for builder: HKWorkoutBuilder) async throws -> UUID {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let workout {
                    continuation.resume(returning: workout.uuid)
                } else {
                    continuation.resume(throwing: HealthKitSyncError.writeFailed(""))
                }
            }
        }
    }
}

@MainActor
final class HealthKitWorkoutSyncService: ObservableObject {
    static let shared = HealthKitWorkoutSyncService()

    @Published private(set) var authorizationState: HealthKitAuthorizationState = .unknown

    private let healthStore: HealthStoreWriting
    private let workoutType = HKObjectType.workoutType()
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
    private let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)

    init(healthStore: HealthStoreWriting = HKHealthStoreAdapter()) {
        self.healthStore = healthStore
        refreshAuthorizationState()
    }

    func refreshAuthorizationState() {
        guard healthStore.isHealthDataAvailable else {
            authorizationState = .unavailable
            return
        }

        switch healthStore.authorizationStatus(for: workoutType) {
        case .sharingAuthorized:
            authorizationState = .authorized
        case .sharingDenied:
            authorizationState = .denied
        case .notDetermined:
            authorizationState = .unknown
        @unknown default:
            authorizationState = .unknown
        }
    }

    func requestWriteAuthorization() async throws {
        guard healthStore.isHealthDataAvailable else {
            authorizationState = .unavailable
            throw HealthKitSyncError.unavailable
        }

        authorizationState = .requesting
        do {
            try await healthStore.requestAuthorization(toShare: writeTypes(), read: nil)
        } catch let syncError as HealthKitSyncError {
            refreshAuthorizationState()
            throw syncError
        } catch {
            refreshAuthorizationState()
            throw HealthKitSyncError.authorizationFailed(error.localizedDescription)
        }

        refreshAuthorizationState()
        guard authorizationState == .authorized else {
            throw HealthKitSyncError.notAuthorized
        }
    }

    func syncWorkout(record: WorkoutRecord, activityType: HKWorkoutActivityType) async throws -> HealthKitSyncResult {
        guard healthStore.isHealthDataAvailable else {
            authorizationState = .unavailable
            throw HealthKitSyncError.unavailable
        }

        if authorizationState != .authorized {
            try await requestWriteAuthorization()
        }

        let bounds = workoutBounds(for: record)
        let metadata = makeWorkoutMetadata(record: record)
        let associatedSamples = makeAssociatedSamples(
            record: record,
            start: bounds.start,
            end: bounds.end
        )

        let workoutUUID: UUID
        do {
            workoutUUID = try await healthStore.saveWorkout(
                activityType: activityType,
                start: bounds.start,
                end: bounds.end,
                metadata: metadata,
                samples: associatedSamples
            )
        } catch {
            throw HealthKitSyncError.writeFailed(error.localizedDescription)
        }

        return HealthKitSyncResult(workoutUUID: workoutUUID)
    }

    private func writeTypes() -> Set<HKSampleType> {
        var types: Set<HKSampleType> = [workoutType]
        if let heartRateType {
            types.insert(heartRateType)
        }
        if let activeEnergyType {
            types.insert(activeEnergyType)
        }
        return types
    }

    private func workoutBounds(for record: WorkoutRecord) -> (start: Date, end: Date) {
        let start = record.startAt
        let computedEnd = record.endAt > start
            ? record.endAt
            : start.addingTimeInterval(max(record.durationSeconds, 1))
        return (start, computedEnd)
    }

    private func makeWorkoutMetadata(record: WorkoutRecord) -> [String: Any] {
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: record.id.uuidString,
            "BPMWorkoutRecordID": record.id.uuidString,
            "BPMAppVersion": record.appVersion,
            "BPMSource": record.source
        ]
        if let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            metadata["BPMWorkoutTitle"] = title
        }
        return metadata
    }

    private func makeAssociatedSamples(record: WorkoutRecord, start: Date, end: Date) -> [HKSample] {
        var samples: [HKSample] = []

        if let heartRateType {
            let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
            for sample in record.hrSamples where sample.bpm > 0 {
                guard sample.timestamp >= start, sample.timestamp <= end else { continue }
                let sampleEnd = min(end, sample.timestamp.addingTimeInterval(1))
                let quantity = HKQuantity(unit: heartRateUnit, doubleValue: Double(sample.bpm))
                samples.append(
                    HKQuantitySample(
                        type: heartRateType,
                        quantity: quantity,
                        start: sample.timestamp,
                        end: sampleEnd
                    )
                )
            }
        }

        if let activeEnergyType {
            let caloriesValue = record.caloriesActive ?? record.caloriesTotal
            if let caloriesValue, caloriesValue > 0 {
                let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: caloriesValue)
                samples.append(
                    HKQuantitySample(
                        type: activeEnergyType,
                        quantity: quantity,
                        start: start,
                        end: end
                    )
                )
            }
        }

        return samples
    }
}
