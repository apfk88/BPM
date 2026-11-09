import Foundation
import XCTest
@testable import BPM

final class HeartRateZoneDraftTests: XCTestCase {
    func testLoadingCustomRangesDoesNotRecalculate() {
        let custom = customConfiguration()
        let draft = HeartRateZoneDraft(config: custom)

        XCTAssertEqual(draft.configuration, custom)
        XCTAssertNil(draft.validationError)
        XCTAssertNotEqual(draft.configuration, HeartRateZoneConfig(maxHeartRate: custom.maxHeartRate))
    }

    @MainActor
    func testTypingMaxHeartRatePreservesCustomRangesAndOnlySavePersists() throws {
        let suite = "HeartRateZoneDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        let custom = customConfiguration()
        storage.config = custom
        let savedData = defaults.data(forKey: HeartRateZoneDefaultsKey.config)
        var draft = HeartRateZoneDraft(config: storage.effectiveConfig)
        let ranges = draft.ranges

        // Simulate deleting the old number and typing the replacement one digit at a time.
        for text in ["", "2", "20", "200"] {
            draft.maxHeartRate = text
            XCTAssertEqual(draft.ranges, ranges)
            XCTAssertEqual(storage.config, custom)
            XCTAssertEqual(defaults.data(forKey: HeartRateZoneDefaultsKey.config), savedData)
        }

        var expected = custom
        expected.maxHeartRate = 200
        XCTAssertTrue(draft.save(to: storage))
        XCTAssertEqual(storage.config, expected)
        let reloaded = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        XCTAssertEqual(reloaded.config, expected)
    }

    @MainActor
    func testRecalculationChangesDraftOnlyUntilSaved() throws {
        let suite = "HeartRateZoneDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        let custom = customConfiguration()
        storage.config = custom
        var draft = HeartRateZoneDraft(config: storage.effectiveConfig)
        draft.maxHeartRate = "200"
        draft.recalculateZones()

        XCTAssertEqual(draft.configuration, HeartRateZoneConfig(maxHeartRate: 200))
        XCTAssertEqual(storage.config, custom)
        // Discarding this draft, including a confirmed recalculation, leaves storage intact.
        XCTAssertEqual(HeartRateZoneDraft(config: storage.effectiveConfig).configuration, custom)
        XCTAssertTrue(draft.save(to: storage))
        XCTAssertEqual(storage.config, HeartRateZoneConfig(maxHeartRate: 200))
    }

    @MainActor
    func testResetIsReversibleUntilSaveAndRemovesCustomConfigurationOnSave() throws {
        let suite = "HeartRateZoneDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        let custom = customConfiguration()
        storage.config = custom
        var draft = HeartRateZoneDraft(config: storage.effectiveConfig)
        draft.resetToDefaults()

        XCTAssertTrue(draft.resetsStoredConfiguration)
        XCTAssertEqual(draft.configuration, HeartRateZoneConfig(maxHeartRate: 190))
        XCTAssertEqual(storage.config, custom)
        XCTAssertTrue(draft.save(to: storage))
        XCTAssertNil(storage.config)
        XCTAssertNil(defaults.object(forKey: HeartRateZoneDefaultsKey.config))
    }

    func testEditingAfterResetSavesTheEditedConfiguration() {
        var draft = HeartRateZoneDraft(config: customConfiguration())
        draft.resetToDefaults()
        draft.ranges[0].minimum = "90"
        XCTAssertFalse(draft.resetsStoredConfiguration)
        XCTAssertEqual(draft.configuration?.zone1Min, 90)
    }

    @MainActor
    func testInvalidDraftCannotReplaceSavedConfiguration() throws {
        let suite = "HeartRateZoneDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: NotificationCenter())
        let custom = customConfiguration()
        storage.config = custom
        var draft = HeartRateZoneDraft(config: custom)
        draft.ranges[1].minimum = "100"

        XCTAssertTrue(try XCTUnwrap(draft.validationError).contains("Zone 2 overlaps Zone 1"))
        XCTAssertFalse(draft.save(to: storage))
        XCTAssertEqual(storage.config, custom)
        draft.ranges[1].minimum = ""
        XCTAssertEqual(draft.validationError, "Enter both values for Zone 2.")
        draft.ranges[1].minimum = "140"
        XCTAssertEqual(draft.validationError, "Zone 2 minimum must be below its maximum.")
    }

    func testInvalidMaximumCannotRecalculateAndGapsRemainValid() {
        var draft = HeartRateZoneDraft(config: customConfiguration())
        let ranges = draft.ranges
        draft.maxHeartRate = "0"
        draft.recalculateZones()
        XCTAssertEqual(draft.ranges, ranges)
        XCTAssertNil(draft.configuration)
        XCTAssertNotNil(draft.validationError)

        draft.maxHeartRate = "180"
        draft.ranges[1].minimum = "116"
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(draft.configuration?.zone1Max, 110)
        XCTAssertEqual(draft.configuration?.zone2Min, 116)
    }

    private func customConfiguration() -> HeartRateZoneConfig {
        var config = HeartRateZoneConfig(maxHeartRate: 180)
        config.zone1Min = 85
        config.zone1Max = 110
        config.zone2Min = 110
        config.zone2Max = 135
        config.zone3Min = 135
        config.zone3Max = 155
        config.zone4Min = 155
        config.zone4Max = 170
        config.zone5Min = 170
        config.zone5Max = 185
        return config
    }
}
