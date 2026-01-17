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
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(lastSample: nil, now: now, interval: 10) == true)
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(lastSample: now.addingTimeInterval(-9), now: now, interval: 10) == false)
        #expect(HeartRateBluetoothManager.shouldAttemptNoDataReconnect(lastSample: now.addingTimeInterval(-10), now: now, interval: 10) == true)
    }
}
