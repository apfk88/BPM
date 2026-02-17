import Testing
@testable import BPM

struct TimerPresetTests {
    @Test func defaultPresetsIncludeEightSetHiitVariants() {
        let defaults = PresetStorage.defaultPresets
        let oneMinuteIntervals = defaults.first(where: { $0.name == "HIIT 60/60 x10" })

        #expect(oneMinuteIntervals?.workDuration == 60)
        #expect(oneMinuteIntervals?.restDuration == 60)
        #expect(oneMinuteIntervals?.numberOfSets == 10)
        #expect(defaults.contains(where: { $0.name == "10x1" }) == false)

        let hiitTwentyTen = defaults.first(where: { $0.name == "HIIT 20/10 x8" })
        #expect(hiitTwentyTen?.workDuration == 20)
        #expect(hiitTwentyTen?.restDuration == 10)
        #expect(hiitTwentyTen?.numberOfSets == 8)

        let hiitTenTwenty = defaults.first(where: { $0.name == "HIIT 10/20 x8" })
        #expect(hiitTenTwenty?.workDuration == 10)
        #expect(hiitTenTwenty?.restDuration == 20)
        #expect(hiitTenTwenty?.numberOfSets == 8)
    }

    @Test func mergingMissingDefaultPresetsAppendsNewDefaultsForExistingUsers() {
        let existingPresets = [
            TimerPreset(name: "Norwegian 4x4", workDuration: 240, restDuration: 180, numberOfSets: 4, includeCooldown: true, playSound: true),
            TimerPreset(name: "Custom Sprint", workDuration: 30, restDuration: 90, numberOfSets: 6, includeCooldown: false, playSound: true)
        ]

        let merged = PresetStorage.mergingMissingDefaultPresets(into: existingPresets)

        #expect(merged.contains(where: { $0.name == "Custom Sprint" }))
        #expect(merged.contains(where: { $0.name == "HIIT 20/10 x8" }))
        #expect(merged.contains(where: { $0.name == "HIIT 10/20 x8" }))
        #expect(merged.contains(where: { $0.name == "HIIT 60/60 x10" }))
    }

    @Test func normalizeLegacyDefaultNamesRenamesLegacyTenByOnePreset() {
        let presets = [
            TimerPreset(name: "10x1", workDuration: 60, restDuration: 60, numberOfSets: 10, includeCooldown: false, playSound: true),
            TimerPreset(name: "10x1", workDuration: 45, restDuration: 15, numberOfSets: 8, includeCooldown: false, playSound: true)
        ]

        let normalized = PresetStorage.normalizeLegacyDefaultNames(in: presets)

        #expect(normalized[0].name == "HIIT 60/60 x10")
        #expect(normalized[1].name == "10x1")
    }
}
