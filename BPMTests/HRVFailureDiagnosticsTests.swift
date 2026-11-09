import Foundation
import XCTest
@testable import BPM

final class HRVFailureDiagnosticsTests: XCTestCase {
    func testQualityDiagnosticsIdentifyTheRejectedAcquisitionCheck() {
        let valid = (1...120).map { interval(at: Double($0)) }
        var invalidValue = valid
        invalidValue[60] = interval(at: 61, value: 0)
        var invalidTimestamp = valid
        invalidTimestamp[60] = interval(at: .nan)
        var outsideWindow = valid
        outsideWindow[0] = interval(at: 0)
        var reordered = valid
        reordered.swapAt(60, 61)
        var receiptGap = valid.filter { $0.receivedTicks <= 40 || $0.receivedTicks >= 47 }
        receiptGap.insert(contentsOf: (0..<6).map { _ in interval(at: 40) }, at: 40)
        var rollingCoverage = stride(from: 2, through: 40, by: 2).map { interval(at: Double($0)) }
        rollingCoverage += stride(from: 42, through: 80, by: 2).flatMap { second in
            (0..<3).map { _ in interval(at: Double(second)) }
        }
        rollingCoverage += (81...120).map { interval(at: Double($0)) }
        var abruptVariation = valid
        abruptVariation[60] = interval(at: 61, value: 1600)

        let cases: [(HRVCalculator.QualityIssue, [RRInterval])] = [
            (.insufficientIntervals, Array(valid.prefix(20))),
            (.invalidInterval, invalidValue),
            (.invalidTimestamp, invalidTimestamp),
            (.outsideWindow, outsideWindow),
            (.lateStart, (6...120).map { interval(at: Double($0)) }),
            (.earlyEnd, Array(valid.prefix(114))),
            (.coverageMismatch, (1...120).map { interval(at: Double($0), value: 900) }),
            (.receiptOrder, reordered),
            (.receiptGap, receiptGap),
            (.rollingCoverageMismatch, rollingCoverage),
            (.abruptVariation, abruptVariation)
        ]
        for (expected, intervals) in cases {
            XCTAssertEqual(HRVCalculator.qualityIssue(intervals: intervals, start: 0, duration: 120), expected)
            XCTAssertEqual(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: 120), expected.message)
        }
        XCTAssertEqual(HRVCalculator.qualityIssue(intervals: valid, start: .nan, duration: 120), .invalidWindow)
        XCTAssertNil(HRVCalculator.qualityIssue(intervals: valid, start: 0, duration: 120))
        XCTAssertEqual(Set(cases.map(\.0)).union([.invalidWindow]), Set(HRVCalculator.QualityIssue.allCases))
    }

    @MainActor
    func testStartFailuresIdentifyUnavailableInputWithoutCountingMeasurementOrCancellation() {
        let cases: [(String, (DiagnosticInput) -> Void)] = [
            ("rr_unavailable", { $0.supportsRR = false }),
            ("heart_rate_unavailable", { $0.heartRate = nil }),
            ("stream_unavailable", { $0.stream = nil }),
            ("clock_unavailable", { $0.ticks = nil })
        ]
        for (detail, configure) in cases {
            let input = DiagnosticInput()
            configure(input)
            let model = makeModel(input)
            defer { model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            model.updateMeasurement()
            model.reset()
            XCTAssertEqual(input.events.map(\.event), [.hrvFailed])
            XCTAssertEqual(input.events.last?.parameters,
                           ["reason": "sensor_unavailable", "stage": "start", "detail": detail, "source": "local"])
        }
    }

    @MainActor
    func testMeasurementFailuresRetainOriginalSourceAndHaveOneTerminalOutcome() {
        let cases: [(String, (DiagnosticInput) -> Void)] = [
            ("source_changed", { $0.isRemote = false }),
            ("stream_changed", { $0.stream = UUID() }),
            ("stream_unavailable", { $0.stream = nil }),
            ("rr_unavailable", { $0.supportsRR = false }),
            ("clock_unavailable", { $0.ticks = .infinity })
        ]
        for (detail, change) in cases {
            let input = DiagnosticInput()
            input.isRemote = true
            let model = makeModel(input)
            defer { model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            change(input)
            model.updateMeasurement()
            model.updateMeasurement()
            model.reset()
            XCTAssertEqual(input.events.map(\.event), [.hrvStart, .hrvFailed])
            XCTAssertEqual(input.events.last?.parameters,
                           ["reason": "sensor_changed", "stage": "measurement", "detail": detail, "source": "shared"])
        }
    }

    @MainActor
    func testMissingBeatsAndInterruptedBeatsHaveDifferentDiagnostics() {
        for receivedBeats in [false, true] {
            let input = DiagnosticInput()
            let model = makeModel(input)
            defer { model.reset(); model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            if receivedBeats {
                input.ticks = 1
                input.history = [interval(at: 1)]
                model.updateMeasurement()
            }
            input.ticks = 7
            model.updateMeasurement()
            XCTAssertEqual(input.events.last?.parameters,
                           ["reason": "data_stopped", "stage": "measurement", "source": "local",
                            "detail": receivedBeats ? "beat_data_stopped" : "no_beats_received"])
        }
    }

    @MainActor
    func testFinalQualityFailureHasBoundedDiagnosticsAndDoesNotSendMeasurements() {
        for remote in [false, true] {
            let input = DiagnosticInput()
            input.isRemote = remote
            let model = makeModel(input)
            defer { model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            input.ticks = 120
            input.history = (1...120).map { interval(at: Double($0), value: $0 == 60 ? 1600 : 1000) }
            model.updateMeasurement()
            model.updateMeasurement()
            model.reset()
            XCTAssertEqual(input.events.map(\.event), [.hrvStart, .hrvFailed])
            XCTAssertEqual(input.events.first?.parameters, ["source": remote ? "shared" : "local"])
            XCTAssertEqual(input.events.last?.parameters,
                           ["reason": "quality_check", "stage": "validation", "detail": "abrupt_variation",
                            "source": remote ? "shared" : "local"])
        }
    }

    @MainActor
    func testCompletedAndCancelledMeasurementsIncludeOnlyCapturedSource() {
        for complete in [false, true] {
            let input = DiagnosticInput()
            input.isRemote = true
            input.heartRate = nil // Remote HRV needs raw beats, not rounded BPM.
            let model = makeModel(input)
            defer { model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            if complete {
                input.ticks = 120
                input.history = (1...120).map { interval(at: Double($0)) }
                model.updateMeasurement()
            }
            input.isRemote = false
            model.reset()
            model.reset()
            XCTAssertEqual(input.events.map(\.event), [.hrvStart, complete ? .hrvCompleted : .hrvCancelled])
            XCTAssertEqual(input.events.map(\.parameters), [["source": "shared"], ["source": "shared"]])
        }
    }

    @MainActor
    func testLocalSensorContextIsCapturedAtStartAndSharedHRVNeverUsesIt() {
        for remote in [false, true] {
            let input = DiagnosticInput()
            input.isRemote = remote
            var identity = SensorAnalyticsIdentity(vendor: .polar, model: .polarH10)
            let model = makeModel(input)
            model.currentSensorAnalyticsIdentity = { identity }
            defer { model.stopLiveHeartRateUpdates() }
            model.startMeasurement()
            identity = SensorAnalyticsIdentity(vendor: .garmin, model: .garminHRMPro)
            input.stream = UUID()
            model.updateMeasurement()
            model.reset()
            XCTAssertEqual(input.events.map(\.event), [.hrvStart, .hrvFailed])
            for event in input.events {
                XCTAssertEqual(event.parameters["source"], remote ? "shared" : "local")
                XCTAssertEqual(event.parameters["sensor_vendor"], remote ? nil : "polar")
                XCTAssertEqual(event.parameters["sensor_model"], remote ? nil : "polar_h10")
            }
        }
    }

    private func interval(at ticks: TimeInterval, value: Double = 1000) -> RRInterval {
        RRInterval(value: value, timestamp: Date(timeIntervalSince1970: 1_800_000_000), receivedTicks: ticks)
    }

    @MainActor
    private func makeModel(_ input: DiagnosticInput) -> HRVMeasurementViewModel {
        let model = HRVMeasurementViewModel(ticksProvider: { input.ticks ?? .nan }, playCompletionSound: {},
                                            emitAnalytics: { input.events.append(DiagnosticEvent(event: $0, parameters: $1)) })
        model.supportsRRIntervals = { input.supportsRR }
        model.currentHeartRate = { input.heartRate }
        model.currentRRStreamID = { input.stream }
        model.getRRIntervals = { input.history }
        model.isRemoteSource = { input.isRemote }
        model.measurementTicks = { input.ticks }
        return model
    }
}

private struct DiagnosticEvent {
    let event: AppAnalytics.Event
    let parameters: [String: String]
}

private final class DiagnosticInput {
    var ticks: TimeInterval? = 0
    var stream: UUID? = UUID()
    var supportsRR = true
    var heartRate: Int? = 60
    var isRemote = false
    var history: [RRInterval] = []
    var events: [DiagnosticEvent] = []
}
