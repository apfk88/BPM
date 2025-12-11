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

    init(id: UUID = UUID(), name: String = "", workDuration: TimeInterval = 60, restDuration: TimeInterval = 60, numberOfSets: Int = 5, includeCooldown: Bool = true) {
        self.id = id
        self.name = name
        self.workDuration = workDuration
        self.restDuration = restDuration
        self.numberOfSets = numberOfSets
        self.includeCooldown = includeCooldown
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

    @Published var presets: [TimerPreset] = []

    private let userDefaultsKey = "timerPresets"

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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([TimerPreset].self, from: data) else {
            return
        }
        presets = decoded
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
