import SwiftUI

struct CalorieHealthAutofillReview: Identifiable {
    let id = UUID()
    let snapshot: CalorieHealthAutofillSnapshot
}

struct CalorieHealthAutofillReviewView: View {
    let snapshot: CalorieHealthAutofillSnapshot
    let weightUnit: String
    let onApply: ([CalorieHealthField]) -> Void
    @Environment(\.dismiss) private var dismiss

    private var hasEmptyFields: Bool {
        snapshot.entries.contains { isEmpty($0.field) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(snapshot.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.field.title)
                                .font(.headline)
                            Text(displayValue(entry))
                                .font(.body.monospacedDigit())
                            Text(importActionLabel(entry.field))
                                .font(.subheadline)
                                .foregroundStyle(isEmpty(entry.field) ? Color.accentColor : Color.secondary)
                            if let date = entry.sampleDate {
                                Text("Recorded \(date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Latest shared values")
                } footer: {
                    Text("Fills empty fields only. Imported values stay on this device.")
                }
            }
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Autofill") {
                        onApply(snapshot.fillMissingValues(in: .standard))
                        dismiss()
                    }
                    .disabled(!hasEmptyFields)
                    .accessibilityIdentifier("applyCalorieHealthAutofill")
                }
            }
        }
    }

    private func isEmpty(_ field: CalorieHealthField) -> Bool {
        (UserDefaults.standard.string(forKey: field.defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func importActionLabel(_ field: CalorieHealthField) -> String {
        guard isEmpty(field) else { return "Keep your existing entry" }
        return field == .restingHR || field == .vo2Max ? "Fill if compatible" : "Fill empty field"
    }

    private func displayValue(_ entry: CalorieHealthAutofillEntry) -> String {
        switch entry.field {
        case .weight:
            guard let kg = Double(entry.value) else { return entry.value }
            let value = weightUnit == "kg" ? kg : kg * 2.2046226218
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit == "kg" ? "kg" : "lb")"
        case .age:
            return "\(entry.value) years"
        case .sex:
            return SexAtBirth(rawValue: entry.value)?.displayName ?? entry.value
        case .restingHR:
            return "\(entry.value) bpm"
        case .vo2Max:
            return "\(entry.value) ml/kg/min"
        }
    }
}
