//
//  HeartRateZoneConfigView.swift
//  BPM
//

import SwiftUI

/// Retains the modal entry point while sharing the Settings editor's behavior.
struct HeartRateZoneConfigView: View {
    @Binding var isPresented: Bool
    @ObservedObject var storage = HeartRateZoneStorage.shared

    var body: some View {
        NavigationStack {
            ZoneSettingsView(storage: storage, title: "Heart Rate Zones") {
                isPresented = false
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ZoneSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storage: HeartRateZoneStorage
    @State private var draft: HeartRateZoneDraft
    @State private var showRecalculationConfirmation = false
    @State private var showResetConfirmation = false
    @FocusState private var focusedField: String?
    private let title: String
    private let onDismiss: (() -> Void)?

    init(
        storage: HeartRateZoneStorage = .shared,
        title: String = "Zone Settings",
        onDismiss: (() -> Void)? = nil
    ) {
        self.storage = storage
        self.title = title
        self.onDismiss = onDismiss
        _draft = State(initialValue: HeartRateZoneDraft(config: storage.effectiveConfig))
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Max Heart Rate")
                    Spacer()
                    numberField("Max Heart Rate", text: $draft.maxHeartRate)
                        .accessibilityIdentifier("zoneMaxHeartRate")
                    Text("BPM")
                        .foregroundStyle(.secondary)
                }
                Button("Recalculate Zones") {
                    focusedField = nil
                    showRecalculationConfirmation = true
                }
                .disabled(draft.validMaxHeartRate == nil)
                .accessibilityIdentifier("recalculateZones")
            } footer: {
                Text("Changing max HR keeps your current zone ranges. Recalculate only if you want to replace them with 50-100% of max HR. Formulas are population estimates; use a measured max HR when available.")
            }

            Section {
                ForEach(HeartRateZone.allCases, id: \.self) { zone in
                    zoneRow(zone)
                }
            } header: {
                Text("Zone Ranges")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = draft.validationError {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("zoneValidationError")
                    }
                    Text("Changes take effect when you tap Save. Z1 includes resting readings below its minimum; Z5 includes readings above its maximum. Gaps between custom ranges remain unassigned.")
                }
            }

            Section {
                Button("Reset Defaults", role: .destructive) {
                    focusedField = nil
                    showResetConfirmation = true
                }
                .accessibilityIdentifier("resetZones")
            } footer: {
                if draft.resetsStoredConfiguration {
                    Text("Defaults loaded: max HR 190 BPM. Tap Save to apply, or Cancel to keep your saved zones.")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .analyticsScreen(.zones)
        .onAppear {
            // NavigationLink may cache its destination before a previous edit
            // is saved. Start each presentation from the current configuration.
            draft = HeartRateZoneDraft(config: storage.effectiveConfig)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: close)
                    .accessibilityIdentifier("cancelZones")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard draft.save(to: storage) else { return }
                    close()
                }
                .disabled(draft.validationError != nil)
                .accessibilityIdentifier("saveZones")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("dismissZoneKeyboard")
            }
        }
        .confirmationDialog("Recalculate all zones?", isPresented: $showRecalculationConfirmation, titleVisibility: .visible) {
            Button("Recalculate Zones", role: .destructive) {
                draft.recalculateZones()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Replace all five ranges using \(draft.maxHeartRate) BPM as your max HR? Your saved zones stay unchanged until you tap Save.")
        }
        .confirmationDialog("Reset zone defaults?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Defaults", role: .destructive) {
                draft.resetToDefaults()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Load the default ranges and a max HR of 190 BPM. Tap Save afterward to replace your saved settings.")
        }
    }

    private func zoneRow(_ zone: HeartRateZone) -> some View {
        let index = zone.rawValue - 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(zone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(zone.fullName)
                    .font(.subheadline)
            }
            HStack(spacing: 12) {
                numberField("Zone \(zone.rawValue) minimum", text: $draft.ranges[index].minimum)
                    .accessibilityIdentifier("zone\(zone.rawValue)Minimum")
                Text("to")
                    .foregroundStyle(.secondary)
                numberField("Zone \(zone.rawValue) maximum", text: $draft.ranges[index].maximum)
                    .accessibilityIdentifier("zone\(zone.rawValue)Maximum")
                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField("", text: Binding(
            get: { text.wrappedValue },
            set: { text.wrappedValue = String($0.filter { $0.isNumber }.prefix(3)) }
        ))
        .accessibilityLabel(label)
        .keyboardType(.numberPad)
        .font(.system(size: 18, weight: .medium, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(minWidth: 64, idealWidth: 76, maxWidth: 92)
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: label)
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
