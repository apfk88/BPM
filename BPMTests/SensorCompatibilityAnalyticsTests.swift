import XCTest
@testable import BPM

final class SensorCompatibilityAnalyticsTests: XCTestCase {
    func testGenericHRMNamesDoNotImplyGarmin() {
        for name in ["HRM chest strap", "HRM Bluetooth", "HRM monitor", "HRM Proximity", "HRM", "Rhythm monitor", "My heart rhythm sensor"] {
            XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: name), .unknown, name)
        }
    }

    func testCommonAdvertisementsNormalizeToFixedModelsWithoutSensorIDs() {
        let cases: [(String, SensorAnalyticsIdentity.Vendor, SensorAnalyticsIdentity.Model)] = [
            ("Polar H10 A1B2C3D4", .polar, .polarH10),
            ("Polar H9 12345678", .polar, .polarH9),
            ("Polar H7 12345678", .polar, .polarH7),
            ("Polar Verity Sense 98765432", .polar, .polarVeritySense),
            ("Polar OH1 12345678", .polar, .polarOH1),
            ("HRM-Pro Plus:12345", .garmin, .garminHRMProPlus),
            ("Garmin HRM-Pro", .garmin, .garminHRMPro),
            ("HRM-Dual 987", .garmin, .garminHRMDual),
            ("HRM-Fit 987", .garmin, .garminHRMFit),
            ("HRM600 12345", .garmin, .garminHRM600),
            ("HRM 200 12345", .garmin, .garminHRM200),
            ("TICKR X 12345", .wahoo, .wahooTickrX),
            ("TICKR FIT 12345", .wahoo, .wahooTickrFit),
            ("Wahoo TICKR 12345", .wahoo, .wahooTickr),
            ("TRACKR HR 12345", .wahoo, .wahooTrackrHR),
            ("COOSPO H6 12345", .coospo, .coospoH6),
            ("COOSPO H9Z 12345", .coospo, .coospoH9Z),
            ("COOSPO H808S 12345", .coospo, .coospoH808S),
            ("COOSPO HW9 12345", .coospo, .coospoHW9),
            ("COOSPO HW807 12345", .coospo, .coospoHW807),
            ("COOSPO HW706 12345", .coospo, .coospoHW706),
            ("Scosche RHYTHM+ 12345", .scosche, .scoscheRhythmPlus),
            ("RHYTHM24 12345", .scosche, .scoscheRhythm24),
            ("Suunto Smart Sensor 12345", .suunto, .suuntoSmartSensor),
            ("Magene H303 12345", .magene, .mageneH303),
            ("Magene H64 12345", .magene, .mageneH64),
            ("Magene H603 12345", .magene, .mageneH603),
            ("Moofit HR6 12345", .moofit, .moofitHR6),
            ("COROS Heart Rate Monitor 12345", .coros, .corosHRM)
        ]
        XCTAssertEqual(Set(cases.map { $0.2 }), Set(SensorAnalyticsIdentity.Model.allCases.filter { $0 != .unknown }))
        for (name, vendor, model) in cases {
            let identity = SensorAnalyticsIdentity.classify(advertisedName: name)
            XCTAssertEqual(identity, SensorAnalyticsIdentity(vendor: vendor, model: model), name)
            XCTAssertEqual(identity.parameters.count, 3)
            XCTAssertFalse(identity.parameters.values.contains(name))
        }
    }

    func testDeviceInformationRecognizesRenamedSensorRegardlessOfReadOrder() {
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Alex's chest strap",
                                                      manufacturerName: "Polar Electro Oy", modelNumber: "H10"),
                       .init(vendor: .polar, model: .polarH10, source: .deviceInformation))
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Alex's chest strap",
                                                      modelNumber: "H10"), .unknown)
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Alex's chest strap",
                                                      manufacturerName: "Polar Electro Oy"),
                       .init(vendor: .polar, source: .deviceInformation))
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Alex's chest strap", modelNumber: "Movesense"),
                       .init(vendor: .movesense, source: .deviceInformation))
    }

    func testManufacturerPrecedenceDoesNotMisclassifyConflictingAdvertisement() {
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Polar H10 12345",
                                                      manufacturerName: "Garmin", modelNumber: "HRM-Pro"),
                       .init(vendor: .garmin, model: .garminHRMPro, source: .deviceInformation))
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Polar H10 12345",
                                                      manufacturerName: "Garmin", modelNumber: "private-device-12345"),
                       .init(vendor: .garmin, source: .deviceInformation))
    }

    func testUnknownAndPersonalNamesNeverBecomeTelemetryValues() {
        for name in ["Alex's monitor", "alice@example.com", "B52CC943-CF47-407C-8111-D2AFE20C85E5", "H10", "Polar H100", "Garminish HRM-Pro"] {
            let identity = SensorAnalyticsIdentity.classify(advertisedName: name,
                                                          manufacturerName: "Private Name", modelNumber: "SECRET123")
            XCTAssertTrue(SensorAnalyticsIdentity.Vendor.allCases.map(\.rawValue).contains(identity.parameters["sensor_vendor"]!))
            XCTAssertTrue(SensorAnalyticsIdentity.Model.allCases.map(\.rawValue).contains(identity.parameters["sensor_model"]!))
            XCTAssertFalse(identity.parameters.values.contains { $0.contains("SECRET") || $0.contains("Alex") || $0.contains("@") })
        }
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Polar H100"), .init(vendor: .polar))
        XCTAssertEqual(SensorAnalyticsIdentity.classify(advertisedName: "Movesense SECRET123"), .init(vendor: .movesense))
    }

    func testConnectionIsReadyOnlyAfterUsableHeartRateAndDoesNotCountEveryBeat() {
        var events: [[String: String]] = []
        let tracker = SensorCompatibilityAnalytics(identity: .init(vendor: .polar, model: .polarH10)) { event, values in
            XCTAssertEqual(event, .sensorConnection)
            events.append(values)
        }
        tracker.connected()
        tracker.connected()
        tracker.receivedMeasurement(hasRRIntervals: false, contactSupported: true, hasUsableHeartRate: false)
        XCTAssertEqual(events.map { $0["outcome"]! }, ["connected"])
        for _ in 0..<100 {
            tracker.receivedMeasurement(hasRRIntervals: true, contactSupported: true, hasUsableHeartRate: true)
        }
        XCTAssertEqual(events.map { $0["outcome"]! }, ["connected", "ready"])
        XCTAssertEqual(events.last?["rr_support"], "observed")
        XCTAssertEqual(events.last?["contact_support"], "supported")
        XCTAssertNil(events.last?["heart_rate"])
    }

    func testLateRRAndBatteryCapabilitiesAreReportedOnceAndNeverDowngraded() {
        var events: [[String: String]] = []
        let tracker = SensorCompatibilityAnalytics(identity: .unknown) { _, values in events.append(values) }
        tracker.receivedMeasurement(hasRRIntervals: false, contactSupported: false, hasUsableHeartRate: true)
        tracker.receivedMeasurement(hasRRIntervals: true, contactSupported: true, hasUsableHeartRate: true)
        tracker.receivedMeasurement(hasRRIntervals: false, contactSupported: false, hasUsableHeartRate: true)
        tracker.observedBatteryLevel(255)
        XCTAssertEqual(events.count, 2)
        tracker.observedBatteryLevel(85)
        tracker.observedBatteryLevel(84)
        tracker.observedBatteryService(present: false)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?["battery_support"], "supported")
        XCTAssertEqual(events.last?["rr_support"], "observed")
        XCTAssertEqual(events.last?["contact_support"], "supported")
        XCTAssertFalse(events.flatMap(\.values).contains("85"))
    }

    func testMissingBatteryServiceIsDifferentFromAnUnreadablePresentService() {
        for present in [true, false] {
            var event: [String: String] = [:]
            let tracker = SensorCompatibilityAnalytics(identity: .unknown) { _, values in event = values }
            tracker.observedBatteryService(present: present)
            tracker.receivedMeasurement(hasRRIntervals: false, contactSupported: false, hasUsableHeartRate: true)
            XCTAssertEqual(event["battery_support"], present ? "unknown" : "unavailable")
        }
    }

    func testMetadataArrivingAfterFirstReadingEmitsOnlyNormalizedEnrichment() {
        var events: [[String: String]] = []
        let tracker = SensorCompatibilityAnalytics(identity: .unknown) { _, values in events.append(values) }
        tracker.receivedMeasurement(hasRRIntervals: true, contactSupported: true, hasUsableHeartRate: true)
        let identity = SensorAnalyticsIdentity.classify(advertisedName: "Alex's H10", manufacturerName: "Polar Electro Oy", modelNumber: "H10")
        tracker.updateIdentity(identity)
        tracker.updateIdentity(identity)
        XCTAssertEqual(events.map { $0["outcome"]! }, ["ready", "capabilities"])
        XCTAssertEqual(events.last?["sensor_model"], "polar_h10")
        XCTAssertFalse(events.flatMap(\.values).contains { $0.contains("Alex") })
    }

    func testFailureAndReconnectCallbacksStayBoundedAndIncludeSensorFamily() {
        var events: [[String: String]] = []
        let tracker = SensorCompatibilityAnalytics(identity: .init(vendor: .garmin, model: .garminHRMDual)) { _, values in events.append(values) }
        tracker.connected()
        for _ in 0..<100 {
            tracker.failed(stage: .subscribe, category: .timeout)
            tracker.disconnected(userInitiated: false)
            tracker.failed(stage: .connect, category: .connectionLost)
            tracker.connected()
        }
        XCTAssertEqual(events.count, 4)
        for event in events {
            XCTAssertEqual(event["sensor_vendor"], "garmin")
            XCTAssertEqual(event["sensor_model"], "garmin_hrm_dual")
            XCTAssertEqual(Set(event.keys).subtracting(["outcome", "reason", "stage", "sensor_vendor", "sensor_model", "sensor_identity_source", "rr_support", "contact_support", "battery_support"]), [])
        }
        XCTAssertEqual(events.filter { $0["outcome"] == "failed" }.count, 2)
    }
}
