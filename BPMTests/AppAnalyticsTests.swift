import XCTest
@testable import BPM

final class AppAnalyticsTests: XCTestCase {
    func testTelemetryDeckConfigurationValues() {
        let configuration = AppAnalytics.configuration

        XCTAssertEqual(configuration.telemetryAppID, "458D3F06-26F3-4929-ADFA-C1B7DF052D28")
        XCTAssertEqual(configuration.namespace, "com.siav")
    }

    func testLegacyEventNamesRemainAvailableAndAllNamesAreUnique() {
        let names = AppAnalytics.Event.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        let legacy: Set<String> = [
            "connect_device", "connect_friends_code", "share_on", "share_off",
            "workout_start", "workout_save", "hrv_start", "share_picker_opened",
            "share_format_selected", "share_export_requested", "share_export_presented",
            "share_export_completed", "share_export_cancelled", "share_export_failed"
        ]
        XCTAssertTrue(legacy.isSubset(of: Set(names)))
    }

    func testCompletedExportDoesNotAlsoCountDismissalAsCancellation() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .workoutDetail, format: .chartCard)) { event, parameters in
            events.append(event)
            XCTAssertEqual(parameters, ["source": "workout_detail", "format": "chart_card"])
        }
        session.presented()
        session.presented()
        session.finish(completed: true)
        session.finish(completed: false)
        XCTAssertEqual(events, [.shareExportRequested, .shareExportPresented, .shareExportCompleted])
    }

    func testCancellationAndFailureAreSeparateTerminalOutcomes() {
        for failed in [false, true] {
            var events: [AppAnalytics.Event] = []
            let session = ShareAnalyticsSession(context: .init(source: .postSave, format: .plainText)) { event, _ in
                events.append(event)
            }
            session.presented()
            session.finish(completed: false, failed: failed)
            session.finish(completed: false)
            XCTAssertEqual(events, [.shareExportRequested, .shareExportPresented,
                                    failed ? .shareExportFailed : .shareExportCancelled])
        }
    }

    func testPreparationFailureDoesNotCountAsPresentedOrCancelled() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .hrvHistory, format: .logs)) { event, _ in
            events.append(event)
        }
        session.finish(completed: false, failed: true)
        session.presented()
        session.finish(completed: false)
        XCTAssertEqual(events, [.shareExportRequested, .shareExportFailed])
    }

    func testNativeErrorTakesPrecedenceOverCompletedFlag() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .hrvDetail, format: .logs)) { event, _ in
            events.append(event)
        }
        session.finish(completed: true, failed: true)
        XCTAssertEqual(events.last, .shareExportFailed)
    }

    func testEveryContextContainsOnlyFixedSourceAndFormatLabels() {
        for source in ShareAnalyticsContext.Source.allCases {
            for format in ShareAnalyticsContext.Format.allCases {
                XCTAssertEqual(ShareAnalyticsContext(source: source, format: format).parameters,
                               ["source": source.rawValue, "format": format.rawValue])
            }
        }
    }

    func testCalorieSnapshotContainsOnlyFieldStatesAndNeverValues() {
        let suite = "BPMAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = CalorieAnalytics.configuration(defaults: defaults)
        XCTAssertEqual(empty["sex_state"], "empty")
        XCTAssertEqual(empty["calories_enabled"], "false")
        for field in CalorieAnalytics.Field.allCases where field != .sex {
            XCTAssertEqual(empty["\(field.rawValue)_state"], "empty")
            defaults.set("42", forKey: field.defaultsKey)
        }
        defaults.set("190", forKey: CaloriesDefaultsKey.maxHrBpm)
        defaults.set("1440", forKey: CaloriesDefaultsKey.rmrKcalPerDay)
        defaults.set("female", forKey: CaloriesDefaultsKey.sexAtBirth)
        let first = CalorieAnalytics.configuration(defaults: defaults)
        XCTAssertEqual(first["calories_enabled"], "true")
        XCTAssertEqual(first["sex_state"], "filled")
        for field in CalorieAnalytics.Field.allCases where field != .sex {
            defaults.set("79", forKey: field.defaultsKey)
        }
        defaults.set("195", forKey: CaloriesDefaultsKey.maxHrBpm)
        defaults.set("1790", forKey: CaloriesDefaultsKey.rmrKcalPerDay)
        defaults.set("male", forKey: CaloriesDefaultsKey.sexAtBirth)
        XCTAssertEqual(first, CalorieAnalytics.configuration(defaults: defaults),
                       "Changing every health value and sex must not change the telemetry payload")
        XCTAssertTrue(Set(first.values).isSubset(of: ["filled", "empty", "invalid", "defaulted", "true", "false"]))
        XCTAssertEqual(first.count, 10)
    }

    func testCalorieEnabledTelemetryMatchesEstimatorValidation() {
        let suite = "BPMAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("80", forKey: CaloriesDefaultsKey.weightKg)
        defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)
        defaults.set("180", forKey: CaloriesDefaultsKey.heightCm)
        defaults.set("male", forKey: CaloriesDefaultsKey.sexAtBirth)
        XCTAssertEqual(CalorieAnalytics.configuration(defaults: defaults)["calories_enabled"], "true")
        defaults.set("inf", forKey: CaloriesDefaultsKey.vo2Max)
        XCTAssertEqual(CalorieAnalytics.configuration(defaults: defaults)["calories_enabled"], "false")
        defaults.removeObject(forKey: CaloriesDefaultsKey.vo2Max)
        defaults.set(true, forKey: CaloriesDefaultsKey.medsAffectingHr)
        let parameters = CalorieAnalytics.configuration(defaults: defaults)
        XCTAssertEqual(parameters["calories_enabled"], "false")
        XCTAssertEqual(parameters.count, 10)
        XCTAssertFalse(parameters.keys.contains { $0.lowercased().contains("med") })
    }

    func testInvalidAndClearedCalorieFieldsDoNotCountAsFilled() {
        let suite = "BPMAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in ["0", "-1", "nan", "inf", ".", "arbitrary private text"] {
            defaults.set(value, forKey: CaloriesDefaultsKey.weightKg)
            XCTAssertEqual(CalorieAnalytics.state(for: .weight, defaults: defaults), .invalid)
        }
        defaults.set("25.5", forKey: CaloriesDefaultsKey.ageYears)
        XCTAssertEqual(CalorieAnalytics.state(for: .age, defaults: defaults), .invalid)
        defaults.set("", forKey: CaloriesDefaultsKey.weightKg)
        XCTAssertEqual(CalorieAnalytics.state(for: .weight, defaults: defaults), .empty)
    }

    func testSoundUseIsBoundedEvenWithConcurrentSensorCallbacks() {
        let usage = AnalyticsOncePerSession<AppAnalytics.Sound>()
        let lock = NSLock()
        var counts: [AppAnalytics.Sound: Int] = [:]
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            for sound in [AppAnalytics.Sound.bpmAlert, .zoneAlert] where usage.insert(sound) {
                lock.lock()
                counts[sound, default: 0] += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(counts, [.bpmAlert: 1, .zoneAlert: 1])
        XCTAssertTrue(AnalyticsOncePerSession<AppAnalytics.Sound>().insert(.bpmAlert))
    }

    func testDailySoundAdoptionRenewsWithoutRelaunchingTheApp() {
        let usage = AnalyticsOncePerSession<AppAnalytics.Sound>(resetsDaily: true)
        let beforeMidnight = Date(timeIntervalSince1970: 86_399)
        let afterMidnight = Date(timeIntervalSince1970: 86_400)
        XCTAssertTrue(usage.insert(.zoneAlert, now: beforeMidnight))
        XCTAssertFalse(usage.insert(.zoneAlert, now: beforeMidnight))
        XCTAssertTrue(usage.insert(.zoneAlert, now: afterMidnight))
        XCTAssertFalse(usage.insert(.zoneAlert, now: afterMidnight))
        let stream = AnalyticsOncePerSession<String>()
        XCTAssertTrue(stream.insert("connected", now: beforeMidnight))
        XCTAssertFalse(stream.insert("connected", now: afterMidnight))
    }

    func testViewerFailureCanRecoverWithoutCountingEveryPollOrLateReply() {
        var events: [AppAnalytics.Event] = []
        var parameters: [[String: String]] = []
        let session = StreamViewingAnalytics(restored: false) { event, payload in
            events.append(event); parameters.append(payload)
        }
        session.failed()
        session.failed()
        session.receivedData()
        session.receivedData()
        session.stop()
        session.receivedData()
        session.failed()
        session.stop()
        XCTAssertEqual(events, [.streamViewerStarted, .streamViewerFailed, .streamViewerConnected, .streamViewerStopped])
        XCTAssertEqual(parameters, [["source": "user"], ["stage": "connecting"], [:], ["connected": "true"]])
    }

    func testRestoredViewerDoesNotPretendToBeUserIntentOrConnected() {
        var events: [AppAnalytics.Event] = []
        var parameters: [[String: String]] = []
        let session = StreamViewingAnalytics(restored: true) { event, payload in
            events.append(event); parameters.append(payload)
        }
        session.stop()
        session.receivedData()
        XCTAssertEqual(events, [.streamViewerStarted, .streamViewerStopped])
        XCTAssertEqual(parameters, [["source": "restored"], ["connected": "false"]])
    }

    @MainActor func testHRVStartFailureAndCancellationHaveDistinctOutcomes() {
        var events: [AppAnalytics.Event] = []
        var payloads: [[String: String]] = []
        var ticks: TimeInterval = 0
        let model = HRVMeasurementViewModel(ticksProvider: { ticks }, playCompletionSound: {}, emitAnalytics: { event, payload in
            events.append(event); payloads.append(payload)
        })
        model.startMeasurement()
        XCTAssertEqual(events, [.hrvFailed])
        XCTAssertEqual(payloads.last, ["reason": "sensor_unavailable", "stage": "start"])
        let stream = UUID()
        model.currentHeartRate = { 65 }
        model.supportsRRIntervals = { true }
        model.currentRRStreamID = { stream }
        model.getRRIntervals = { [] }
        model.startMeasurement()
        model.startMeasurement() // Repeated tap while running must not count twice.
        model.reset()
        model.reset()
        XCTAssertEqual(events, [.hrvFailed, .hrvStart, .hrvCancelled])
        model.startMeasurement()
        ticks = 6
        model.updateMeasurement()
        model.updateMeasurement()
        model.reset()
        XCTAssertEqual(events.suffix(2), [.hrvStart, .hrvFailed])
        XCTAssertEqual(payloads.last, ["reason": "data_stopped", "stage": "measurement"])
        model.stopLiveHeartRateUpdates()
    }

    @MainActor func testHRVCompletionIsCountedOnceWithoutMeasurementsInPayload() {
        var events: [AppAnalytics.Event] = []
        var ticks: TimeInterval = 0
        var history: [RRInterval] = []
        let stream = UUID()
        let model = HRVMeasurementViewModel(ticksProvider: { ticks }, playCompletionSound: {}, emitAnalytics: { event, payload in
            events.append(event)
            XCTAssertTrue(payload.isEmpty)
        })
        model.currentHeartRate = { 60 }
        model.supportsRRIntervals = { true }
        model.currentRRStreamID = { stream }
        model.getRRIntervals = { history }
        model.startMeasurement()
        for second in 1...120 {
            ticks = Double(second)
            history = [RRInterval(value: second.isMultiple(of: 2) ? 1010 : 990, timestamp: Date(), receivedTicks: ticks)]
            model.updateMeasurement()
        }
        model.updateMeasurement()
        model.reset()
        XCTAssertEqual(events, [.hrvStart, .hrvCompleted])
        model.stopLiveHeartRateUpdates()
    }
}
