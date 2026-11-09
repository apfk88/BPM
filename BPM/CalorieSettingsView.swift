import SwiftUI

struct CalorieSettingsView: View {
    var isPresentedAsSetup = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CaloriesDefaultsKey.weightKg) private var weightKgText = ""
    @AppStorage(CaloriesDefaultsKey.ageYears) private var ageYearsText = ""
    @AppStorage(CaloriesDefaultsKey.sexAtBirth) private var sexAtBirthRaw = ""
    @AppStorage(CaloriesDefaultsKey.restHrBpm) private var restHrText = ""
    @AppStorage(CaloriesDefaultsKey.maxHrBpm) private var maxHrText = ""
    @AppStorage(CaloriesDefaultsKey.vo2Max) private var vo2MaxText = ""
    @AppStorage(CaloriesDefaultsKey.rmrKcalPerDay) private var rmrText = ""
    @AppStorage(CaloriesDefaultsKey.medsAffectingHr) private var medsAffectingHr = false
    @AppStorage(CalorieSetupDefaultsKey.weightUnit) private var weightUnit = "lb"

    @Environment(\.scenePhase) private var scenePhase
    @State private var editedFields: Set<CalorieAnalytics.Field> = []
    @State private var showHowItWorks = false
    @State private var weightText = ""
    @State private var isLoadingHealthAutofill = false
    @State private var healthAutofillMessage: String?
    @State private var healthAutofillFailed = false
    @State private var healthAutofillReview: CalorieHealthAutofillReview?
    @State private var healthAutofillTask: Task<Void, Never>?
    @FocusState private var focusedField: CalorieAnalytics.Field?

    private var sexAtBirth: SexAtBirth? {
        SexAtBirth(rawValue: sexAtBirthRaw)
    }

    private var profile: UserEnergyProfile {
        UserEnergyProfile(
            weightKg: Double(weightKgText),
            ageYears: Int(ageYearsText),
            sexAtBirth: sexAtBirth,
            heightCm: nil,
            restHeartRate: Int(restHrText),
            maxHeartRate: Int(maxHrText),
            vo2Max: Double(vo2MaxText),
            rmrKcalPerDay: Double(rmrText),
            bodyFatPercent: nil,
            medsAffectingHr: medsAffectingHr
        )
    }

    var body: some View {
        List {
            Section {
                CalorieSetupSummary(profile: profile)
                Button {
                    focusedField = nil
                    healthAutofillTask = Task { await loadHealthAutofill() }
                } label: {
                    HStack {
                        Label("Autofill from Apple Health", systemImage: "heart.text.square")
                        Spacer()
                        if isLoadingHealthAutofill { ProgressView() }
                    }
                }
                .disabled(isLoadingHealthAutofill)
                .accessibilityIdentifier("autofillCaloriesFromHealth")
                if let healthAutofillMessage {
                    Text(healthAutofillMessage)
                        .font(.footnote)
                        .foregroundStyle(healthAutofillFailed ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("calorieHealthAutofillMessage")
                }
            }

            Section("Basics") {
                weightRow
                numericRow(label: "Age", text: tracked($ageYearsText, field: .age), unit: "yrs", allowsDecimal: false, field: .age)
                sexRow
            }

            Section {
                numericRow(label: "Resting HR", text: tracked($restHrText, field: .restingHR), unit: "bpm", allowsDecimal: false, field: .restingHR)
                numericRow(label: "Max HR", text: tracked($maxHrText, field: .maxHR), unit: "bpm", allowsDecimal: false, field: .maxHR)
                numericRow(label: "VO2max", text: tracked($vo2MaxText, field: .vo2Max), unit: "ml/kg/min", allowsDecimal: true, field: .vo2Max)
                numericRow(label: "Resting energy", text: tracked($rmrText, field: .rmr), unit: "kcal/day", allowsDecimal: true, field: .rmr)
            } header: {
                Text("Optional")
            } footer: {
                Text("Use values you know. Leave the rest blank.")
            }

            Section {
                Button {
                    focusedField = nil
                    showHowItWorks = true
                } label: {
                    Label("How calorie estimates work", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Calorie Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .analyticsScreen(.calories)
        .toolbar {
            if isPresentedAsSetup {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        focusedField = nil
                        dismiss()
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("dismissCalorieKeyboard")
            }
        }
        .sheet(isPresented: $showHowItWorks) {
            CalorieExplanationSheet(medsAffectingHr: $medsAffectingHr)
        }
        .sheet(item: $healthAutofillReview) { review in
            CalorieHealthAutofillReviewView(snapshot: review.snapshot, weightUnit: weightUnit) { fields in
                if fields.isEmpty {
                    healthAutofillMessage = "No compatible values to add."
                } else {
                    healthAutofillMessage = "Filled: \(fields.map(\.title).joined(separator: ", "))."
                }
                healthAutofillFailed = false
                hydrateWeightField()
                AppAnalytics.signal(.calorieConfiguration, parameters: CalorieAnalytics.configuration())
                AppAnalytics.recordConfiguration()
            }
        }
        .onAppear {
            hydrateWeightField()
        }
        .onDisappear {
            healthAutofillTask?.cancel()
            flushAnalytics()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { flushAnalytics() }
        }
        .onChange(of: weightUnit) { _, _ in
            hydrateWeightField()
        }
        .onChange(of: weightKgText) { _, _ in
            if focusedField != .weight { hydrateWeightField() }
        }
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .weight, newField != .weight { hydrateWeightField() }
        }
    }

    @MainActor
    private func loadHealthAutofill() async {
        guard !isLoadingHealthAutofill else { return }
        isLoadingHealthAutofill = true
        healthAutofillMessage = nil
        healthAutofillFailed = false
        defer { isLoadingHealthAutofill = false }
        do {
            #if DEBUG
            let service = CalorieHealthAutofillUITestFixture.service() ?? CalorieHealthAutofillService()
            #else
            let service = CalorieHealthAutofillService()
            #endif
            let snapshot = try await service.fetch()
            guard !Task.isCancelled else { return }
            if snapshot.entries.isEmpty {
                healthAutofillMessage = "No shared data was available. Enter your details manually or review BPM's access in Apple Health."
            } else {
                healthAutofillReview = CalorieHealthAutofillReview(snapshot: snapshot)
            }
        } catch {
            guard !Task.isCancelled, !AppFailureCategory.isCancellation(error) else { return }
            healthAutofillFailed = true
            healthAutofillMessage = error.localizedDescription
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

    private var sexRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sex")
            Picker("Sex", selection: tracked($sexAtBirthRaw, field: .sex)) {
                Text("Choose").tag("")
                Text(SexAtBirth.male.displayName).tag(SexAtBirth.male.rawValue)
                Text(SexAtBirth.female.displayName).tag(SexAtBirth.female.rawValue)
            }
            .pickerStyle(.segmented)
        }
    }

    private func numericRow(label: String, text: Binding<String>, unit: String, allowsDecimal: Bool, field: CalorieAnalytics.Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("Add", text: numericBinding(text, allowsDecimal: allowsDecimal))
                .accessibilityLabel(label)
                .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
            Text(unit)
                .foregroundColor(.secondary)
        }
    }

    private var weightRow: some View {
        HStack {
            Text("Weight")
            Spacer()
            TextField("Add", text: numericBinding(Binding(
                get: { weightText },
                set: { value in
                    weightText = value
                    editedFields.insert(.weight)
                    updateWeightKg()
                }
            ), allowsDecimal: true, normalizesDecimalSeparator: false))
                .accessibilityLabel("Weight")
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .weight)
            Picker("Weight unit", selection: $weightUnit) {
                Text("lb").tag("lb")
                Text("kg").tag("kg")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func hydrateWeightField() {
        guard let kg = Double(weightKgText), kg.isFinite else {
            weightText = ""
            return
        }
        weightText = formatDecimal(weightUnit == "kg" ? kg : kg * 2.2046226218)
    }

    private func updateWeightKg() {
        guard let enteredWeight = Double(weightText.replacingOccurrences(of: ",", with: ".")) else {
            weightKgText = ""
            return
        }
        weightKgText = String(weightUnit == "kg" ? enteredWeight : enteredWeight / 2.2046226218)
    }

    private func formatDecimal(_ value: Double, maximumFractionDigits: Int = 1, minimumFractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maximumFractionDigits)f", value)
    }

    private func numericBinding(_ binding: Binding<String>, allowsDecimal: Bool, normalizesDecimalSeparator: Bool = true) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                let normalized = allowsDecimal && normalizesDecimalSeparator
                    ? newValue.replacingOccurrences(of: ",", with: ".") : newValue
                let filtered = normalized.filter { char in
                    if char.isNumber { return true }
                    if allowsDecimal, char == "." || char == "," { return true }
                    return false
                }
                if allowsDecimal {
                    var hasDecimal = false
                    let compacted = filtered.filter { char in
                        if char == "." || char == "," {
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

private struct CalorieExplanationSheet: View {
    @Binding var medsAffectingHr: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Setup levels") {
                    Text("Basic uses heart rate, weight, age and sex. Personalized also uses resting HR and VO2max, with max HR estimated from age if needed. Complete adds your measured max HR and resting energy (RMR).")
                    Text("Resting and max HR change calorie estimates only when VO2max is also provided.")
                        .foregroundStyle(.secondary)
                }

                Section("Active and total calories") {
                    Text("Active calories exclude resting energy. Total calories include it. A measured resting metabolic rate (RMR) refines that split.")
                }

                Section {
                    Toggle("Medication affects heart rate", isOn: $medsAffectingHr)
                } header: {
                    Text("Heart-rate medication")
                } footer: {
                    Text("Turn on to disable calorie estimates if medication changes your heart-rate response to exercise.")
                }

                Section {
                    Text("Calories are estimates, not direct measurements. Accuracy varies by activity; gaps in heart-rate data are excluded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("How calories are estimated")
            .navigationBarTitleDisplayMode(.inline)
            .analyticsScreen(.calorieAccuracy)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
