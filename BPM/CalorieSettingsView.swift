import SwiftUI

struct CalorieSettingsView: View {
    @AppStorage(CaloriesDefaultsKey.weightKg) private var weightKgText = ""
    @AppStorage(CaloriesDefaultsKey.ageYears) private var ageYearsText = ""
    @AppStorage(CaloriesDefaultsKey.sexAtBirth) private var sexAtBirthRaw = ""
    @AppStorage(CaloriesDefaultsKey.heightCm) private var heightCmText = ""
    @AppStorage(CaloriesDefaultsKey.restHrBpm) private var restHrText = ""
    @AppStorage(CaloriesDefaultsKey.maxHrBpm) private var maxHrText = ""
    @AppStorage(CaloriesDefaultsKey.vo2Max) private var vo2MaxText = ""
    @AppStorage(CaloriesDefaultsKey.rmrKcalPerDay) private var rmrText = ""
    @AppStorage(CaloriesDefaultsKey.bodyFatPercent) private var bodyFatText = ""
    @AppStorage(CaloriesDefaultsKey.medsAffectingHr) private var medsAffectingHr = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var editedFields: Set<CalorieAnalytics.Field> = []
    @State private var showConfidenceWhy = false
    @State private var heightFeetText = ""
    @State private var heightInchesText = ""
    @State private var weightLbText = ""
    @FocusState private var isWeightFocused: Bool

    private var sexAtBirth: SexAtBirth? {
        SexAtBirth(rawValue: sexAtBirthRaw)
    }

    private var profile: UserEnergyProfile {
        UserEnergyProfile(
            weightKg: Double(weightKgText),
            ageYears: Int(ageYearsText),
            sexAtBirth: sexAtBirth,
            heightCm: Double(heightCmText),
            restHeartRate: Int(restHrText),
            maxHeartRate: Int(maxHrText),
            vo2Max: Double(vo2MaxText),
            rmrKcalPerDay: Double(rmrText),
            bodyFatPercent: Double(bodyFatText),
            medsAffectingHr: medsAffectingHr
        )
    }

