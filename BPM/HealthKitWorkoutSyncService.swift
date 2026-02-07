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
    func save(_ object: HKObject) async throws
    func add(_ samples: [HKSample], to workout: HKWorkout) async throws
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

    func save(_ object: HKObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(object) { success, error in
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

    func add(_ samples: [HKSample], to workout: HKWorkout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.add(samples, to: workout) { success, error in
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

        let workout = makeWorkout(record: record, activityType: activityType)
        do {
            try await healthStore.save(workout)
        } catch {
            throw HealthKitSyncError.writeFailed(error.localizedDescription)
        }

        let associatedSamples = makeAssociatedSamples(record: record)
        if !associatedSamples.isEmpty {
            do {
                try await healthStore.add(associatedSamples, to: workout)
            } catch {
                throw HealthKitSyncError.writeFailed(error.localizedDescription)
            }
        }

        return HealthKitSyncResult(workoutUUID: workout.uuid)
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

    private func makeWorkout(record: WorkoutRecord, activityType: HKWorkoutActivityType) -> HKWorkout {
        let start = record.startAt
        let computedEnd = record.endAt > start
            ? record.endAt
            : start.addingTimeInterval(max(record.durationSeconds, 1))
        let totalEnergy = record.caloriesTotal.map { HKQuantity(unit: .kilocalorie(), doubleValue: $0) }

        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: record.id.uuidString,
            "BPMWorkoutRecordID": record.id.uuidString,
            "BPMAppVersion": record.appVersion,
            "BPMSource": record.source
        ]
        if let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            metadata["BPMWorkoutTitle"] = title
        }

        return HKWorkout(
            activityType: activityType,
            start: start,
            end: computedEnd,
            duration: computedEnd.timeIntervalSince(start),
            totalEnergyBurned: totalEnergy,
            totalDistance: nil,
            metadata: metadata
        )
    }

    private func makeAssociatedSamples(record: WorkoutRecord) -> [HKSample] {
        let start = record.startAt
        let end = record.endAt > start
            ? record.endAt
            : start.addingTimeInterval(max(record.durationSeconds, 1))

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

        if let activeEnergyType, let activeCalories = record.caloriesActive, activeCalories > 0 {
            let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: activeCalories)
            samples.append(
                HKQuantitySample(
                    type: activeEnergyType,
                    quantity: quantity,
                    start: start,
                    end: end
                )
            )
        }

        return samples
    }
}
