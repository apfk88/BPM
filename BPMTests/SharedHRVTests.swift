import Foundation
import XCTest
@testable import BPM

final class SharedHRVTests: XCTestCase {
    func testRepeatedPacketsAndBeatsCannotExtendFreshnessOrDuplicateIntervals() {
        let buffer = SharedRRStreamBuffer()
        let stream = UUID()
        let beat = SharedRRInterval(id: UUID(), value: 1000, receivedTicks: 1000)
        let initial = snapshot(stream: stream, sequence: 1, ticks: 1000, intervals: [beat])
        XCTAssertTrue(receive(initial, into: buffer, localTicks: 0))
        let identity = buffer.intervals.first?.id
        XCTAssertFalse(receive(initial, into: buffer, localTicks: 4))
        XCTAssertTrue(receive(snapshot(stream: stream, sequence: 2, ticks: 1004, intervals: [beat]), into: buffer, localTicks: 4))
        XCTAssertEqual(buffer.intervals.count, 1)
        XCTAssertEqual(buffer.intervals.first?.id, identity)
        XCTAssertEqual(buffer.intervals.first?.value, 1000)
        XCTAssertEqual(buffer.intervals.first?.receivedTicks, 1000)
        XCTAssertTrue(buffer.isFresh(at: 4.9))
        XCTAssertFalse(buffer.isFresh(at: 5))
    }

    func testTransportAgeIsConservativeAndUnsupportedStreamNeverManufacturesIntervals() {
        let buffer = SharedRRStreamBuffer()
        let stream = UUID()
        let beat = SharedRRInterval(id: UUID(), value: 0, receivedTicks: 1000)
        let packet = snapshot(stream: stream, sequence: 1, ticks: 1000, intervals: [beat])
        XCTAssertTrue(buffer.receive(snapshot: packet, serverTimestamp: 10_000, serverTime: 12_000,
                                     receivedAtTicks: 100, transportAge: 1, now: Date()))
        // Implausible raw values remain present so the quality check rejects
        // the recording. Transport must never silently remove or replace them.
        XCTAssertEqual(buffer.intervals.first?.value, 0)
        XCTAssertTrue(buffer.isFresh(at: 101.9))
        XCTAssertFalse(buffer.isFresh(at: 102))
        let unsupported = SharedRRStreamSnapshot(sequence: 2, streamID: stream, supportsRRIntervals: false,
                                                 sourceTicks: 1001, intervals: [])
        XCTAssertTrue(receive(unsupported, into: buffer, localTicks: 101))
        XCTAssertFalse(buffer.isFresh(at: 101))
        XCTAssertTrue(buffer.intervals.isEmpty)
    }

    func testReorderedAndMutatedRawIntervalsInvalidateTheStream() {
        let buffer = SharedRRStreamBuffer()
        let stream = UUID()
        let beat = SharedRRInterval(id: UUID(), value: 1000, receivedTicks: 1000)
        XCTAssertTrue(receive(snapshot(stream: stream, sequence: 1, ticks: 1000, intervals: [beat]), into: buffer, localTicks: 0))
        let altered = SharedRRInterval(id: beat.id, value: 900, receivedTicks: 1000)
        XCTAssertFalse(receive(snapshot(stream: stream, sequence: 2, ticks: 1001, intervals: [altered]), into: buffer, localTicks: 1))
        XCTAssertFalse(buffer.isFresh(at: 1))
        XCTAssertTrue(buffer.intervals.isEmpty)

        buffer.reset()
        let later = SharedRRInterval(id: UUID(), value: 1000, receivedTicks: 1001)
        XCTAssertFalse(receive(snapshot(stream: stream, sequence: 1, ticks: 1001, intervals: [later, beat]), into: buffer, localTicks: 1))
        XCTAssertFalse(buffer.isFresh(at: 1))
        XCTAssertFalse(buffer.receive(snapshot: snapshot(stream: stream, sequence: 2, ticks: 1001, intervals: [later]),
                                      serverTimestamp: 11_000, serverTime: 10_000, receivedAtTicks: 1, transportAge: 0, now: Date()))
        XCTAssertFalse(buffer.isFresh(at: 1))
    }

    @MainActor
    func testRemoteMeasurementUsesRawSourceClockDespiteNetworkJitterAndCannotBeSaved() throws {
        let input = RemoteHRVInput()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        input.publish(second: 0)
        model.startMeasurement()
        XCTAssertEqual(model.state, .countingDown)
        XCTAssertTrue(model.isRemoteMeasurement)

        for second in 1...120 {
            // Receiver clocks and delivery jitter are unrelated to the original
            // source ticks. Neither may alter which raw beats enter the window.
            input.localTicks = 10_000 + Double(second) + (second.isMultiple(of: 2) ? 0.4 : 0.1)
            input.wallClockOffset = second >= 60 ? 3600 : 0
            input.publish(second: second)
            model.updateMeasurement()
            model.updateMeasurement()
            XCTAssertEqual(model.remainingTime, Double(120 - second), accuracy: 0.000001)
        }
        XCTAssertTrue(model.isCompleted)
        XCTAssertEqual(try XCTUnwrap(model.hrvValue), 40, accuracy: 0.000001)
        XCTAssertFalse(model.canSaveMeasurement)
        XCTAssertNil(model.hrvRecord())
        input.isRemote = false
        XCTAssertFalse(model.canSaveMeasurement)
        XCTAssertNil(model.hrvRecord(), "Switching back to a local monitor cannot make a friend's result saveable")
    }

