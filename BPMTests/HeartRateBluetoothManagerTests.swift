//
//  HeartRateBluetoothManagerTests.swift
//  BPMTests
//
//  Created by Codex.
//

import Foundation
import Combine
import Testing
@testable import BPM

struct HeartRateBluetoothManagerTests {
    @Test @MainActor func knownSignalLossPreservesBPMAndFirstInvalidationTime() {
        let manager = HeartRateBluetoothManager()
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0, 120])))
        var invalidations: [Date] = []
        let subscription = manager.heartRateInvalidations.sink { date in
            #expect(manager.freshHeartRate == nil)
            invalidations.append(date)
        }

        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([4, 120])))
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([4, 120])))

        #expect(invalidations.count == 2)
        #expect(manager.heartRateSamples.map(\.value) == [120])
        #expect(manager.heartRateSamples.first?.invalidatedAt == invalidations.first)
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0, 160])))
        #expect(manager.heartRateSamples.last?.invalidatedAt == nil)
        subscription.cancel()
    }

    @Test func liveAverageStopsAtKnownLossBeforeFreshnessExpires() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [HeartRateSample(value: 100, timestamp: origin, workoutTime: nil,
                                      invalidatedAt: origin.addingTimeInterval(1)),
                       HeartRateSample(value: 200, timestamp: origin.addingTimeInterval(2), workoutTime: nil)]
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: samples, now: origin.addingTimeInterval(3)) == 150)
    }

    @Test @MainActor func switchingSensorsStartsIndependentMeasurementHistory() {
        let manager = HeartRateBluetoothManager()
        let firstDevice = UUID()
        manager.beginMeasurementStream(for: firstDevice)
        manager.receiveHeartRateMeasurement(HeartRateMeasurementData(
            heartRate: 60, sensorContactStatus: .detected,
            hasRRIntervals: true, rrIntervals: [1000]
        ))
        let oldHRSession = manager.heartRateSessionID
        let oldRRStream = manager.rrStreamID
        #expect(manager.supportsRRIntervals)
        #expect(manager.currentHeartRate == 60)

        manager.beginMeasurementStream(for: UUID())

        #expect(manager.heartRateSessionID != oldHRSession)
        #expect(manager.rrStreamID != oldRRStream)
        #expect(manager.heartRateSamples.isEmpty)
        #expect(manager.rrIntervals.isEmpty)
        #expect(!manager.supportsRRIntervals)
        #expect(manager.currentHeartRate == nil)
        #expect(manager.freshHeartRate == nil)
    }

    @Test @MainActor func reconnectNeverSplicesRRButKeepsSameSensorHistory() {
        let manager = HeartRateBluetoothManager()
        let device = UUID()
        manager.beginMeasurementStream(for: device)
        manager.receiveHeartRateMeasurement(HeartRateMeasurementData(
            heartRate: 60, sensorContactStatus: .detected,
            hasRRIntervals: true, rrIntervals: [1000]
        ))
        let oldHRSession = manager.heartRateSessionID
        let oldRRStream = manager.rrStreamID

        manager.beginMeasurementStream(for: device)

        #expect(manager.heartRateSessionID == oldHRSession)
        #expect(manager.heartRateSamples.count == 1)
        #expect(manager.rrStreamID != oldRRStream)
        #expect(manager.rrIntervals.isEmpty)
        #expect(!manager.supportsRRIntervals)
        #expect(manager.freshHeartRate == nil)
    }

    @Test @MainActor func malformedPacketImmediatelyClearsPriorDisplayedReading() {
        let manager = HeartRateBluetoothManager()
        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0, 120])))
        let stream = manager.rrStreamID
        #expect(manager.freshHeartRate == 120)

        manager.receiveHeartRateMeasurement(HeartRateBluetoothManager.parseHeartRateData(from: Data([0x10, 120, 0])))

        #expect(manager.currentHeartRate == nil)
        #expect(manager.freshHeartRate == nil)
        #expect(manager.rrStreamID != stream)
        #expect(manager.heartRateSamples.count == 1)
    }

    @Test func liveAverageWeightsElapsedTimeRatherThanNotificationCount() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [(0.0, 100), (1.0, 200), (1.1, 200), (2.0, 100)].map { time, bpm in
            HeartRateSample(value: bpm, timestamp: origin.addingTimeInterval(time), workoutTime: nil)
        }
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: samples, now: origin.addingTimeInterval(3)) == 133)
    }

    @Test func liveAverageDoesNotExtendLastReadingAcrossDropout() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            HeartRateSample(value: 100, timestamp: origin, workoutTime: nil),
            HeartRateSample(value: 200, timestamp: origin.addingTimeInterval(100), workoutTime: nil)
        ]
        // 3 seconds at 100 plus 1 at 200; the 97-second gap is unknown.
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: samples, now: origin.addingTimeInterval(101)) == 125)
    }

    @Test func liveStatisticsExpireOldHistoryAndClipAtHourBoundary() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            HeartRateSample(value: 100, timestamp: origin, workoutTime: nil),
            HeartRateSample(value: 200, timestamp: origin.addingTimeInterval(3600), workoutTime: nil)
        ]
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: samples, now: origin.addingTimeInterval(3601)) == 133)
        #expect(HeartRateBluetoothManager.recentHeartRateSamples(samples, now: origin.addingTimeInterval(3601)).map(\.value) == [200])
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: samples, now: origin.addingTimeInterval(8000)) == nil)
        #expect(HeartRateBluetoothManager.recentHeartRateSamples(samples, now: origin.addingTimeInterval(8000)).isEmpty)
        #expect(HeartRateBluetoothManager.timeWeightedAverage(samples: [samples[0]], now: origin) == 100)
    }

    @Test func staleSampleHelperUsesTimeout() {
        let now = Date()
        #expect(HeartRateBluetoothManager.isStaleSample(lastSample: nil, now: now, timeout: 300) == false)
        #expect(HeartRateBluetoothManager.isStaleSample(lastSample: now.addingTimeInterval(-299), now: now, timeout: 300) == false)
        #expect(HeartRateBluetoothManager.isStaleSample(lastSample: now.addingTimeInterval(-300), now: now, timeout: 300) == true)
    }

    @Test func noDataWarningHelperUsesInterval() {
        let now = Date()
        #expect(HeartRateBluetoothManager.shouldShowNoDataWarning(lastSample: nil, now: now, interval: 5) == true)
        #expect(HeartRateBluetoothManager.shouldShowNoDataWarning(lastSample: now.addingTimeInterval(-4), now: now, interval: 5) == false)
        #expect(HeartRateBluetoothManager.shouldShowNoDataWarning(lastSample: now.addingTimeInterval(-5), now: now, interval: 5) == true)
    }

    @Test func initialNoDataWarningHelperHonorsReceivedDataFlag() {
        let now = Date()
        #expect(HeartRateBluetoothManager.shouldShowInitialNoDataWarning(
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 5
        ) == false)
        #expect(HeartRateBluetoothManager.shouldShowInitialNoDataWarning(
            hasReceivedDataSinceConnect: false,
            lastSample: now.addingTimeInterval(-4),
            now: now,
            interval: 5
        ) == false)
        #expect(HeartRateBluetoothManager.shouldShowInitialNoDataWarning(
            hasReceivedDataSinceConnect: false,
            lastSample: now.addingTimeInterval(-5),
            now: now,
            interval: 5
        ) == true)
    }

    @Test func noDataSharingHelperUsesInterval() {
        let now = Date()
        #expect(HeartRateBluetoothManager.shouldSendNoDataToSharing(lastSample: nil, now: now, interval: 20) == true)
        #expect(HeartRateBluetoothManager.shouldSendNoDataToSharing(lastSample: now.addingTimeInterval(-19), now: now, interval: 20) == false)
        #expect(HeartRateBluetoothManager.shouldSendNoDataToSharing(lastSample: now.addingTimeInterval(-20), now: now, interval: 20) == true)
    }

    @Test func noDataReconnectHelperUsesInterval() {
        let now = Date()
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(
            hasReceivedDataSinceConnect: false,
            lastSample: nil,
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(
            hasReceivedDataSinceConnect: false,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-9),
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 10
        ) == true)
    }

    @Test func foregroundNoDataReconnectHonorsIntentAndStaleSamples() {
        let now = Date()
        #expect(HeartRateBluetoothManager.shouldAttemptForegroundNoDataReconnect(
            isUserInitiatedDisconnect: true,
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptForegroundNoDataReconnect(
            isUserInitiatedDisconnect: false,
            hasReceivedDataSinceConnect: false,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptForegroundNoDataReconnect(
            isUserInitiatedDisconnect: false,
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-9),
            now: now,
            interval: 10
        ) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptForegroundNoDataReconnect(
            isUserInitiatedDisconnect: false,
            hasReceivedDataSinceConnect: true,
            lastSample: now.addingTimeInterval(-10),
            now: now,
            interval: 10
        ) == true)
    }

    @Test func parsesSensorContactFlagsFromHeartRateMeasurement() {
        let unsupported = HeartRateBluetoothManager.parseHeartRateData(from: Data([0x00, 180]))
        #expect(unsupported.heartRate == 180)
        #expect(unsupported.sensorContactStatus == .unsupported)

        let notDetected = HeartRateBluetoothManager.parseHeartRateData(from: Data([0x04, 162]))
        #expect(notDetected.heartRate == 162)
        #expect(notDetected.sensorContactStatus == .notDetected)

        let detected = HeartRateBluetoothManager.parseHeartRateData(from: Data([0x06, 181]))
        #expect(detected.heartRate == 181)
        #expect(detected.sensorContactStatus == .detected)
    }

    @Test func parserSkipsEnergyExpendedBeforeRRIntervals() {
        let parsed = HeartRateBluetoothManager.parseHeartRateData(
            from: Data([
                0x1e, // contact detected, energy expended, RR intervals, 8-bit HR
                150,
                0x34, 0x12, // energy expended
                0x00, 0x04 // 1024 / 1024s = 1000ms RR interval
            ])
        )

        #expect(parsed.heartRate == 150)
        #expect(parsed.sensorContactStatus == .detected)
        #expect(parsed.hasRRIntervals)
        #expect(parsed.rrIntervals == [1000])
    }

    @Test func freshnessRejectsStaleAndPoorContactReadings() {
        let now = Date()
        #expect(HeartRateBluetoothManager.isFreshHeartRate(
            lastSample: now.addingTimeInterval(-2),
            sensorContactStatus: .unsupported,
            now: now,
            maxAge: 3
        ))
        #expect(HeartRateBluetoothManager.isFreshHeartRate(
            lastSample: now.addingTimeInterval(-4),
            sensorContactStatus: .detected,
            now: now,
            maxAge: 3
        ) == false)
        #expect(HeartRateBluetoothManager.isFreshHeartRate(
            lastSample: now,
            sensorContactStatus: .notDetected,
            now: now,
            maxAge: 3
        ) == false)
    }

    @Test func liveActivityRequiresAReadingOrAnActiveWorkoutTimer() {
        #expect(HeartRateActivityLifecycle.shouldShowActivity(bpm: 120, hasActiveTimer: false))
        #expect(!HeartRateActivityLifecycle.shouldShowActivity(bpm: nil, hasActiveTimer: false))
        #expect(!HeartRateActivityLifecycle.shouldShowActivity(bpm: 0, hasActiveTimer: false))
        #expect(HeartRateActivityLifecycle.shouldShowActivity(bpm: nil, hasActiveTimer: true))
    }
}
