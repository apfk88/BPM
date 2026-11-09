import XCTest
import HealthKit
import CoreBluetooth
@testable import BPM

final class ReliabilityAnalyticsTests: XCTestCase {
    func testFailureCategoriesUseFixedLabelsInsteadOfRawErrorContent() {
        let cases: [(Error, AppFailureCategory)] = [
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .storageFull),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), .permissionDenied),
            (NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue), .deviceLocked),
            (NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue), .permissionDenied),
            (NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue), .timeout),
            (URLError(.notConnectedToInternet), .network),
            (URLError(.badServerResponse), .invalidResponse),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private workout contents")), .corruptData)
        ]
        for (error, expected) in cases { XCTAssertEqual(AppFailureCategory(error: error), expected) }
        var payloads: [[String: String]] = []
        let reporter = AppFailureReporter { event, payload in
            XCTAssertEqual(event, .appFailure)
            payloads.append(payload)
        }
        reporter.report(.workoutStore, .save,
                        error: NSError(domain: "private-user-domain", code: 1234,
                                       userInfo: [NSLocalizedDescriptionKey: "My private workout, /private/path, 180 BPM"]))
        XCTAssertEqual(payloads, [["component": "workout_store", "operation": "save", "category": "unknown"]])
    }

    func testRepeatedFailureCallbacksCountOnceUntilRecovery() {
        var events: [[String: String]] = []
        let reporter = AppFailureReporter { _, payload in events.append(payload) }
        for _ in 0..<100 { reporter.report(.bluetooth, .connect, category: .timeout) }
        XCTAssertEqual(events.count, 1)
        reporter.recovered(.bluetooth, .subscribe)
        reporter.report(.bluetooth, .connect, category: .timeout)
        XCTAssertEqual(events.count, 1)
        reporter.recovered(.bluetooth)
        reporter.report(.bluetooth, .connect, category: .timeout)
        XCTAssertEqual(events.count, 2)
    }

    func testCancellationDoesNotCountAsFailure() {
        var count = 0
        let reporter = AppFailureReporter { _, _ in count += 1 }
        reporter.report(.healthKit, .sync, error: CancellationError())
        reporter.report(.healthKit, .sync, error: URLError(.cancelled))
        reporter.report(.healthKit, .authorize,
                        error: NSError(domain: HKErrorDomain, code: HKError.Code.errorUserCanceled.rawValue))
        XCTAssertEqual(count, 0)
    }

    func testDebugConfigurationStillDisablesUploadsByDefault() {
        #if DEBUG
        XCTAssertEqual(AppAnalytics.configuration.analyticsDisabled,
                       !ProcessInfo.processInfo.arguments.contains("-BPMEnableAnalytics"))
        XCTAssertTrue(AppAnalytics.configuration.testMode)
        #endif
    }

    func testViewerFailurePreservesSourceAndBoundedReasonWithoutDuplicatePollEvents() {
        var failures: [[String: String]] = []
        let session = StreamViewingAnalytics(restored: true) { event, payload in
            if event == .streamViewerFailed { failures.append(payload) }
        }
        session.failed(reason: .sessionNotFound)
        session.failed(reason: .network)
        XCTAssertEqual(failures, [["stage": "connecting", "source": "restored", "reason": "session_not_found"]])
    }

    @MainActor
    func testHealthKitSyncFailureIsCategorizedAndDeduplicatedUntilSuccess() async throws {
        var failures: [[String: String]] = []
        let reporter = AppFailureReporter { _, payload in failures.append(payload) }
        let health = ReliabilityHealthStore()
        let service = HealthKitWorkoutSyncService(healthStore: health, failureReporter: reporter)
        health.saveError = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        for _ in 0..<2 { _ = try? await service.syncWorkout(record: workout(), activityType: .other) }
        XCTAssertEqual(failures, [["component": "healthkit", "operation": "sync", "category": "device_locked"]])
        health.saveError = nil
        _ = try await service.syncWorkout(record: workout(), activityType: .other)
        health.saveError = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        _ = try? await service.syncWorkout(record: workout(), activityType: .other)
        XCTAssertEqual(failures.count, 2)
    }

    @MainActor
    func testHealthAuthorizationFailureDoesNotAlsoCountAsWriteFailure() async {
        var failures: [[String: String]] = []
        let reporter = AppFailureReporter { _, payload in failures.append(payload) }
        let health = ReliabilityHealthStore()
        health.status = .sharingDenied
        let service = HealthKitWorkoutSyncService(healthStore: health, failureReporter: reporter)
        for _ in 0..<2 { _ = try? await service.syncWorkout(record: workout(), activityType: .other) }
        XCTAssertEqual(failures, [["component": "healthkit", "operation": "authorize", "category": "permission_denied"]])
    }

    @MainActor
    func testActualWorkoutDiskFailuresReportOnceAndSuccessfulRetryResetsEpisode() async throws {
        let events = LockedFailureEvents()
        let reporter = AppFailureReporter { _, payload in events.append(payload) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reliability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: path) }
        let defaults = UserDefaults(suiteName: "Reliability-\(UUID())")!
        let store = WorkoutStore(storeURL: path.appendingPathComponent("workouts.json"), userDefaults: defaults,
                                 iCloudStore: InMemoryICloudKeyValueStore(), failureReporter: reporter)
        _ = try await save(workout(), in: store)
        try FileManager.default.removeItem(at: path)
        try Data("Not a directory".utf8).write(to: path)
        for _ in 0..<2 {
            do { _ = try await save(workout(), in: store); XCTFail("Expected disk write failure") }
            catch { XCTAssertEqual(error as? WorkoutStore.DetailEditError, .saveFailed) }
        }
        XCTAssertEqual(events.values.filter { $0["operation"] == "save" }.count, 1)
        try FileManager.default.removeItem(at: path)
        _ = try await save(workout(), in: store)
        try FileManager.default.removeItem(at: path)
        try Data("Not a directory".utf8).write(to: path)
        _ = try? await save(workout(), in: store)
        XCTAssertEqual(events.values.filter { $0["operation"] == "save" }.count, 2)
        XCTAssertTrue(events.values.allSatisfy { $0["component"] == "workout_store" && $0.keys.count == 3 })
    }

    @MainActor
    func testActualHRVDiskFailureIsReportedWithoutMeasurementData() async throws {
        let events = LockedFailureEvents()
        let reporter = AppFailureReporter { _, payload in events.append(payload) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hrv-reliability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("Not a directory".utf8).write(to: path)
        let store = HRVStore(storeURL: path.appendingPathComponent("hrv.json"),
                             userDefaults: UserDefaults(suiteName: "Reliability-\(UUID())")!, failureReporter: reporter)
        let now = Date()
        let record = HRVRecord(id: UUID(), schemaVersion: 1, startAt: now, endAt: now, durationSeconds: 60,
                               hrvValue: 42, avgHr: 60, minHr: 50, maxHr: 70, hrSamples: [], rrIntervalsMs: [],
                               source: "Private monitor", appVersion: "2.2", createdAt: now, updatedAt: now)
        for _ in 0..<2 {
            let success = await withCheckedContinuation { continuation in
                store.saveRecord(record) { continuation.resume(returning: $0) }
            }
            XCTAssertFalse(success)
        }
        XCTAssertEqual(events.values.filter { $0["operation"] == "save" }.count, 1)
        XCTAssertTrue(events.values.allSatisfy { $0["component"] == "hrv_store" && $0.keys.count == 3 })
    }

    @MainActor
    func testAutofillEmptyOrPrivateFieldsAreNotFailuresButRequestErrorsAre() async throws {
        var failures: [[String: String]] = []
        let reader = ReliabilityHealthReader()
        let reporter = AppFailureReporter { _, payload in failures.append(payload) }
        let service = CalorieHealthAutofillService(healthStore: reader, failureReporter: reporter)
        let snapshot = try await service.fetch()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        reader.authorizationError = NSError(domain: HKErrorDomain, code: HKError.Code.errorHealthDataRestricted.rawValue)
        for _ in 0..<2 { _ = try? await service.fetch() }
        XCTAssertEqual(failures, [["component": "health_autofill", "operation": "authorize", "category": "permission_denied"]])
    }

    @MainActor
    func testCancellingHealthAutofillAuthorizationDoesNotCountAsAnAppFailure() async {
        var failures: [[String: String]] = []
        let reader = ReliabilityHealthReader()
        reader.authorizationError = NSError(domain: HKErrorDomain, code: HKError.Code.errorUserCanceled.rawValue)
        let reporter = AppFailureReporter { _, payload in failures.append(payload) }
        let service = CalorieHealthAutofillService(healthStore: reader, failureReporter: reporter)

        do {
            _ = try await service.fetch()
            XCTFail("Expected authorization cancellation to propagate")
        } catch {
            XCTAssertTrue(AppFailureCategory.isCancellation(error))
        }
        XCTAssertTrue(failures.isEmpty)
    }

    @MainActor
    private func save(_ record: WorkoutRecord, in store: WorkoutStore) async throws -> WorkoutRecord {
        try await withCheckedThrowingContinuation { continuation in
            store.saveWorkout(record) { continuation.resume(with: $0) }
        }
    }

    private func workout() -> WorkoutRecord {
        let now = Date()
        return WorkoutRecord(id: UUID(), schemaVersion: WorkoutRecord.schemaVersion, title: "Private session",
                             startAt: now.addingTimeInterval(-60), endAt: now, durationSeconds: 60,
                             avgHr: 140, maxHr: 180, minHr: 60, hrv: nil, hrr: nil,
                             caloriesTotal: nil, caloriesActive: nil, hrSamples: [], zones: [], sets: [],
                             notes: "Private notes", source: "phone", appVersion: "2.2",
                             healthKitWorkoutUUID: nil, healthKitSyncedAt: nil, healthKitLastError: nil,
                             createdAt: now, updatedAt: now)
    }
}

