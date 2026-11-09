//
//  HeartRateZone.swift
//  BPM
//

import Foundation
import SwiftUI

enum HeartRateZoneDefaultsKey {
    static let config = "heartRateZoneConfig"
}

struct HeartRateZoneConfig: Codable, Equatable {
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

/// Edits remain local until Save, including confirmed recalculation and reset.
struct HeartRateZoneDraft: Equatable {
    struct Range: Equatable {
        var minimum: String
        var maximum: String
    }

    var maxHeartRate: String {
        didSet { resetsStoredConfiguration = false }
    }
    var ranges: [Range] {
        didSet { resetsStoredConfiguration = false }
    }
    private(set) var resetsStoredConfiguration = false

    init(config: HeartRateZoneConfig) {
        maxHeartRate = String(config.maxHeartRate)
        ranges = [
            Range(minimum: String(config.zone1Min), maximum: String(config.zone1Max)),
            Range(minimum: String(config.zone2Min), maximum: String(config.zone2Max)),
            Range(minimum: String(config.zone3Min), maximum: String(config.zone3Max)),
            Range(minimum: String(config.zone4Min), maximum: String(config.zone4Max)),
            Range(minimum: String(config.zone5Min), maximum: String(config.zone5Max))
        ]
    }

    var validMaxHeartRate: Int? {
        guard let value = Int(maxHeartRate), (30...250).contains(value) else { return nil }
        return value
    }

    var validationError: String? {
        guard validMaxHeartRate != nil else { return "Enter a max heart rate from 30 to 250 BPM." }
        guard ranges.count == HeartRateZone.allCases.count else { return "Enter all five zone ranges." }

        var previousMaximum: Int?
        for (index, range) in ranges.enumerated() {
            let zone = index + 1
            guard let minimum = Int(range.minimum), let maximum = Int(range.maximum) else {
                return "Enter both values for Zone \(zone)."
            }
            guard (0...300).contains(minimum), (1...300).contains(maximum) else {
                return "Zone \(zone) values must be between 0 and 300 BPM."
            }
            guard minimum < maximum else { return "Zone \(zone) minimum must be below its maximum." }
            if let previousMaximum, minimum < previousMaximum {
                return "Zone \(zone) overlaps Zone \(index). Raise its minimum or lower the previous maximum."
            }
            previousMaximum = maximum
        }
        return nil
    }

    var configuration: HeartRateZoneConfig? {
        guard validationError == nil, let maxHeartRate = validMaxHeartRate else { return nil }
        let values = ranges.compactMap { range -> (Int, Int)? in
            guard let minimum = Int(range.minimum), let maximum = Int(range.maximum) else { return nil }
            return (minimum, maximum)
        }
        guard values.count == 5 else { return nil }
        var config = HeartRateZoneConfig(maxHeartRate: maxHeartRate)
        (config.zone1Min, config.zone1Max) = values[0]
        (config.zone2Min, config.zone2Max) = values[1]
        (config.zone3Min, config.zone3Max) = values[2]
        (config.zone4Min, config.zone4Max) = values[3]
        (config.zone5Min, config.zone5Max) = values[4]
        return config
    }

    mutating func recalculateZones() {
        guard let maxHeartRate = validMaxHeartRate else { return }
        self = HeartRateZoneDraft(config: HeartRateZoneConfig(maxHeartRate: maxHeartRate))
    }

    mutating func resetToDefaults() {
        self = HeartRateZoneDraft(config: HeartRateZoneConfig(maxHeartRate: 190))
        resetsStoredConfiguration = true
    }

    @discardableResult
    func save(to storage: HeartRateZoneStorage) -> Bool {
        guard let configuration else { return false }
        storage.config = resetsStoredConfiguration ? nil : configuration
        return true
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
        case .zone1: return .white
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
        } else if heartRate >= config.zone4Min && heartRate < config.zone4Max {
            return .zone4
        } else if heartRate >= config.zone3Min && heartRate < config.zone3Max {
            return .zone3
        } else if heartRate >= config.zone2Min && heartRate < config.zone2Max {
            return .zone2
        } else if heartRate < config.zone1Max {
            // Retain resting readings below Z1's nominal lower threshold.
            return .zone1
        }
        // Custom ranges may contain gaps. Do not silently extend a zone beyond
        // the upper bound the user entered. Shared boundaries enter the higher zone.
        return nil
    }
}

class HeartRateZoneStorage: ObservableObject {
    static let shared = HeartRateZoneStorage()

    private let storageKey = HeartRateZoneDefaultsKey.config
    private let defaultMaxHeartRate = 190
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var lastLoadedData: Data?
    private var defaultsObserver: NSObjectProtocol?
    private var isLoadingDefaults = false

    @Published var config: HeartRateZoneConfig? {
        didSet {
            guard !isLoadingDefaults, config != oldValue else { return }
            save()
        }
    }

    var isConfigured: Bool {
        config != nil
    }

    var effectiveConfig: HeartRateZoneConfig {
        config ?? HeartRateZoneConfig(maxHeartRate: defaultMaxHeartRate)
    }

    init(userDefaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        load()
        defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    deinit {
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
    }

    private func load() {
        let data = userDefaults.data(forKey: storageKey)
        lastLoadedData = data
        let loaded = data.flatMap { try? JSONDecoder().decode(HeartRateZoneConfig.self, from: $0) }
        guard loaded != config else { return }
        // A defaults notification reads external state; it must never write the
        // same value back and synchronously enter this observer again.
        isLoadingDefaults = true
        defer { isLoadingDefaults = false }
        config = loaded
    }

    private func reloadIfChanged() {
        let data = userDefaults.data(forKey: storageKey)
        guard data != lastLoadedData else { return }
        load()
    }

    private func save() {
        if let config = config {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(config) else { return }
            // Update the cache before writing because UserDefaults can deliver
            // its change notification synchronously from inside set/remove.
            lastLoadedData = data
            guard userDefaults.data(forKey: storageKey) != data else { return }
            userDefaults.set(data, forKey: storageKey)
        } else if config == nil {
            lastLoadedData = nil
            guard userDefaults.object(forKey: storageKey) != nil else { return }
            userDefaults.removeObject(forKey: storageKey)
        }
    }

    func currentZone(for heartRate: Int?) -> HeartRateZone? {
        guard let heartRate = heartRate else { return nil }
        return HeartRateZone.zone(for: heartRate, config: effectiveConfig)
    }
}
