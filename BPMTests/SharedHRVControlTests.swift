import Foundation
import XCTest
@testable import BPM

@MainActor
final class SharedHRVControlTests: XCTestCase {
    func testViewerStartsHostMeasurementAndMirrorsItsResultWithoutLocalAcquisition() {
        let input = Input()
        let host = makeModel(input)
        let timer = makeTimer()
        var viewerEvents: [AppAnalytics.Event] = []
        let viewer = HRVMeasurementViewModel(playCompletionSound: {}, emitAnalytics: { event, _ in viewerEvents.append(event) })
        defer {
            host.reset(); host.stopLiveHeartRateUpdates()
            viewer.reset(); viewer.stopLiveHeartRateUpdates()
            timer.reset()
        }
        viewer.getRRIntervals = { XCTFail("A viewer must not read raw beats"); return [] }
        let ready = snapshot(timer, host)
        XCTAssertTrue(ready.permits(.hrvStart))
        XCTAssertFalse(ready.allowedActions?.contains(.hrvStart) == true)
        let start = command(.hrvStart, ready)
        XCTAssertTrue(SharedWorkoutPresentation.apply(start, to: timer, current: ready, hrv: host))
        XCTAssertEqual(host.state, .countingDown)
        XCTAssertFalse(host.isRemoteMeasurement)
        XCTAssertEqual(timer.state, .idle)
        XCTAssertFalse(SharedWorkoutPresentation.apply(start, to: timer, current: ready, hrv: host))

        let measuring = host.sharedSnapshot(isPresented: true)
        viewer.mirrorSharedMeasurement(measuring, age: 2)
        XCTAssertTrue(viewer.isRemoteMeasurement)
        XCTAssertEqual(viewer.state, .countingDown)
        XCTAssertEqual(viewer.remainingTime, 118)
        viewer.startMeasurement()
        viewer.updateMeasurement()
        XCTAssertEqual(viewer.remainingTime, 118)

        for second in 1...120 {
            input.ticks = 100 + Double(second)
            input.intervals.append(input.interval(at: input.ticks))
            host.recordHeartRateSample(HeartRateSample(value: 60, timestamp: input.date, workoutTime: nil))
            host.updateMeasurement()
        }
        XCTAssertEqual(host.state, .completed)
        XCTAssertEqual(host.hrvValue, 0)
        XCTAssertTrue(host.canSaveMeasurement)
        XCTAssertNotNil(host.hrvRecord())

        viewer.mirrorSharedMeasurement(host.sharedSnapshot(isPresented: true), age: 3)
        XCTAssertEqual(viewer.state, .completed)
        XCTAssertEqual(viewer.hrvValue, host.hrvValue)
        XCTAssertEqual(viewer.avgHeartRate, host.avgHeartRate)
        XCTAssertEqual(viewer.minHeartRate, host.minHeartRate)
        XCTAssertEqual(viewer.maxHeartRate, host.maxHeartRate)
        XCTAssertFalse(viewer.canSaveMeasurement)
        XCTAssertNil(viewer.hrvRecord())
        XCTAssertTrue(viewerEvents.isEmpty)
        XCTAssertEqual(input.events, [.hrvStart, .hrvCompleted])
    }

    func testSharedCancelPreservesWorkoutAndRejectsAStaleRestart() {
        let input = Input()
        let host = makeModel(input)
        let timer = makeTimer()
        defer { host.reset(); host.stopLiveHeartRateUpdates(); timer.reset() }
        timer.start()
        let workoutGenerationBefore = timer.sharingControlGeneration
        let workoutBefore = SharedWorkoutPresentation.snapshot(
            timer: timer, screen: .workout, page: .table, heartRate: 60,
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg", calories: "---"
        )
        let ready = snapshot(timer, host)
        let start = command(.hrvStart, ready)
        XCTAssertTrue(SharedWorkoutPresentation.apply(start, to: timer, current: ready, hrv: host))
        let measuring = snapshot(timer, host)
        XCTAssertTrue(measuring.permits(.hrvCancel))
        XCTAssertFalse(measuring.permits(.hrvReset))
        XCTAssertFalse(measuring.permits(.hrvStart))
        XCTAssertTrue(SharedWorkoutPresentation.apply(command(.hrvCancel, measuring), to: timer, current: measuring, hrv: host))
        XCTAssertEqual(host.state, .idle)
        XCTAssertEqual(input.events, [.hrvStart, .hrvCancelled])
        let idle = snapshot(timer, host)
        XCTAssertFalse(SharedWorkoutPresentation.apply(start, to: timer, current: idle, hrv: host))
        XCTAssertFalse(SharedWorkoutPresentation.apply(command(.hrvCancel, measuring), to: timer, current: idle, hrv: host))
        XCTAssertEqual(timer.state, .running)
        XCTAssertEqual(timer.sharingWorkoutID, workoutBefore.workoutID)
        XCTAssertEqual(timer.sharingControlGeneration, workoutGenerationBefore)
        XCTAssertTrue(timer.sets.isEmpty)
    }

