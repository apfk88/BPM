import SwiftUI

struct HealthKitWorkoutTypesSettingsView: View {
    @AppStorage(HealthKitWorkoutTypeDefaultsKey.quickSelection)
    private var quickTypesRawValue = HealthKitWorkoutTypeSettings.defaultQuickSelectionRawValue()

    @State private var selectedTypes: [HealthKitActivityOption] = HealthKitWorkoutTypeSettings.defaultQuickSelection

    var body: some View {
        List {
            Section(
                header: Text("Top 3 Quick Workout Types"),
                footer: Text("Shown in this order in the quick picker when saving to Apple Health.")
            ) {
                ForEach(0..<HealthKitWorkoutTypeSettings.quickSelectionCount, id: \.self) { index in
                    Picker("Type \(index + 1)", selection: binding(for: index)) {
                        ForEach(HealthKitWorkoutTypeSettings.quickSelectionOptions) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }
            }
        }
        .navigationTitle("Workout Types")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedTypes = HealthKitWorkoutTypeSettings.quickSelection(from: quickTypesRawValue)
            persistSelection()
        }
    }

    private func binding(for index: Int) -> Binding<HealthKitActivityOption> {
        Binding(
            get: { selectedTypes[index] },
            set: { newValue in
                applySelection(newValue, at: index)
            }
        )
    }

    private func applySelection(_ selected: HealthKitActivityOption, at index: Int) {
        var ordered = selectedTypes.filter { $0 != selected }
        let safeIndex = max(0, min(index, ordered.count))
        ordered.insert(selected, at: safeIndex)

        for option in HealthKitWorkoutTypeSettings.defaultQuickSelection where !ordered.contains(option) {
            ordered.append(option)
        }
        for option in HealthKitWorkoutTypeSettings.quickSelectionOptions where !ordered.contains(option) {
            ordered.append(option)
        }

        selectedTypes = Array(ordered.prefix(HealthKitWorkoutTypeSettings.quickSelectionCount))
        persistSelection()
    }

    private func persistSelection() {
        quickTypesRawValue = HealthKitWorkoutTypeSettings.encodedQuickSelection(selectedTypes)
    }
}

#Preview {
    NavigationView {
        HealthKitWorkoutTypesSettingsView()
    }
}