    @MainActor
    func testFreshSharedBPMAloneCannotStartHRV() {
        let input = RemoteHRVInput()
        input.heartRate = 75
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        model.startMeasurement()
        XCTAssertTrue(model.hasError)
        XCTAssertNil(model.hrvValue)
        XCTAssertNil(model.hrvRecord())
        XCTAssertTrue(input.buffer.intervals.isEmpty)
    }

    @MainActor
    func testRemoteDataExpiryOrMonitorChangeFailsWithoutJoiningStreams() {
        for changeStream in [false, true] {
            let input = RemoteHRVInput()
            let model = makeModel(input)
            defer { model.reset(); model.stopLiveHeartRateUpdates() }
            input.publish(second: 0)
            model.startMeasurement()
            input.localTicks += 1
            input.publish(second: 1)
            model.updateMeasurement()
            if changeStream {
                input.stream = UUID()
                input.wireIntervals.removeAll()
                input.localTicks += 1
                input.publish(second: 2)
            } else {
                input.localTicks += 5
            }
            model.updateMeasurement()
            XCTAssertTrue(model.hasError)
            XCTAssertNil(model.hrvValue)
            XCTAssertNil(model.hrvRecord())
        }
    }

    @MainActor
    func testRemoteArtifactsFailQualityInsteadOfProducingAResultFromFilteredBeats() {
        let input = RemoteHRVInput()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        input.publish(second: 0)
        model.startMeasurement()
        for second in 1...120 {
            input.localTicks += 1
            input.publish(second: second, value: second == 60 ? 1600 : nil)
            model.updateMeasurement()
        }
        XCTAssertTrue(model.hasError)
        XCTAssertNil(model.hrvValue)
        XCTAssertNil(model.hrvRecord())
    }

    @MainActor
    private func makeModel(_ input: RemoteHRVInput) -> HRVMeasurementViewModel {
        let model = HRVMeasurementViewModel(ticksProvider: { input.localTicks }, nowProvider: { input.date },
                                            playCompletionSound: {}, emitAnalytics: { _, _ in })
        model.isRemoteSource = { input.isRemote }
        model.currentHeartRate = { input.heartRate }
        model.supportsRRIntervals = { input.buffer.isFresh(at: input.localTicks) }
        model.currentRRStreamID = { input.buffer.streamID }
        model.getRRIntervals = { input.buffer.intervals }
        model.measurementTicks = { input.buffer.isFresh(at: input.localTicks) ? input.buffer.sourceTicks : nil }
        return model
    }

    private func snapshot(stream: UUID, sequence: Int64, ticks: TimeInterval, intervals: [SharedRRInterval]) -> SharedRRStreamSnapshot {
        SharedRRStreamSnapshot(sequence: sequence, streamID: stream, supportsRRIntervals: true,
                               sourceTicks: ticks, intervals: intervals)
    }

    private func receive(_ snapshot: SharedRRStreamSnapshot, into buffer: SharedRRStreamBuffer, localTicks: TimeInterval) -> Bool {
        buffer.receive(snapshot: snapshot, serverTimestamp: 10_000, serverTime: 10_000,
                       receivedAtTicks: localTicks, transportAge: 0, now: Date())
    }
}

private final class RemoteHRVInput {
    let buffer = SharedRRStreamBuffer()
    var localTicks: TimeInterval = 10_000
    var wallClockOffset: TimeInterval = 0
    var stream = UUID()
    var isRemote = true
    var heartRate: Int?
    var wireIntervals: [SharedRRInterval] = []
    var date: Date { Date(timeIntervalSince1970: 1_800_000_000 + localTicks + wallClockOffset) }

    func publish(second: Int, value: Double? = nil) {
        let ticks = 1000 + Double(second)
        wireIntervals.append(SharedRRInterval(id: UUID(), value: value ?? (second.isMultiple(of: 2) ? 980 : 1020),
                                             receivedTicks: ticks))
        let packet = SharedRRStreamSnapshot(sequence: Int64(second + 1), streamID: stream, supportsRRIntervals: true,
                                            sourceTicks: ticks, intervals: wireIntervals.filter { ticks - $0.receivedTicks <= 15 })
        XCTAssertTrue(buffer.receive(snapshot: packet, serverTimestamp: 10_000, serverTime: 10_000,
                                     receivedAtTicks: localTicks, transportAge: 0, now: date))
    }
}