private final class ReliabilityHealthStore: HealthStoreWriting {
    var isHealthDataAvailable = true
    var status: HKAuthorizationStatus = .sharingAuthorized
    var saveError: Error?
    func authorizationStatus(for objectType: HKObjectType) -> HKAuthorizationStatus { status }
    func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>?) async throws {}
    func saveWorkout(activityType: HKWorkoutActivityType, start: Date, end: Date, metadata: [String: Any],
                     samples: [HKSample], events: [HKWorkoutEvent]) async throws -> UUID {
        if let saveError { throw saveError }
        return UUID()
    }
}

private final class LockedFailureEvents {
    private let lock = NSLock()
    private var payloads: [[String: String]] = []
    func append(_ payload: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        payloads.append(payload)
    }
    var values: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return payloads
    }
}

private final class ReliabilityHealthReader: CalorieHealthDataReading {
    var isHealthDataAvailable = true
    var authorizationError: Error?
    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        if let authorizationError { throw authorizationError }
    }
    func dateOfBirthComponents() throws -> DateComponents {
        throw NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
    }
    func biologicalSex() throws -> HKBiologicalSex {
        throw NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
    }
    func latestQuantity(for identifier: HKQuantityTypeIdentifier, before date: Date) async throws -> HKQuantitySample? { nil }
}
