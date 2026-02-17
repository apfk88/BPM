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
    case walking
    case hiking
    case rowing
    case swimming
    case elliptical
    case stairClimbing
    case yoga
    case dance
    case mixedCardio
    case basketball
    case soccer
    case tennis
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
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .rowing:
            return "Rowing"
        case .swimming:
            return "Swimming"
        case .elliptical:
            return "Elliptical"
        case .stairClimbing:
            return "Stair Climbing"
        case .yoga:
            return "Yoga"
        case .dance:
            return "Dance"
        case .mixedCardio:
            return "Mixed Cardio"
        case .basketball:
            return "Basketball"
        case .soccer:
            return "Soccer"
        case .tennis:
            return "Tennis"
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
        case .walking:
            return .walking
        case .hiking:
            return .hiking
        case .rowing:
            return .rowing
        case .swimming:
            return .swimming
        case .elliptical:
            return .elliptical
        case .stairClimbing:
            return .stairClimbing
        case .yoga:
            return .yoga
        case .dance:
            return .cardioDance
        case .mixedCardio:
            return .mixedCardio
        case .basketball:
            return .basketball
        case .soccer:
            return .soccer
        case .tennis:
            return .tennis
        case .other:
            return .other
        }
    }
}

enum HealthKitWorkoutTypeSettings {
    static let quickSelectionCount = 3
    static let quickSelectionOptions: [HealthKitActivityOption] =
        HealthKitActivityOption.allCases.filter { $0 != .other }

    static let defaultQuickSelection: [HealthKitActivityOption] = [
        .functionalStrength,
        .hiit,
        .running
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
        for option in options where quickSelectionOptions.contains(option) && !unique.contains(option) {
            unique.append(option)
        }
        for option in defaultQuickSelection where !unique.contains(option) {
            unique.append(option)
        }
        for option in quickSelectionOptions where !unique.contains(option) {
            unique.append(option)
        }
        return Array(unique.prefix(quickSelectionCount))
    }
}
