import Foundation
import HealthKit

enum HealthKitWorkoutTypeDefaultsKey {
    static let quickSelection = "BPM_HealthKit_QuickWorkoutTypes"
}

enum HealthKitActivityOption: String, CaseIterable, Identifiable {
    case functionalStrength
    case hiit
    case traditionalStrength
    case running
    case cycling
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .functionalStrength:
            return "Functional Strength"
        case .hiit:
            return "HIIT"
        case .traditionalStrength:
            return "Traditional Strength"
        case .running:
            return "Running"
        case .cycling:
            return "Cycling"
        case .other:
            return "Other"
        }
    }

    var workoutType: HKWorkoutActivityType {
        switch self {
        case .functionalStrength:
            return .functionalStrengthTraining
        case .hiit:
            return .highIntensityIntervalTraining
        case .traditionalStrength:
            return .traditionalStrengthTraining
        case .running:
            return .running
        case .cycling:
            return .cycling
        case .other:
            return .other
        }
    }
}

enum HealthKitWorkoutTypeSettings {
    static let quickSelectionCount = 4
    static let defaultQuickSelection: [HealthKitActivityOption] = [
        .functionalStrength,
        .hiit,
        .running,
        .cycling
    ]

    static func defaultQuickSelectionRawValue() -> String {
        encodedQuickSelection(defaultQuickSelection)
    }

    static func quickSelection(from rawValue: String) -> [HealthKitActivityOption] {
        let parsed = rawValue
            .split(separator: ",")
            .compactMap { HealthKitActivityOption(rawValue: String($0)) }
        return normalizedQuickSelection(parsed)
    }

    static func encodedQuickSelection(_ options: [HealthKitActivityOption]) -> String {
        normalizedQuickSelection(options)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func normalizedQuickSelection(_ options: [HealthKitActivityOption]) -> [HealthKitActivityOption] {
        var unique: [HealthKitActivityOption] = []
        for option in options where !unique.contains(option) {
            unique.append(option)
        }
        for option in defaultQuickSelection where !unique.contains(option) {
            unique.append(option)
        }
        for option in HealthKitActivityOption.allCases where !unique.contains(option) {
            unique.append(option)
        }
        return Array(unique.prefix(quickSelectionCount))
    }
}
