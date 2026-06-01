//
//  HeartRateBluetoothManagerTests.swift
//  BPMTests
//
//  Created by Codex.
//

import Foundation
import Testing
@testable import BPM

struct HeartRateBluetoothManagerTests {
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
}
