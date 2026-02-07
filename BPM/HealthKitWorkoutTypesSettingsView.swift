import SwiftUI

struct HealthKitWorkoutTypesSettingsView: View {
    @AppStorage(HealthKitWorkoutTypeDefaultsKey.quickSelection)
    private var quickTypesRawValue = HealthKitWorkoutTypeSettings.defaultQuickSelectionRawValue()

    @State private var selectedTypes: [HealthKitActivityOption] = HealthKitWorkoutTypeSettings.defaultQuickSelection

    var body: some View {
        List {
            Section(
                header: Text("Top 4 Workout Types"),
                footer: Text("Shown in this order when saving a workout to Apple Health.")
            ) {
                ForEach(0..<HealthKitWorkoutTypeSettings.quickSelectionCount, id: \.self) { index in
                    Picker("Type \(index + 1)", selection: binding(for: index)) {
                        ForEach(HealthKitActivityOption.allCases) { option in
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
        for option in HealthKitActivityOption.allCases where !ordered.contains(option) {
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