    func testSharedControlRechecksReadinessAndHostSaveLock() {
        let input = Input()
        let host = makeModel(input)
        let timer = makeTimer()
        defer { host.reset(); host.stopLiveHeartRateUpdates(); timer.reset() }
        let ready = snapshot(timer, host)
        input.supportsRR = false
        XCTAssertFalse(SharedWorkoutPresentation.apply(command(.hrvStart, ready), to: timer, current: ready, hrv: host))
        XCTAssertEqual(host.state, .idle)
        XCTAssertTrue(input.events.isEmpty)
        input.supportsRR = true
        let locked = SharedWorkoutPresentation.snapshot(
            timer: timer, screen: .workout, page: .table, heartRate: 60,
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg", calories: "---",
            allowsRemoteControl: false, hrv: host.sharedSnapshot(isPresented: false)
        )
        XCTAssertFalse(locked.permits(.hrvStart))
        XCTAssertFalse(SharedWorkoutPresentation.apply(command(.hrvStart, locked), to: timer, current: locked, hrv: host))
    }

    func testReadinessAndMeasurementLifecycleControlEligibility() {
        let input = Input()
        let model = makeModel(input)
        defer { model.reset(); model.stopLiveHeartRateUpdates() }
        let idle = model.sharedSnapshot(isPresented: true)
        XCTAssertTrue(idle.permits(.hrvStart))
        XCTAssertFalse(idle.permits(.hrvReset))
        let originalRevision = idle.revision
        model.startMeasurement()
        input.ticks += 1
        input.intervals.append(input.interval(at: input.ticks))
        model.updateMeasurement()
        let firstTick = model.sharedSnapshot(isPresented: true)
        input.ticks += 1
        input.intervals.append(input.interval(at: input.ticks))
        model.updateMeasurement()
        let secondTick = model.sharedSnapshot(isPresented: true)
        XCTAssertNotEqual(firstTick.revision, originalRevision)
        XCTAssertEqual(firstTick.revision, secondTick.revision)
        XCTAssertLessThan(secondTick.remainingTime, firstTick.remainingTime)

        input.supportsRR = false
        model.updateMeasurement()
        let failed = model.sharedSnapshot(isPresented: true)
        XCTAssertEqual(failed.state, .error)
        XCTAssertTrue(failed.permits(.hrvReset))
        XCTAssertFalse(failed.permits(.hrvStart))
        XCTAssertFalse(failed.permits(.hrvCancel))
        XCTAssertTrue(model.applySharedControl(.hrvReset))
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.sharedSnapshot(isPresented: true).permits(.hrvStart))
    }

    func testMissingInvalidAndStaleSnapshotsNeverStartViewerAcquisitionOrFinishEarly() {
        var events: [AppAnalytics.Event] = []
        let viewer = HRVMeasurementViewModel(playCompletionSound: {}, emitAnalytics: { event, _ in events.append(event) })
        defer { viewer.reset(); viewer.stopLiveHeartRateUpdates() }
        viewer.currentHeartRate = { XCTFail("Missing shared state must not use local readings"); return 70 }
        viewer.mirrorSharedMeasurement(nil)
        viewer.startMeasurement()
        XCTAssertEqual(viewer.state, .idle)
        XCTAssertTrue(viewer.isRemoteMeasurement)

        var measuring = sharedSnapshot(state: .measuring)
        measuring.remainingTime = 3
        viewer.mirrorSharedMeasurement(measuring, age: 100)
        XCTAssertEqual(viewer.remainingTime, 0)
        XCTAssertEqual(viewer.state, .countingDown)
        XCTAssertNil(viewer.hrvValue)
        viewer.updateMeasurement()
        XCTAssertEqual(viewer.state, .countingDown)
        measuring.remainingTime = .nan
        XCTAssertFalse(measuring.isValid)
        viewer.mirrorSharedMeasurement(measuring)
        XCTAssertEqual(viewer.state, .idle)
        XCTAssertNil(viewer.hrvRecord())
        XCTAssertTrue(events.isEmpty)
    }

    func testConfiguringLocalSourceAllowsHostStartBeforeHRVScreenAppears() {
        let manager = HeartRateBluetoothManager()
        manager.isSimulatorConnected = true
        manager.receiveHeartRateMeasurement(HeartRateMeasurementData(
            heartRate: 60, sensorContactStatus: .detected, hasRRIntervals: true, rrIntervals: [1000]
        ))
        let host = HRVMeasurementViewModel(playCompletionSound: {}, emitAnalytics: { _, _ in })
        defer { host.reset(); host.stopLiveHeartRateUpdates(); manager.isSimulatorConnected = false }
        host.configureLocalSource(manager)
        let idle = host.sharedSnapshot(isPresented: false)
        XCTAssertTrue(idle.permits(.hrvStart))
        XCTAssertEqual(idle.currentBPM, 60)
        XCTAssertTrue(host.applySharedControl(.hrvStart))
        XCTAssertEqual(host.state, .countingDown)
        XCTAssertFalse(host.isRemoteMeasurement)
    }

    func testSnapshotRoundTripAndLegacyWorkoutCompatibility() throws {
        let timer = makeTimer()
        defer { timer.reset() }
        let legacy = SharedWorkoutPresentation.snapshot(
            timer: timer, screen: .home, page: .table, heartRate: nil,
            zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg", calories: "---"
        )
        XCTAssertNil(legacy.hrv)
        XCTAssertFalse(legacy.permits(.hrvStart))
        var updated = legacy
        updated.hrv = sharedSnapshot(state: .completed)
        updated.hrv?.hrvValue = 42.5
        XCTAssertEqual(try JSONDecoder().decode(SharedWorkoutSnapshot.self, from: JSONEncoder().encode(updated)), updated)
        let decodedLegacy = try JSONDecoder().decode(SharedWorkoutSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decodedLegacy.hrv)
        XCTAssertTrue(updated.permits(.hrvStart))
        XCTAssertTrue(updated.permits(.hrvReset))
    }

    private func sharedSnapshot(state: SharedHRVSnapshot.State) -> SharedHRVSnapshot {
        SharedHRVSnapshot(revision: UUID().uuidString, isPresented: true, state: state, remainingTime: 120,
                          hrvValue: nil, avgHeartRate: nil, minHeartRate: nil, maxHeartRate: nil, currentBPM: 60,
                          readinessReason: .ready, errorMessage: nil, allowsRemoteControl: true)
    }

    private func snapshot(_ timer: TimerViewModel, _ hrv: HRVMeasurementViewModel) -> SharedWorkoutSnapshot {
        SharedWorkoutPresentation.snapshot(timer: timer, screen: .home, page: .table, heartRate: 60,
                                          zoneConfig: HeartRateZoneConfig(maxHeartRate: 190), primaryBPM: "avg",
                                          calories: "---", hrv: hrv.sharedSnapshot(isPresented: false))
    }

    private func command(_ action: SharedWorkoutAction, _ snapshot: SharedWorkoutSnapshot) -> SharedWorkoutCommand {
        SharedWorkoutCommand(id: UUID().uuidString, workoutID: snapshot.workoutID,
                             controlRevision: snapshot.controlRevision, action: action, createdAt: 0)
    }

    private func makeTimer() -> TimerViewModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-hrv-\(UUID()).json")
        return TimerViewModel(presetStartCountdownDuration: 0, sessionStore: ActiveWorkoutSessionStore(fileURL: url),
                              nowProvider: { Date(timeIntervalSince1970: 1000) }, soundCueHandler: { _ in })
    }

    private func makeModel(_ input: Input) -> HRVMeasurementViewModel {
        let model = HRVMeasurementViewModel(ticksProvider: { input.ticks }, nowProvider: { input.date },
                                            playCompletionSound: {}, emitAnalytics: { event, _ in input.events.append(event) })
        model.currentHeartRate = { 60 }
        model.currentRRStreamID = { input.stream }
        model.supportsRRIntervals = { input.supportsRR }
        model.getRRIntervals = { input.intervals }
        model.startReadiness = {
            .local(isConnected: true, hasSensorContact: true, hasFreshHeartRate: true,
                   supportsRR: input.supportsRR, latestRRTicks: input.intervals.last?.receivedTicks, nowTicks: input.ticks)
        }
        return model
    }

    private final class Input {
        var ticks: TimeInterval = 100
        let stream = UUID()
        var supportsRR = true
        var intervals = [RRInterval(value: 1000, timestamp: Date(timeIntervalSince1970: 1000), receivedTicks: 100)]
        var events: [AppAnalytics.Event] = []
        var date: Date { Date(timeIntervalSince1970: 1000 + ticks - 100) }
        func interval(at ticks: TimeInterval) -> RRInterval {
            RRInterval(value: 1000, timestamp: date, receivedTicks: ticks)
        }
    }
}
