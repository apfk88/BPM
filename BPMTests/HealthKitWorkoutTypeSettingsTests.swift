import Testing
@testable import BPM

struct HealthKitWorkoutTypeSettingsTests {
    @Test func defaultQuickSelectionMatchesRequestedSet() {
        #expect(HealthKitWorkoutTypeSettings.defaultQuickSelection == [.functionalStrength, .hiit, .running])
    }

    @Test func emptyStoredValueFallsBackToDefaultSelection() {
        let selection = HealthKitWorkoutTypeSettings.quickSelection(from: "")
        #expect(selection == [.functionalStrength, .hiit, .running])
    }

    @Test func parserIgnoresOtherAndPadsToThree() {
        let selection = HealthKitWorkoutTypeSettings.quickSelection(
            from: "running,running,other,unknown"
        )
        #expect(selection.count == 3)
        #expect(selection[0] == .running)
        #expect(selection[1] == .functionalStrength)
        #expect(selection[2] == .hiit)
        #expect(!selection.contains(.other))
    }

    @Test func encoderAlwaysStoresThreeUniqueTypes() {
        let encoded = HealthKitWorkoutTypeSettings.encodedQuickSelection([.other, .cycling, .cycling, .running])
        let decoded = HealthKitWorkoutTypeSettings.quickSelection(from: encoded)

        #expect(decoded.count == 3)
        #expect(Set(decoded).count == 3)
        #expect(decoded[0] == .cycling)
        #expect(decoded[1] == .running)
        #expect(decoded[2] == .functionalStrength)
        #expect(!decoded.contains(.other))
    }
}
