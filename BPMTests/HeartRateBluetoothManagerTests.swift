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
}
