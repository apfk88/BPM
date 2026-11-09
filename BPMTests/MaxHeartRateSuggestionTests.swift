import Foundation
import XCTest
@testable import BPM

@MainActor
final class MaxHeartRateSuggestionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var zones: HeartRateZoneStorage!
    private var store: MaxHeartRateSuggestionStore!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        suite = "MaxHeartRateSuggestionTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("195", forKey: CaloriesDefaultsKey.maxHrBpm)
        zones = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        store = MaxHeartRateSuggestionStore(defaults: defaults, zoneStorage: zones)
    }

    override func tearDown() async throws {
        store = nil
        zones = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testSustainedNewMaximumPersistsWithoutChangingSettings() {
        record(198, at: 0)
        record(198, at: 2)
        XCTAssertNil(store.pendingMaxHeartRate)
        record(198, at: 4)
        XCTAssertEqual(store.pendingMaxHeartRate, 198)
        XCTAssertEqual(defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm), "195")
        XCTAssertNil(zones.config)

        let reloaded = MaxHeartRateSuggestionStore(defaults: defaults, zoneStorage: zones)
        XCTAssertEqual(reloaded.pendingMaxHeartRate, 198)
    }

    func testSingleSpikeAndSparseReadingsDoNotQualify() {
        record(190, at: 0)
        record(220, at: 2)
        record(190, at: 4)
        record(198, at: 6)
        record(198, at: 10)
        record(198, at: 14)
        XCTAssertNil(store.pendingMaxHeartRate)
    }

    func testReportsSustainedValueInsteadOfHighestSpike() {
        record(198, at: 0)
        record(225, at: 2)
        record(198, at: 4)
        XCTAssertEqual(store.pendingMaxHeartRate, 198)
    }

    func testSimulationPausedWorkoutBadContactAndInvalidValuesDoNotQualify() {
        for time in [0.0, 2.0, 4.0] {
            record(198, at: time, isSimulated: true)
        }
        XCTAssertNil(store.pendingMaxHeartRate)
        for time in [6.0, 8.0, 10.0] {
            record(198, at: time, isActive: false)
        }
        XCTAssertNil(store.pendingMaxHeartRate)
        record(198, at: 12)
        record(198, at: 14, contact: .notDetected)
        record(198, at: 16)
        XCTAssertNil(store.pendingMaxHeartRate)
        record(251, at: 18)
        record(198, at: 20)
        XCTAssertNil(store.pendingMaxHeartRate)
    }

    func testInvalidatedSamplesAndDuplicateTimestampsCannotConfirm() {
        let invalid = HeartRateSample(value: 198, timestamp: start, workoutTime: nil, invalidatedAt: start)
        store.record(invalid, isLocalWorkoutActive: true, isSimulated: false)
        record(198, at: 2)
        record(198, at: 4)
        XCTAssertNil(store.pendingMaxHeartRate)
        for _ in 0..<10 { record(198, at: 4) }
        XCTAssertNil(store.pendingMaxHeartRate)
    }

    func testAcceptUpdatesMaximaAndPreservesEveryCustomZoneBoundary() {
        var custom = HeartRateZoneConfig(maxHeartRate: 195)
        custom.zone1Min = 85
        custom.zone1Max = 112
        custom.zone2Min = 112
        custom.zone2Max = 135
        zones.config = custom
        record(198, at: 0)
        record(198, at: 2)
        record(198, at: 4)
        store.accept()

        var expected = custom
        expected.maxHeartRate = 198
        XCTAssertEqual(zones.config, expected)
        XCTAssertEqual(defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm), "198")
        XCTAssertTrue(defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.maxHrBpm)))
        XCTAssertTrue(defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: HeartRateZoneDefaultsKey.config)))
        XCTAssertNil(store.pendingMaxHeartRate)
        XCTAssertNil(defaults.object(forKey: MaxHeartRateSuggestionStore.DefaultsKey.pending))
    }

    func testDismissSurvivesRelaunchAndOnlyHigherValuePromptsAgain() {
        record(198, at: 0)
        record(198, at: 2)
        record(198, at: 4)
        store.dismiss()
        store = MaxHeartRateSuggestionStore(defaults: defaults, zoneStorage: zones)
        for time in [6.0, 8.0, 10.0] { record(198, at: time) }
        XCTAssertNil(store.pendingMaxHeartRate)
        for time in [12.0, 14.0, 16.0] { record(200, at: time) }
        XCTAssertEqual(store.pendingMaxHeartRate, 200)
        XCTAssertEqual(defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm), "195")
    }

    func testManualHigherValueClearsStaleSuggestionAndCannotBeLowered() {
        record(198, at: 0)
        record(198, at: 2)
        record(198, at: 4)
        defaults.set("205", forKey: CaloriesDefaultsKey.maxHrBpm)
        store.accept()
        XCTAssertNil(store.pendingMaxHeartRate)
        XCTAssertEqual(defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm), "205")
        XCTAssertNil(zones.config)
    }

    func testUsesHighestEnteredMaximumAndDoesNotPromptBeforeSetup() {
        zones.config = HeartRateZoneConfig(maxHeartRate: 200)
        for time in [0.0, 2.0, 4.0] { record(198, at: time) }
        XCTAssertNil(store.pendingMaxHeartRate)
        zones.config = nil
        defaults.removeObject(forKey: CaloriesDefaultsKey.maxHrBpm)
        for time in [6.0, 8.0, 10.0] { record(198, at: time) }
        XCTAssertNil(store.pendingMaxHeartRate)
    }

    func testConfirmationResetsAcrossWorkouts() {
        record(198, at: 0)
        record(198, at: 2)
        store.resetConfirmation()
        record(198, at: 4)
        XCTAssertNil(store.pendingMaxHeartRate)
    }

    func testAcceptPreservesExistingDeviceOnlyPreferenceMarkers() {
        let originalKey = HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.weightKg)
        defaults.set(true, forKey: originalKey)
        for time in [0.0, 2.0, 4.0] { record(198, at: time) }
        store.accept()
        XCTAssertTrue(defaults.bool(forKey: originalKey))
        XCTAssertTrue(defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.maxHrBpm)))
        XCTAssertTrue(defaults.bool(forKey: HealthKitImportedPreferences.localOnlyKey(for: HeartRateZoneDefaultsKey.config)))
    }

    private func record(
        _ bpm: Int,
        at time: TimeInterval,
        isActive: Bool = true,
        isSimulated: Bool = false,
        contact: HeartRateSensorContactStatus = .detected
    ) {
        store.record(
            HeartRateSample(value: bpm, timestamp: start.addingTimeInterval(time), workoutTime: time, sensorContactStatus: contact),
            isLocalWorkoutActive: isActive,
            isSimulated: isSimulated
        )
    }
}
