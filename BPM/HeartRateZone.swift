//
//  HeartRateZone.swift
//  BPM
//

import Foundation
import SwiftUI

struct HeartRateZoneConfig: Codable {
    var maxHeartRate: Int
    var zone1Min: Int
    var zone1Max: Int
    var zone2Min: Int
    var zone2Max: Int
    var zone3Min: Int
    var zone3Max: Int
    var zone4Min: Int
    var zone4Max: Int
    var zone5Min: Int
    var zone5Max: Int

    init(maxHeartRate: Int) {
        self.maxHeartRate = maxHeartRate
        // Default zone calculations based on HRmax percentages
        self.zone1Min = Int(Double(maxHeartRate) * 0.50)
        self.zone1Max = Int(Double(maxHeartRate) * 0.60)
        self.zone2Min = Int(Double(maxHeartRate) * 0.60)
        self.zone2Max = Int(Double(maxHeartRate) * 0.70)
        self.zone3Min = Int(Double(maxHeartRate) * 0.70)
        self.zone3Max = Int(Double(maxHeartRate) * 0.80)
        self.zone4Min = Int(Double(maxHeartRate) * 0.80)
        self.zone4Max = Int(Double(maxHeartRate) * 0.90)
        self.zone5Min = Int(Double(maxHeartRate) * 0.90)
        self.zone5Max = maxHeartRate
    }

    mutating func recalculateFromMaxHR() {
        zone1Min = Int(Double(maxHeartRate) * 0.50)
        zone1Max = Int(Double(maxHeartRate) * 0.60)
        zone2Min = Int(Double(maxHeartRate) * 0.60)
        zone2Max = Int(Double(maxHeartRate) * 0.70)
        zone3Min = Int(Double(maxHeartRate) * 0.70)
        zone3Max = Int(Double(maxHeartRate) * 0.80)
        zone4Min = Int(Double(maxHeartRate) * 0.80)
        zone4Max = Int(Double(maxHeartRate) * 0.90)
        zone5Min = Int(Double(maxHeartRate) * 0.90)
        zone5Max = maxHeartRate
    }
}

enum HeartRateZone: Int, CaseIterable {
    case zone1 = 1
    case zone2 = 2
    case zone3 = 3
    case zone4 = 4
    case zone5 = 5

    var displayName: String {
        "Z\(rawValue)"
    }

    var fullName: String {
        switch self {
        case .zone1: return "Zone 1 - Recovery"
        case .zone2: return "Zone 2 - Endurance"
        case .zone3: return "Zone 3 - Tempo"
        case .zone4: return "Zone 4 - Threshold"
        case .zone5: return "Zone 5 - Max Effort"
        }
    }

    var color: Color {
        switch self {
        case .zone1: return .gray
        case .zone2: return .green
        case .zone3: return .orange
        case .zone4: return .purple
        case .zone5: return .red
        }
    }

    var percentageRange: String {
        switch self {
        case .zone1: return "50-60%"
        case .zone2: return "60-70%"
        case .zone3: return "70-80%"
        case .zone4: return "80-90%"
        case .zone5: return "90-100%"
        }
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    var zoneInfo: ZoneInfo {
        switch self {
        case .zone1: return .zone1
        case .zone2: return .zone2
        case .zone3: return .zone3
        case .zone4: return .zone4
        case .zone5: return .zone5
        }
    }
    #endif

    static func zone(for heartRate: Int, config: HeartRateZoneConfig) -> HeartRateZone? {
        guard heartRate > 0 else { return nil }

        if heartRate >= config.zone5Min {
            return .zone5
        } else if heartRate >= config.zone4Min {
            return .zone4
        } else if heartRate >= config.zone3Min {
            return .zone3
        } else if heartRate >= config.zone2Min {
            return .zone2
        } else {
            // Any positive heart rate below zone2 is considered zone1 (recovery/rest)
            return .zone1
        }
    }
}

class HeartRateZoneStorage: ObservableObject {
    static let shared = HeartRateZoneStorage()

    private let storageKey = "heartRateZoneConfig"
    private let defaultMaxHeartRate = 190

    @Published var config: HeartRateZoneConfig? {
        didSet {
            save()
        }
    }

    var isConfigured: Bool {
        config != nil
    }

    var effectiveConfig: HeartRateZoneConfig {
        config ?? HeartRateZoneConfig(maxHeartRate: defaultMaxHeartRate)
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode(HeartRateZoneConfig.self, from: data) else {
            config = nil
            return
        }
        config = loaded
    }

    private func save() {
        if let config = config,
           let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else if config == nil {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    func currentZone(for heartRate: Int?) -> HeartRateZone? {
        guard let heartRate = heartRate else { return nil }
        return HeartRateZone.zone(for: heartRate, config: effectiveConfig)
    }
}
