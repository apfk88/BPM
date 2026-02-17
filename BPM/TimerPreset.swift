//
//  TimerPreset.swift
//  BPM
//
//  Created for timer preset feature
//

import Foundation

struct TimerPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var workDuration: TimeInterval // Duration of each work set in seconds
    var restDuration: TimeInterval // Duration of each rest set in seconds
    var numberOfSets: Int
    var includeCooldown: Bool // Whether to include 2-minute cooldown at the end
    var playSound: Bool // Whether to play a sound at the end of each round

    init(id: UUID = UUID(), name: String = "", workDuration: TimeInterval = 60, restDuration: TimeInterval = 60, numberOfSets: Int = 5, includeCooldown: Bool = true, playSound: Bool = true) {
        self.id = id
        self.name = name
        self.workDuration = workDuration
        self.restDuration = restDuration
        self.numberOfSets = numberOfSets
        self.includeCooldown = includeCooldown
        self.playSound = playSound
    }

    var totalDuration: TimeInterval {
        let workTotal = workDuration * Double(numberOfSets)
        let restTotal = restDuration * Double(numberOfSets - 1) // Rest between sets, not after last
        let cooldownTotal = includeCooldown ? 120.0 : 0.0
        return workTotal + restTotal + cooldownTotal
    }

    var formattedTotalDuration: String {
        let totalSeconds = Int(totalDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }
}

final class PresetStorage: ObservableObject {
    static let shared = PresetStorage()
    private static let renamedDefaultPresetsByLegacyName = [
        "10x1": "HIIT 60/60 x10"
    ]
    static let defaultPresets: [TimerPreset] = [
        TimerPreset(
            name: "Norwegian 4x4",
            workDuration: 240,  // 4 minutes
            restDuration: 180,  // 3 minutes
            numberOfSets: 4,
            includeCooldown: true,
            playSound: true
        ),
        TimerPreset(
            name: "HIIT 60/60 x10",
            workDuration: 60,   // 1 minute
            restDuration: 60,   // 1 minute
            numberOfSets: 10,
            includeCooldown: false,
            playSound: true
        ),
        TimerPreset(
            name: "HIIT 20/10 x8",
            workDuration: 20,
            restDuration: 10,
            numberOfSets: 8,
            includeCooldown: false,
            playSound: true
        ),
        TimerPreset(
            name: "HIIT 10/20 x8",
            workDuration: 10,
            restDuration: 20,
            numberOfSets: 8,
            includeCooldown: false,
            playSound: true
        )
    ]

    @Published var presets: [TimerPreset] = []

    private let userDefaultsKey = "timerPresets"
    private let seededKey = "timerPresetsSeeded"

    private init() {
        loadPresets()
    }

    func savePreset(_ preset: TimerPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persistPresets()
    }

    func deletePreset(_ preset: TimerPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func loadPresets() {
        // Check if we have existing presets
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([TimerPreset].self, from: data) {
            let merged = Self.mergingMissingDefaultPresets(into: decoded)
            presets = merged
            if merged != decoded {
                persistPresets()
            }
            return
        }

        // No saved presets - seed defaults on first launch only
        if !UserDefaults.standard.bool(forKey: seededKey) {
            seedDefaultPresets()
        }
    }

    private func seedDefaultPresets() {
        presets = Self.defaultPresets
        persistPresets()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static func mergingMissingDefaultPresets(into existingPresets: [TimerPreset]) -> [TimerPreset] {
        var mergedPresets = normalizeLegacyDefaultNames(in: existingPresets)
        let existingNames = Set(mergedPresets.map(\.name))
        for preset in defaultPresets where !existingNames.contains(preset.name) {
            mergedPresets.append(preset)
        }
        return mergedPresets
    }

    static func normalizeLegacyDefaultNames(in presets: [TimerPreset]) -> [TimerPreset] {
        presets.map { preset in
            guard let renamedPresetName = renamedDefaultPresetsByLegacyName[preset.name],
                  let renamedDefault = defaultPresets.first(where: { $0.name == renamedPresetName }),
                  preset.workDuration == renamedDefault.workDuration,
                  preset.restDuration == renamedDefault.restDuration,
                  preset.numberOfSets == renamedDefault.numberOfSets,
                  preset.includeCooldown == renamedDefault.includeCooldown,
                  preset.playSound == renamedDefault.playSound else {
                return preset
            }

            var renamedPreset = preset
            renamedPreset.name = renamedPresetName
            return renamedPreset
        }
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
