import XCTest
@testable import BPM

final class SimulatorRRIntervalGeneratorTests: XCTestCase {
    func testTwoSecondPacketsCoverRealElapsedTimeAcrossSimulatorHeartRates() {
        for heartRate in [40, 100, 220] {
            var generator = SimulatorRRIntervalGenerator()
            XCTAssertTrue(generator.intervals(at: 0, heartRate: heartRate, variation: { 0 }).isEmpty)
            var intervals: [RRInterval] = []
            for tick in stride(from: 2.0, through: 120.0, by: 2) {
                intervals += generator.intervals(at: tick, heartRate: heartRate, variation: { 0 }).map {
                    RRInterval(value: $0, timestamp: Date(timeIntervalSince1970: tick), receivedTicks: tick)
                }
            }
            let beatDuration = 60.0 / Double(heartRate)
            XCTAssertEqual(intervals.reduce(0) { $0 + $1.value / 1000 }, 120, accuracy: beatDuration + 0.0001)
            XCTAssertNil(HRVCalculator.qualityIssue(intervals: intervals, start: 0, duration: 120),
                         "\(heartRate) BPM must provide complete beat coverage over the measurement")
        }
    }

    func testPartialBeatsCarryAcrossPacketsAndDuplicatePollsAddNothing() {
        var generator = SimulatorRRIntervalGenerator()
        XCTAssertTrue(generator.intervals(at: 0, heartRate: 100, variation: { 0 }).isEmpty)
        XCTAssertEqual(generator.intervals(at: 2, heartRate: 100, variation: { 0 }), [600, 600, 600])
        XCTAssertTrue(generator.intervals(at: 2, heartRate: 100, variation: { 0 }).isEmpty)
        XCTAssertEqual(generator.intervals(at: 2.5, heartRate: 100, variation: { 0 }), [600])
        XCTAssertEqual(generator.intervals(at: 4, heartRate: 100, variation: { 0 }), [600, 600])
    }

    func testInterruptedPacketsDoNotInventMissingBeatHistory() {
        var generator = SimulatorRRIntervalGenerator()
        _ = generator.intervals(at: 0, heartRate: 100, variation: { 0 })
        _ = generator.intervals(at: 2, heartRate: 100, variation: { 0 })
        XCTAssertTrue(generator.intervals(at: 20, heartRate: 100, variation: { 0 }).isEmpty)
        XCTAssertEqual(generator.intervals(at: 22, heartRate: 100, variation: { 0 }), [600, 600, 600])
    }

    @MainActor
    func testFullSimulatorMeasurementCompletesWithVaryingBeatIntervals() throws {
        var ticks: TimeInterval = 0
        var history: [RRInterval] = []
        let streamID = UUID()
        var generator = SimulatorRRIntervalGenerator()
        var beat = 0
        let variation = { () -> Double in
            beat += 1
            return beat.isMultiple(of: 2) ? 0.025 : -0.025
        }
        _ = generator.intervals(at: ticks, heartRate: 100, variation: variation)
        let model = HRVMeasurementViewModel(ticksProvider: { ticks },
                                            nowProvider: { Date(timeIntervalSince1970: ticks) },
                                            playCompletionSound: {}, emitAnalytics: { _, _ in })
        model.currentHeartRate = { 100 }
        model.supportsRRIntervals = { true }
        model.currentRRStreamID = { streamID }
        model.getRRIntervals = { history }
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.startMeasurement()
        XCTAssertEqual(model.state, .countingDown)
        for tick in stride(from: 2.0, through: 120.0, by: 2) {
            ticks = tick
            history += generator.intervals(at: ticks, heartRate: 100, variation: variation).map {
                RRInterval(value: $0, timestamp: Date(timeIntervalSince1970: ticks), receivedTicks: ticks)
            }
            model.updateMeasurement()
        }
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(try XCTUnwrap(model.hrvValue), 30, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(model.hrvRecord()).durationSeconds, 120)
    }
}
