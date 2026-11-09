import SwiftUI

enum CalorieSetupDefaultsKey {
    static let promptDismissed = "BPM_Calories_SetupPromptDismissed"
    static let promptEligible = "BPM_Calories_SetupPromptEligible"
    static let weightUnit = "BPM_Calories_WeightUnit"
}

/// Observes the same stored inputs as the editor so setup indicators update immediately.
@propertyWrapper
struct CalorieProfileStorage: DynamicProperty {
    @AppStorage(CaloriesDefaultsKey.weightKg) private var weight = ""
    @AppStorage(CaloriesDefaultsKey.ageYears) private var age = ""
    @AppStorage(CaloriesDefaultsKey.sexAtBirth) private var sex = ""
    @AppStorage(CaloriesDefaultsKey.restHrBpm) private var restingHR = ""
    @AppStorage(CaloriesDefaultsKey.maxHrBpm) private var maxHR = ""
    @AppStorage(CaloriesDefaultsKey.vo2Max) private var vo2Max = ""
    @AppStorage(CaloriesDefaultsKey.rmrKcalPerDay) private var rmr = ""
    @AppStorage(CaloriesDefaultsKey.medsAffectingHr) private var medication = false

    var wrappedValue: UserEnergyProfile {
        UserEnergyProfile(
            weightKg: Double(weight), ageYears: Int(age), sexAtBirth: SexAtBirth(rawValue: sex),
            heightCm: nil, restHeartRate: Int(restingHR), maxHeartRate: Int(maxHR),
            vo2Max: Double(vo2Max), rmrKcalPerDay: Double(rmr), bodyFatPercent: nil,
            medsAffectingHr: medication
        )
    }
}

extension UserEnergyProfile {
    var setupColor: Color {
        switch setupState {
        case .notStarted, .incomplete, .needsReview: .orange
        case .unavailable: .secondary
        case .basic: .blue
        case .personalized, .complete: .green
        }
    }

    var setupSymbol: String {
        switch setupState {
        case .notStarted, .incomplete, .needsReview: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle"
        case .basic: "checkmark.circle"
        case .personalized: "checkmark.circle.fill"
        case .complete: "checkmark.seal.fill"
        }
    }
}

struct CalorieSetupBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 13, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, .orange)
            .background(.black, in: Circle())
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct CalorieSetupSummary: View {
    let profile: UserEnergyProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(profile.setupTitle, systemImage: profile.setupSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(profile.setupColor)
            if profile.needsCalorieSetupAttention || profile.setupState == .unavailable {
                Text(profile.setupDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calorie setup")
        .accessibilityValue(profile.setupTitle)
        .accessibilityHint(profile.setupDetail)
        .accessibilityIdentifier("calorieSetupStatus")
    }
}

struct CalorieSetupPrompt: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onSetUp: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Set up calorie counting", systemImage: "flame")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Add your weight, age and sex to estimate workout calories.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let actionsLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            actionsLayout {
                Button("Set up calories", action: onSetUp)
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setUpCalories")
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Button("Not now", action: onSkip)
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dismissCalorieSetupPrompt")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
