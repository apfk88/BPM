import Testing
@testable import BPM

struct HeartRateZoneAccuracyTests {
    @Test func defaultBoundariesEnterTheHigherZoneAndRetainRestAndAboveMaximum() {
        let config = HeartRateZoneConfig(maxHeartRate: 200)
        #expect(HeartRateZone.zone(for: 0, config: config) == nil)
        #expect(HeartRateZone.zone(for: 50, config: config) == .zone1)
        #expect(HeartRateZone.zone(for: 119, config: config) == .zone1)
        #expect(HeartRateZone.zone(for: 120, config: config) == .zone2)
        #expect(HeartRateZone.zone(for: 140, config: config) == .zone3)
        #expect(HeartRateZone.zone(for: 160, config: config) == .zone4)
        #expect(HeartRateZone.zone(for: 180, config: config) == .zone5)
        #expect(HeartRateZone.zone(for: 210, config: config) == .zone5)
    }

    @Test func customUpperBoundsDoNotSilentlyFillUnconfiguredGaps() {
        var config = HeartRateZoneConfig(maxHeartRate: 200)
        config.zone1Max = 115
        config.zone2Max = 135
        config.zone3Max = 155
        config.zone4Max = 175
        for bpm in [115, 119, 135, 139, 155, 159, 175, 179] {
            #expect(HeartRateZone.zone(for: bpm, config: config) == nil)
        }
        #expect(HeartRateZone.zone(for: 130, config: config) == .zone2)
        #expect(HeartRateZone.zone(for: 150, config: config) == .zone3)
    }
}
