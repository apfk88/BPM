import Foundation
import Combine
import XCTest
@testable import BPM

final class HRVAcquisitionAccuracyTests: XCTestCase {
    func testCoverageCannotCancelMissingBeatsAgainstLaterExtraIntervals() {
        var intervals: [RRInterval] = []
        for second in stride(from: 2, through: 40, by: 2) {
            intervals.append(interval(at: Double(second)))
        }
        for second in stride(from: 42, through: 80, by: 2) {
            intervals.append(contentsOf: (0..<3).map { _ in interval(at: Double(second)) })
        }
        intervals.append(contentsOf: (81...120).map { interval(at: Double($0)) })
        // Total interval duration is exactly 120 seconds, every RR is plausible,
        // and no notification gap exceeds two seconds. Local coverage is wrong.
        XCTAssertEqual(intervals.count, 120)
        XCTAssertNotNil(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: 120))
    }

    func testBatchedNotificationsPreserveAllIntervalsAndPassCoverage() {
        let intervals = stride(from: 3, through: 120, by: 3).flatMap { second in
            (0..<3).map { _ in interval(at: Double(second)) }
        }
        XCTAssertNil(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: 120))
        XCTAssertEqual(HRVCalculator.rmssd(intervals.map(\.value)), 0)
    }

    func testQualityRejectsIntervalsOutsideRecordingWindow() {
        var intervals = (1...120).map { interval(at: Double($0)) }
        intervals[0] = interval(at: 0)
        XCTAssertNotNil(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: 120))
        intervals[0] = interval(at: 1)
        intervals[119] = interval(at: 121)
        XCTAssertNotNil(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: 120))
        intervals[119] = interval(at: 120)
        XCTAssertNotNil(HRVCalculator.qualityError(intervals: intervals, start: .nan, duration: 120))
        XCTAssertNotNil(HRVCalculator.qualityError(intervals: intervals, start: 0, duration: .infinity))
    }

    @MainActor func testHeartRateStatsUseEveryReceivedSampleWithTimeWeighting() throws {
        let input = HRVAccuracyInput()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.startMeasurement()
        input.ticks = 1
        model.recordHeartRateSample(sample(60, at: input.date))
        input.ticks = 1.2
        let peak = sample(100, at: input.date)
        model.recordHeartRateSample(peak)
        model.recordHeartRateSample(peak)
        input.ticks = 1.3
        // Calendar corrections do not move samples out of the recording window.
        model.recordHeartRateSample(sample(80, at: input.date.addingTimeInterval(3600)))
        input.ticks = 120.1
        model.recordHeartRateSample(sample(140, at: input.date))
        input.history = (1...120).map { interval(at: Double($0)) }
        model.updateMeasurement()

        let record = try XCTUnwrap(model.hrvRecord())
        XCTAssertEqual(record.hrSamples.map(\.bpm), [60, 100, 80])
        XCTAssertEqual(record.minHr, 60)
        XCTAssertEqual(record.maxHr, 100)
        // (60 * .2 + 100 * .1 + 80 * 3) / 3.3 = 79.39 BPM.
        // The final reading expires after three seconds, not at the deadline.
        XCTAssertEqual(record.avgHr, 79)
        XCTAssertEqual(record.hrSamples[2].timestamp.timeIntervalSince(record.startAt), 1.3, accuracy: 0.000001)
    }

    @MainActor func testTimerPollsNeverInventHeartRateMeasurements() throws {
        let input = HRVAccuracyInput()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.startMeasurement()
        for second in 1...120 {
            input.ticks = Double(second)
            input.history = [interval(at: input.ticks)]
            model.updateMeasurement()
        }
        let record = try XCTUnwrap(model.hrvRecord())
        XCTAssertEqual(record.hrvValue, 0)
        XCTAssertTrue(record.hrSamples.isEmpty)
        XCTAssertNil(record.avgHr)
        XCTAssertNil(record.minHr)
        XCTAssertNil(record.maxHr)
    }

    @MainActor func testModelOwnsSensorSubscriptionAndReplacingItDoesNotDuplicateSamples() throws {
        let input = HRVAccuracyInput()
        let model = makeModel(input)
        let measurements = PassthroughSubject<HeartRateSample, Never>()
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.observeHeartRate(from: measurements.eraseToAnyPublisher())
        model.startMeasurement()
        input.ticks = 1
        measurements.send(sample(60, at: input.date))
        model.observeHeartRate(from: measurements.eraseToAnyPublisher())
        input.ticks = 2
        measurements.send(sample(70, at: input.date))
        input.ticks = 120
        input.history = (1...120).map { interval(at: Double($0)) }
        model.updateMeasurement()
        let record = try XCTUnwrap(model.hrvRecord())
        XCTAssertEqual(record.hrSamples.map(\.bpm), [60, 70])
    }

    @MainActor func testHeartRateSamplesOutsideActiveStreamAreExcluded() {
        let input = HRVAccuracyInput()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.recordHeartRateSample(sample(200, at: input.date))
        model.startMeasurement()
        input.ticks = 1
        model.recordHeartRateSample(HeartRateSample(value: 180, timestamp: input.date, workoutTime: nil, sensorContactStatus: .notDetected))
        model.recordHeartRateSample(sample(0, at: input.date))
        input.stream = UUID()
        model.recordHeartRateSample(sample(210, at: input.date))
        XCTAssertNil(model.minHeartRate)
        XCTAssertNil(model.maxHeartRate)
    }

    private func interval(at ticks: TimeInterval) -> RRInterval {
        RRInterval(value: 1000, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + ticks), receivedTicks: ticks)
    }

    private func sample(_ bpm: Int, at date: Date) -> HeartRateSample {
        HeartRateSample(value: bpm, timestamp: date, workoutTime: nil)
    }

    @MainActor private func makeModel(_ input: HRVAccuracyInput) -> HRVMeasurementViewModel {
        let model = HRVMeasurementViewModel(
            ticksProvider: { input.ticks }, nowProvider: { input.date },
            playCompletionSound: {}, emitAnalytics: { _, _ in }
        )
        model.supportsRRIntervals = { true }
        model.currentHeartRate = { 60 }
        model.currentRRStreamID = { input.stream }
        model.getRRIntervals = { input.history }
        return model
    }
}

private final class HRVAccuracyInput {
    var ticks: TimeInterval = 0
    var stream: UUID? = UUID()
    var history: [RRInterval] = []
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + ticks) }
}
