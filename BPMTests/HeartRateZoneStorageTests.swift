import Foundation
import XCTest
import Combine
@testable import BPM

final class HeartRateZoneStorageTests: XCTestCase {
    @MainActor
    func testSynchronousDefaultsNotificationDoesNotReenterSave() {
        let notifications = NotificationCenter()
        let defaults = SynchronousZoneDefaults(notifications: notifications)
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: notifications)
        let config = HeartRateZoneConfig(maxHeartRate: 190)
        storage.config = config
        XCTAssertEqual(defaults.writeCount, 1)
        XCTAssertEqual(storage.config, config)

        storage.config = config
        for _ in 0..<100 { notifications.post(name: UserDefaults.didChangeNotification, object: defaults) }
        XCTAssertEqual(defaults.writeCount, 1)

        storage.config = nil
        XCTAssertEqual(defaults.writeCount, 2)
        XCTAssertNil(defaults.data(forKey: HeartRateZoneDefaultsKey.config))
        XCTAssertNil(storage.config)
    }

    @MainActor
    func testExternalConfigChangesLoadWithoutWritingBackAndEquivalentJSONDoesNotRepublish() throws {
        let notifications = NotificationCenter()
        let defaults = SynchronousZoneDefaults(notifications: notifications)
        let original = HeartRateZoneConfig(maxHeartRate: 180)
        defaults.set(try JSONEncoder().encode(original), forKey: HeartRateZoneDefaultsKey.config)
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: notifications)
        XCTAssertEqual(defaults.writeCount, 1)
        XCTAssertEqual(storage.config, original)

        var publications = 0
        let subscription = storage.$config.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let replacement = HeartRateZoneConfig(maxHeartRate: 200)
        defaults.set(try JSONEncoder().encode(replacement), forKey: HeartRateZoneDefaultsKey.config)
        XCTAssertEqual(defaults.writeCount, 2)
        XCTAssertEqual(storage.config, replacement)
        XCTAssertEqual(publications, 1)

        let differentlyOrderedEncoder = JSONEncoder()
        differentlyOrderedEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        defaults.set(try differentlyOrderedEncoder.encode(replacement), forKey: HeartRateZoneDefaultsKey.config)
        XCTAssertEqual(defaults.writeCount, 3)
        XCTAssertEqual(publications, 1)
        defaults.removeObject(forKey: HeartRateZoneDefaultsKey.config)
        XCTAssertEqual(defaults.writeCount, 4)
        XCTAssertNil(storage.config)
        XCTAssertEqual(publications, 2)
    }

    @MainActor
    func testMalformedExternalDataFallsBackWithoutRecursiveRewrite() {
        let notifications = NotificationCenter()
        let defaults = SynchronousZoneDefaults(notifications: notifications)
        let storage = HeartRateZoneStorage(userDefaults: defaults, notificationCenter: notifications)
        storage.config = HeartRateZoneConfig(maxHeartRate: 190)
        defaults.set(Data("invalid".utf8), forKey: HeartRateZoneDefaultsKey.config)
        XCTAssertEqual(defaults.writeCount, 2)
        XCTAssertNil(storage.config)
        XCTAssertEqual(storage.effectiveConfig.maxHeartRate, 190)
    }
}

private final class SynchronousZoneDefaults: UserDefaults {
    private let notifications: NotificationCenter
    private var values: [String: Any] = [:]
    private(set) var writeCount = 0

    init(notifications: NotificationCenter) {
        self.notifications = notifications
        super.init(suiteName: "zone-reentrancy-\(UUID())")!
    }

    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) {
        writeCount += 1
        guard writeCount <= 20 else {
            XCTFail("Defaults observer entered a recursive write loop")
            return
        }
        values[defaultName] = value
        notifications.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removeObject(forKey defaultName: String) {
        writeCount += 1
        guard writeCount <= 20 else {
            XCTFail("Defaults observer entered a recursive removal loop")
            return
        }
        values.removeValue(forKey: defaultName)
        notifications.post(name: UserDefaults.didChangeNotification, object: self)
    }
}
