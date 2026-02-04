//
//  HeartRateAlerts.swift
//  BPM
//

import Foundation

struct HeartRateAlertSettings {
    let isHeartRateAlertEnabled: Bool
    let heartRateThreshold: Int
    let isZoneAlertEnabled: Bool
    let selectedZones: Set<HeartRateZone>

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> HeartRateAlertSettings {
        let heartRateEnabled = defaults.bool(forKey: "BPM_Alert_HeartRateEnabled")
        let heartRateThreshold = defaults.object(forKey: "BPM_Alert_HeartRateThreshold") as? Int ?? 160
        let zoneEnabled = defaults.bool(forKey: "BPM_Alert_ZoneEnabled")
        let zoneSelections = defaults.string(forKey: "BPM_Alert_Zones") ?? "3,4,5"
        return HeartRateAlertSettings(
            isHeartRateAlertEnabled: heartRateEnabled,
            heartRateThreshold: heartRateThreshold,
            isZoneAlertEnabled: zoneEnabled,
            selectedZones: selectedZones(from: zoneSelections)
        )
    }

    static func selectedZones(from selections: String) -> Set<HeartRateZone> {
        let ids = selections
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let zones = HeartRateZone.allCases.filter { ids.contains($0.rawValue) }
        return Set(zones)
    }
}

struct HeartRateAlertDecision {
    var playBpmAscending = false
    var playBpmDescending = false
    var playZoneCount: Int?

    var shouldPlay: Bool {
        playBpmAscending || playBpmDescending || playZoneCount != nil
    }
}

struct HeartRateAlertState {
    private(set) var wasAboveHeartRateThreshold = false
    private(set) var lastZoneSeen: HeartRateZone?

    mutating func reset() {
        wasAboveHeartRateThreshold = false
        lastZoneSeen = nil
    }

    mutating func handle(
        heartRate: Int?,
        settings: HeartRateAlertSettings,
        zoneForHeartRate: (Int) -> HeartRateZone?
    ) -> HeartRateAlertDecision {
        guard let heartRate = heartRate, heartRate > 0 else {
            reset()
            return HeartRateAlertDecision()
        }

        var decision = HeartRateAlertDecision()

        if settings.isHeartRateAlertEnabled {
            let isAbove = heartRate >= settings.heartRateThreshold
            if isAbove && !wasAboveHeartRateThreshold {
                decision.playBpmAscending = true
            } else if !isAbove && wasAboveHeartRateThreshold {
                decision.playBpmDescending = true
            }
            wasAboveHeartRateThreshold = isAbove
        } else {
            wasAboveHeartRateThreshold = false
        }

        if settings.isZoneAlertEnabled {
            let zone = zoneForHeartRate(heartRate)
            if zone != lastZoneSeen {
                lastZoneSeen = zone
                if let zone = zone, settings.selectedZones.contains(zone) {
                    decision.playZoneCount = zone.rawValue
                }
            }
        } else {
            lastZoneSeen = nil
        }

        return decision
    }
}
