//
//  HeartRateAlertStateTests.swift
//  BPMTests
//
//  Created by Codex.
//

import Foundation
import Testing
@testable import BPM

struct HeartRateAlertStateTests {
    @Test func bpmAlertFiresOnThresholdCrossings() {
        var state = HeartRateAlertState()
        let settings = HeartRateAlertSettings(
            isHeartRateAlertEnabled: true,
            heartRateThreshold: 150,
            isZoneAlertEnabled: false,
            selectedZones: []
        )
        let zoneFor: (Int) -> HeartRateZone? = { _ in nil }

        var decision = state.handle(heartRate: 140, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playBpmAscending == false)
        #expect(decision.playBpmDescending == false)

        decision = state.handle(heartRate: 151, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playBpmAscending == true)
        #expect(decision.playBpmDescending == false)

        decision = state.handle(heartRate: 152, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playBpmAscending == false)
        #expect(decision.playBpmDescending == false)

        decision = state.handle(heartRate: 149, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playBpmAscending == false)
        #expect(decision.playBpmDescending == true)
    }

    @Test func zoneAlertFiresWhenEnteringSelectedZones() {
        var state = HeartRateAlertState()
        let config = HeartRateZoneConfig(maxHeartRate: 190)
        let settings = HeartRateAlertSettings(
            isHeartRateAlertEnabled: false,
            heartRateThreshold: 160,
            isZoneAlertEnabled: true,
            selectedZones: [.zone3, .zone4]
        )
        let zoneFor: (Int) -> HeartRateZone? = { HeartRateZone.zone(for: $0, config: config) }

        var decision = state.handle(heartRate: config.zone2Min, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playZoneCount == nil)

        decision = state.handle(heartRate: config.zone3Min, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playZoneCount == HeartRateZone.zone3.rawValue)

        decision = state.handle(heartRate: config.zone3Min + 1, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playZoneCount == nil)

        decision = state.handle(heartRate: config.zone4Min, settings: settings, zoneForHeartRate: zoneFor)
        #expect(decision.playZoneCount == HeartRateZone.zone4.rawValue)
    }
}
