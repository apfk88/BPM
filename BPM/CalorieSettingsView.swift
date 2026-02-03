import SwiftUI

struct CalorieSettingsView: View {
    @AppStorage(CaloriesDefaultsKey.weightKg) private var weightKgText = ""
    @AppStorage(CaloriesDefaultsKey.ageYears) private var ageYearsText = ""
    @AppStorage(CaloriesDefaultsKey.sexAtBirth) private var sexAtBirthRaw = SexAtBirth.male.rawValue
    @AppStorage(CaloriesDefaultsKey.heightCm) private var heightCmText = ""
    @AppStorage(CaloriesDefaultsKey.restHrBpm) private var restHrText = ""
    @AppStorage(CaloriesDefaultsKey.maxHrBpm) private var maxHrText = ""
    @AppStorage(CaloriesDefaultsKey.vo2Max) private var vo2MaxText = ""
    @AppStorage(CaloriesDefaultsKey.rmrKcalPerDay) private var rmrText = ""
    @AppStorage(CaloriesDefaultsKey.bodyFatPercent) private var bodyFatText = ""

    @State private var showConfidenceWhy = false
    @State private var heightFeetText = ""
    @State private var heightInchesText = ""
    @State private var weightLbText = ""
    @FocusState private var isWeightFocused: Bool

    private var sexAtBirth: SexAtBirth {
        SexAtBirth(rawValue: sexAtBirthRaw) ?? .male
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
            medsAffectingHr: false
        )
    }

    var body: some View {
        List {
            Section(footer: Text("More detail = better accuracy.")) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(statusColor)
                }

                HStack {
                    Text("Confidence")
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
                numericRow(label: "Age", text: $ageYearsText, unit: "yrs", allowsDecimal: false)
                sexRow
                heightRow
            }

            Section(
                header: Text("Advanced"),
                footer: Text("Optional fields increase accuracy.")
            ) {
                numericRow(label: "Resting HR", text: $restHrText, unit: "bpm", allowsDecimal: false)
                numericRow(label: "Max HR", text: $maxHrText, unit: "bpm", allowsDecimal: false)
                numericRow(label: "VO2max", text: $vo2MaxText, unit: "ml/kg/min", allowsDecimal: true)
                numericRow(label: "RMR", text: $rmrText, unit: "kcal/day", allowsDecimal: true)
                numericRow(label: "Body Fat", text: $bodyFatText, unit: "%", allowsDecimal: true)
            }
        }
        .navigationTitle("Calorie Settings")
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
        }
        .onChange(of: heightFeetText) { _, _ in
            updateHeightCmFromImperial()
        }
        .onChange(of: heightInchesText) { _, _ in
            updateHeightCmFromImperial()
        }
        .onChange(of: isWeightFocused) { _, isFocused in
            if !isFocused {
                commitWeightToKg()
            }
        }
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
        return Text("Missing required: \(missing). Calories are disabled until complete.")
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
        var reasons: [String] = ["Method: \(methodLabel)"]
        if profile.maxHeartRate != nil {
            reasons.append("Measured max HR provided (+0.2)")
        } else {
            reasons.append("Max HR not provided (uses age-based estimate)")
        }
        if profile.vo2Max != nil {
            reasons.append("VO2max provided (+0.2)")
        } else {
            reasons.append("VO2max not provided")
        }
        if profile.rmrKcalPerDay != nil {
            reasons.append("RMR provided (+0.1)")
        }
        return reasons
    }

    private var sexRow: some View {
        Picker("Sex", selection: $sexAtBirthRaw) {
            Text(SexAtBirth.male.displayName).tag(SexAtBirth.male.rawValue)
            Text(SexAtBirth.female.displayName).tag(SexAtBirth.female.rawValue)
        }
        .pickerStyle(.segmented)
    }

    private var heightRow: some View {
        HStack {
            Text("Height")
            Spacer()
            TextField("", text: numericBinding($heightFeetText, allowsDecimal: false))
                .keyboardType(.numberPad)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
                .textFieldStyle(.roundedBorder)
            Text("ft")
                .foregroundColor(.secondary)
            TextField("", text: numericBinding($heightInchesText, allowsDecimal: true))
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
            TextField("", text: numericBinding($weightLbText, allowsDecimal: true))
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
        guard let cm = Double(heightCmText), cm > 0 else { return }
        let totalInches = cm / 2.54
        let feet = Int(totalInches / 12.0)
        let inches = totalInches - Double(feet * 12)
        heightFeetText = String(feet)
        heightInchesText = formatDecimal(inches)
    }

    private func updateHeightCmFromImperial() {
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
        guard let kg = Double(weightKgText), kg > 0 else { return }
        let lb = kg * 2.2046226218
        weightLbText = formatDecimal(lb)
    }

    private func commitWeightToKg() {
        guard let lb = Double(weightLbText), lb > 0 else {
            weightKgText = ""
            return
        }
        let kg = lb / 2.2046226218
        weightKgText = formatDecimal(kg, maximumFractionDigits: 2)
        weightLbText = formatDecimal(lb)
    }

    private func formatDecimal(_ value: Double, maximumFractionDigits: Int = 1, minimumFractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    private func numericBinding(_ binding: Binding<String>, allowsDecimal: Bool) -> Binding<String> {
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
                    binding.wrappedValue = String(filtered)
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
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Confidence")
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        CalorieSettingsView()
    }
}
