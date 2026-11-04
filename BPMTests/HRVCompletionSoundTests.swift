import XCTest
@testable import BPM

final class HRVCompletionSoundTests: XCTestCase {
    @MainActor func testValidCompletionPlaysExactlyOnce() {
        let input = MeasurementInput()
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        record(seconds: 119, model: model, input: input)
        XCTAssertEqual(model.state, .countingDown)
        XCTAssertEqual(soundCount, 0)

        record(seconds: 1, model: model, input: input)
        XCTAssertEqual(model.state, .completed)
        XCTAssertNotNil(model.hrvRecord())
        XCTAssertEqual(soundCount, 1)
        model.updateMeasurement()
        model.reset()
        XCTAssertEqual(soundCount, 1)
    }

    @MainActor func testInvalidCompletedRecordingDoesNotPlay() {
        let input = MeasurementInput()
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        record(seconds: 60, model: model, input: input)
        input.ticks += 1
        input.history = [RRInterval(value: 1600, timestamp: input.date, receivedTicks: input.ticks)]
        model.updateMeasurement()
        record(seconds: 59, model: model, input: input)

        XCTAssertTrue(model.hasError)
        XCTAssertNil(model.hrvRecord())
        XCTAssertEqual(soundCount, 0)
    }

    @MainActor func testUnavailableSensorDoesNotPlay() {
        let input = MeasurementInput()
        input.stream = nil
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        XCTAssertTrue(model.hasError)
        XCTAssertEqual(soundCount, 0)
    }

    @MainActor func testChangedSensorDoesNotPlay() {
        let input = MeasurementInput()
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        record(seconds: 1, model: model, input: input)
        input.stream = UUID()
        model.updateMeasurement()
        XCTAssertTrue(model.hasError)
        XCTAssertEqual(soundCount, 0)
    }

    @MainActor func testInterruptedMeasurementDoesNotPlay() {
        let input = MeasurementInput()
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        input.ticks = 6
        model.updateMeasurement()
        input.ticks = 120
        model.updateMeasurement()
        XCTAssertTrue(model.hasError)
        XCTAssertEqual(soundCount, 0)
    }

    @MainActor func testCancelledMeasurementDoesNotPlayAtOriginalDeadline() {
        let input = MeasurementInput()
        var soundCount = 0
        let model = makeModel(input: input) { soundCount += 1 }
        defer { model.stopLiveHeartRateUpdates() }

        model.startMeasurement()
        record(seconds: 119, model: model, input: input)
        model.reset()
        record(seconds: 1, model: model, input: input)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.hrvRecord())
        XCTAssertEqual(soundCount, 0)
    }

    @MainActor private func makeModel(input: MeasurementInput, sound: @escaping () -> Void) -> HRVMeasurementViewModel {
        let model = HRVMeasurementViewModel(
            ticksProvider: { input.ticks },
            nowProvider: { input.date },
            playCompletionSound: sound,
            emitAnalytics: { _, _ in }
        )
        model.supportsRRIntervals = { true }
        model.currentHeartRate = { 60 }
        model.currentRRStreamID = { input.stream }
        model.getRRIntervals = { input.history }
        return model
    }

    @MainActor private func record(seconds: Int, model: HRVMeasurementViewModel, input: MeasurementInput) {
        for _ in 0..<seconds {
            input.ticks += 1
            let interval = Int(input.ticks).isMultiple(of: 2) ? 1010.0 : 990.0
            input.history = [RRInterval(value: interval, timestamp: input.date, receivedTicks: input.ticks)]
            model.updateMeasurement()
        }
    }
}

private final class MeasurementInput {
    var ticks: TimeInterval = 0
    var stream: UUID? = UUID()
    var history: [RRInterval] = []
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + ticks) }
}
