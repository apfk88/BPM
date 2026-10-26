import SwiftUI

/// Edits the saved workout. Share-card overrides live in their own editor.
struct WorkoutDetailsEditor: View {
    let recordID: UUID
    let store: WorkoutStore
    @State private var title: String
    @State private var description: String
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(record: WorkoutRecord, store: WorkoutStore) {
        recordID = record.id
        self.store = store
        _title = State(initialValue: record.title ?? "")
        _description = State(initialValue: record.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Workout", text: $title)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("savedWorkoutTitle")
                }
                Section("Description") {
                    TextEditor(text: $description)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Workout description")
                        .accessibilityIdentifier("savedWorkoutDescription")
                }
            }
            .disabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        store.updateDetails(for: recordID, title: title, description: description) { result in
                            isSaving = false
                            switch result {
                            case .success: dismiss()
                            case .failure(let error): saveError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveWorkoutDetails")
                }
            }
            .alert("Couldn’t Save Workout", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "Please try again.")
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}