    var body: some View {
        List {
            Section(footer: Text("Calories are estimates from heart rate, not measured energy expenditure. Accuracy varies by person and activity.")) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(statusColor)
                }

                HStack {
                    Text("Accuracy")
                    Spacer()
                    Button(confidenceLabel) {
                        showConfidenceWhy = true
                    }
                    .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text("Required"),
                footer: requiredFooterText
            ) {
                weightRow
                numericRow(label: "Age", text: tracked($ageYearsText, field: .age), unit: "yrs", allowsDecimal: false)
                sexRow
                heightRow
            }

            Section(
                header: Text("Advanced"),
                footer: Text("Resting HR and VO2max enable the oxygen-use model. Max HR personalizes that model; RMR sets resting energy. Height and body fat do not enter either calculation.")
            ) {
                numericRow(label: "Resting HR", text: tracked($restHrText, field: .restingHR), unit: "bpm", allowsDecimal: false)
                numericRow(
                    label: "Max HR",
                    text: numericBinding(tracked($maxHrText, field: .maxHR), allowsDecimal: false, maxDigits: 3),
                    unit: "bpm",
                    allowsDecimal: false
                )
                numericRow(label: "VO2max", text: tracked($vo2MaxText, field: .vo2Max), unit: "ml/kg/min", allowsDecimal: true)
                numericRow(label: "RMR", text: tracked($rmrText, field: .rmr), unit: "kcal/day", allowsDecimal: true)
                numericRow(label: "Body Fat", text: tracked($bodyFatText, field: .bodyFat), unit: "%", allowsDecimal: true)
                Toggle("Medication affects heart rate", isOn: $medsAffectingHr)
            }
        }
        .navigationTitle("Calorie Settings")
        .analyticsScreen(.calories)
        .sheet(isPresented: $showConfidenceWhy) {
            ConfidenceWhySheet(
                confidenceLabel: confidenceLabel,
                methodLabel: methodLabel,
                reasons: confidenceReasons
            )
        }
        .onAppear {
            hydrateHeightFields()
            hydrateWeightField()
        }
        .onDisappear {
            commitWeightToKg()
            flushAnalytics()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { flushAnalytics() }
        }
        .onChange(of: heightFeetText) { _, _ in
            updateHeightCmFromImperial()
        }
        .onChange(of: heightInchesText) { _, _ in
            updateHeightCmFromImperial()
        }
        .onChange(of: weightLbText) { _, _ in
            updateWeightKgFromImperial()
        }
        .onChange(of: isWeightFocused) { _, isFocused in
            if !isFocused {
                commitWeightToKg()
            }
        }
    }

    private func tracked(_ binding: Binding<String>, field: CalorieAnalytics.Field) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { value in
            guard value != binding.wrappedValue else { return }
            binding.wrappedValue = value
            editedFields.insert(field)
        })
    }

    private func flushAnalytics() {
        // One event per edited field when leaving/backgrounding, not per keystroke.
        for field in CalorieAnalytics.Field.allCases where editedFields.contains(field) {
            CalorieAnalytics.edited(field)
        }
        editedFields.removeAll()
        AppAnalytics.signal(.calorieConfiguration, parameters: CalorieAnalytics.configuration())
        AppAnalytics.recordConfiguration()
    }

    private var statusText: String {
        profile.hasRequiredInputs ? "Enabled" : "Needs info"
    }

    private var statusColor: Color {
        profile.hasRequiredInputs ? .green : .orange
    }

    private var requiredFooterText: Text {
        if profile.hasRequiredInputs {
            return Text("Required fields are complete.")
        }
        let missing = profile.missingRequiredFields.joined(separator: ", ")
        return Text("Check: \(missing). Calories are disabled until corrected.")
    }

    private var confidenceLabel: String {
        CaloriesEstimator.confidenceLabel(for: confidenceValue)
    }

    private var confidenceValue: Double {
        CaloriesEstimator.confidence(for: profile, method: CaloriesEstimator.preferredMethod(for: profile))
    }

    private var methodLabel: String {
        switch CaloriesEstimator.preferredMethod(for: profile) {
        case .hrrVO2:
            return "HRR -> VO2"
        case .hrRegression:
            return "HR Regression"
        case .hrRegressionUnsexed:
            return "HR Regression (unsexed)"
        }
    }

    private var confidenceReasons: [String] {
        var reasons = [
            "Neither model has been validated for your individual calorie burn.",
            "Heart rate can rise from heat, stress, or medication without a matching rise in energy use.",
            "The regression was developed during steady running and cycling in adults aged 18–45. Resting periods, strength training, and intervals can be less accurate.",
            "Sensor gaps are excluded; displayed calories cover only usable heart-rate time."
        ]
        if CaloriesEstimator.preferredMethod(for: profile) == .hrrVO2 {
            reasons.append(profile.maxHeartRate == nil
                           ? "Maximum HR is estimated from age."
                           : "Maximum HR uses your entered value.")
        }
        reasons.append(profile.rmrKcalPerDay == nil
                       ? "Resting energy assumes 3.5 ml oxygen/kg/min."
                       : "Resting energy uses your entered RMR.")
        return reasons
    }

    private var sexRow: some View {
        Picker("Sex", selection: tracked($sexAtBirthRaw, field: .sex)) {
            Text("Choose").tag("")
            Text(SexAtBirth.male.displayName).tag(SexAtBirth.male.rawValue)
            Text(SexAtBirth.female.displayName).tag(SexAtBirth.female.rawValue)
        }
        .pickerStyle(.segmented)
    }

    private var heightRow: some View {
        HStack {
            Text("Height")
            Spacer()
            TextField("", text: numericBinding(tracked($heightFeetText, field: .height), allowsDecimal: false))
                .accessibilityLabel("Height feet")
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
                .textFieldStyle(.roundedBorder)
            Text("ft")
                .foregroundColor(.secondary)
            TextField("", text: numericBinding(tracked($heightInchesText, field: .height), allowsDecimal: true))
                .accessibilityLabel("Height inches")
                .keyboardType(.decimalPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .textFieldStyle(.roundedBorder)
            Text("in")
                .foregroundColor(.secondary)
        }
    }

    private func numericRow(label: String, text: Binding<String>, unit: String, allowsDecimal: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: numericBinding(text, allowsDecimal: allowsDecimal))
                .accessibilityLabel(label)
                .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            Text(unit)
                .foregroundColor(.secondary)
        }
    }

    private var weightRow: some View {
        HStack {
            Text("Weight")
            Spacer()
            TextField("", text: numericBinding(tracked($weightLbText, field: .weight), allowsDecimal: true))
                .accessibilityLabel("Weight")
                .keyboardType(.decimalPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
                .focused($isWeightFocused)
            Text("lb")
                .foregroundColor(.secondary)
        }
    }

    private func hydrateHeightFields() {
        guard let cm = Double(heightCmText), cm.isFinite, (1...300).contains(cm) else { return }
        let totalInches = cm / 2.54
        let feet = Int(totalInches / 12.0)
        let inches = totalInches - Double(feet * 12)
        heightFeetText = String(feet)
        heightInchesText = formatDecimal(inches)
    }

    private func updateHeightCmFromImperial() {
        guard editedFields.contains(.height) else { return }
        guard let feet = Double(heightFeetText), feet >= 0 else {
            heightCmText = ""
            return
        }
        guard let inches = Double(heightInchesText), inches >= 0 else {
            heightCmText = ""
            return
        }
        let totalInches = feet * 12.0 + inches
        let cm = totalInches * 2.54
        heightCmText = formatDecimal(cm)
    }

    private func hydrateWeightField() {
        guard let kg = Double(weightKgText), kg.isFinite, (1...1000).contains(kg) else { return }
        let lb = kg * 2.2046226218
        weightLbText = formatDecimal(lb)
    }

    private func commitWeightToKg() {
        guard editedFields.contains(.weight) else { return }
        updateWeightKgFromImperial()
        guard let lb = Double(weightLbText), lb > 0 else {
            return
        }
        weightLbText = formatDecimal(lb)
    }

    private func updateWeightKgFromImperial() {
        guard editedFields.contains(.weight) else { return }
        guard let lb = Double(weightLbText), lb > 0 else {
            weightKgText = ""
            return
        }
        let kg = lb / 2.2046226218
        weightKgText = formatDecimal(kg, maximumFractionDigits: 2)
    }

    private func formatDecimal(_ value: Double, maximumFractionDigits: Int = 1, minimumFractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    private func numericBinding(_ binding: Binding<String>, allowsDecimal: Bool, maxDigits: Int? = nil) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                let filtered = newValue.filter { char in
                    if char.isNumber { return true }
                    if allowsDecimal, char == "." { return true }
                    return false
                }
                if allowsDecimal {
                    var hasDecimal = false
                    let compacted = filtered.filter { char in
                        if char == "." {
                            if hasDecimal { return false }
                            hasDecimal = true
                            return true
                        }
                        return true
                    }
                    binding.wrappedValue = String(compacted)
                } else {
                    if let maxDigits {
                        binding.wrappedValue = String(filtered.prefix(maxDigits))
                    } else {
                        binding.wrappedValue = String(filtered)
                    }
                }
            }
        )
    }
}

private struct ConfidenceWhySheet: View {
    let confidenceLabel: String
    let methodLabel: String
    let reasons: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Accuracy")
                        Spacer()
                        Text(confidenceLabel)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Method")
                        Spacer()
                        Text(methodLabel)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Why")) {
                    ForEach(reasons, id: \.self) { reason in
                        Text(reason)
                    }
                }
            }
            .navigationTitle("Accuracy")
            .analyticsScreen(.calorieAccuracy)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CalorieSettingsView()
    }
}
