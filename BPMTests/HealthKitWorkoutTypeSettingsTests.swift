import Testing
@testable import BPM

struct HealthKitWorkoutTypeSettingsTests {
    @Test func defaultQuickSelectionMatchesRequestedSet() {
        #expect(HealthKitWorkoutTypeSettings.defaultQuickSelection == [.functionalStrength, .hiit, .running, .cycling])
    }

    @Test func emptyStoredValueFallsBackToDefaultSelection() {
        let selection = HealthKitWorkoutTypeSettings.quickSelection(from: "")
        #expect(selection == [.functionalStrength, .hiit, .running, .cycling])
    }

    @Test func parserDeduplicatesAndPadsToFour() {
        let selection = HealthKitWorkoutTypeSettings.quickSelection(
            from: "running,running,other,unknown"
        )
        #expect(selection.count == 4)
        #expect(selection[0] == .running)
        #expect(selection[1] == .other)
        #expect(selection[2] == .functionalStrength)
        #expect(selection[3] == .hiit)
    }

    @Test func encoderAlwaysStoresFourUniqueTypes() {
        let encoded = HealthKitWorkoutTypeSettings.encodedQuickSelection([.cycling, .cycling, .running])
        let decoded = HealthKitWorkoutTypeSettings.quickSelection(from: encoded)

        #expect(decoded.count == 4)
        #expect(Set(decoded).count == 4)
        #expect(decoded[0] == .cycling)
        #expect(decoded[1] == .running)
    }
}
