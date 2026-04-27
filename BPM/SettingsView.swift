//
//  SettingsView.swift
//  BPM
//
//  Created by OpenAI on 11/5/25.
//
import Foundation
import SwiftUI
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HeartRateAlertDefaultsKey.heartRateEnabled) private var isHeartRateAlertEnabled = false
    @AppStorage(HeartRateAlertDefaultsKey.heartRateThreshold) private var heartRateAlertThreshold = 160
    @AppStorage(HeartRateAlertDefaultsKey.zoneEnabled) private var isZoneAlertEnabled = false
    @AppStorage(HeartRateAlertDefaultsKey.zoneSelections) private var zoneAlertSelections = "3,4,5"
    @AppStorage(HealthKitWorkoutTypeDefaultsKey.quickSelection)
    private var healthKitQuickTypesRawValue = HealthKitWorkoutTypeSettings.defaultQuickSelectionRawValue()
    @State private var heartRateAlertThresholdText = ""
    @State private var didLoadHeartRateThreshold = false
    @FocusState private var isHeartRateThresholdFocused: Bool
    @StateObject private var workoutStore = WorkoutStore.shared
    @StateObject private var hrvStore = HRVStore.shared
    @StateObject private var healthKitSyncService = HealthKitWorkoutSyncService.shared
    @State private var showPresetSheet = false
    @State private var healthKitStatusMessage: String?
    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink {
                        ZoneSettingsView()
                    } label: {
                        Text("Zone Settings")
                    }
                    NavigationLink {
                        CalorieSettingsView()
                    } label: {
                        Text("Calorie Settings")
                    }
                    NavigationLink {
                        HealthKitWorkoutTypesSettingsView()
                    } label: {
                        HStack {
                            Text("Workout Types")
                            Spacer()
                            Text(healthKitQuickTypesSummary)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Button {
                        showPresetSheet = true
                    } label: {
                        HStack {
                            Text("Workout Presets")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section(
                    header: VStack(alignment: .leading, spacing: 4) {
                        Text("Zone Alert")
                        Text("Toggle on to get alerts for selected zones.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                ) {
                    Toggle("Zone Alert", isOn: $isZoneAlertEnabled)
                    NavigationLink {
                        ZoneAlertSelectionView()
                    } label: {
                        HStack {
                            Text("Selected Zones")
                            Spacer()
                            Text(selectedZoneSummary)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section(
                    header: VStack(alignment: .leading, spacing: 4) {
                        Text("BPM Alert")
                        Text("Alert triggers when your heart rate crosses the threshold.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                ) {
                    Toggle("BPM Alert", isOn: $isHeartRateAlertEnabled)
                    HStack {
                        Text("BPM Alert")
                        Spacer()
                        TextField("", text: $heartRateAlertThresholdText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .textFieldStyle(.roundedBorder)
                            .focused($isHeartRateThresholdFocused)
                        Text("BPM")
                            .foregroundColor(.secondary)
                    }
                }
                Section(header: Text("History")) {
                    NavigationLink {
                        WorkoutHistoryView(store: workoutStore)
                    } label: {
                        Text("Workout History")
                    }
                    NavigationLink {
                        HRVHistoryView(store: hrvStore)
                    } label: {
                        Text("HRV History")
                    }
                }
                Section(header: Text("Integrations")) {
                    Button {
                        Task {
                            await requestHealthKitAccess()
                        }
                    } label: {
                        HStack {
                            Text("Apple Health")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(healthKitStatusText)
                                .foregroundColor(healthKitStatusColor)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        commitHeartRateThreshold()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if !didLoadHeartRateThreshold {
                heartRateAlertThresholdText = String(heartRateAlertThreshold)
                didLoadHeartRateThreshold = true
            }
            healthKitSyncService.refreshAuthorizationState()
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetConfigurationView(
                isPresented: $showPresetSheet,
                currentPresetId: nil,
                mode: .manage,
                onLoadPreset: { _ in },
                onClearPreset: { }
            )
        }
        .onChange(of: heartRateAlertThresholdText) { _, newValue in
            let digitsOnly = newValue.filter { $0.isNumber }
            if digitsOnly != newValue {
                heartRateAlertThresholdText = digitsOnly
            }
        }
        .onChange(of: isHeartRateThresholdFocused) { _, isFocused in
            if !isFocused {
                commitHeartRateThreshold()
            }
        }
    }
    private var healthKitStatusText: String {
        if let healthKitStatusMessage {
            return healthKitStatusMessage
        }

        switch healthKitSyncService.authorizationState {
        case .authorized:
            return "Connected"
        case .denied:
            return "Not Connected"
        case .unavailable:
            return "Unavailable"
        case .requesting:
            return "Connecting..."
        case .unknown:
            return "Not Connected"
        }
    }

    private var healthKitStatusColor: Color {
        if healthKitStatusMessage != nil {
            return .orange
        }

        switch healthKitSyncService.authorizationState {
        case .authorized:
            return .green
        case .requesting:
            return .secondary
        case .denied, .unavailable, .unknown:
            return .secondary
        }
    }

    @MainActor
    private func requestHealthKitAccess() async {
        healthKitStatusMessage = nil
        do {
            try await healthKitSyncService.requestWriteAuthorization()
        } catch let syncError as HealthKitSyncError {
            healthKitStatusMessage = syncError.userFacingMessage
        } catch {
            healthKitStatusMessage = error.localizedDescription
        }
        healthKitSyncService.refreshAuthorizationState()
    }

    private var selectedZoneSummary: String {
        let ids = zoneAlertSelections
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let zones = HeartRateZone.allCases.filter { ids.contains($0.rawValue) }
        guard !zones.isEmpty else { return "None" }
        return zones.map { $0.displayName }.joined(separator: ", ")
    }

    private var healthKitQuickTypesSummary: String {
        let options = HealthKitWorkoutTypeSettings.quickSelection(from: healthKitQuickTypesRawValue)
        return options.map(\.title).joined(separator: ", ")
    }

    private func commitHeartRateThreshold() {
        guard let value = Int(heartRateAlertThresholdText) else { return }
        let clamped = min(max(value, 40), 240)
        heartRateAlertThreshold = clamped
        heartRateAlertThresholdText = String(clamped)
    }
}

private struct ZoneSettingsView: View {
    @ObservedObject private var zoneStorage = HeartRateZoneStorage.shared

    @State private var maxHeartRate: String = ""
    @State private var zone1Min: String = ""
    @State private var zone1Max: String = ""
    @State private var zone2Min: String = ""
    @State private var zone2Max: String = ""
    @State private var zone3Min: String = ""
    @State private var zone3Max: String = ""
    @State private var zone4Min: String = ""
    @State private var zone4Max: String = ""
    @State private var zone5Min: String = ""
    @State private var zone5Max: String = ""
    @State private var didLoadConfig = false

    var body: some View {
        List {
            Section(
                header: Text("Max Heart Rate"),
                footer: Text("If you don't know your max heart rate, use 220 minus your age.")
            ) {
                HStack {
                    TextField("", text: numericBinding($maxHeartRate, maxDigits: 3))
                        .keyboardType(.numberPad)
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 72)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: maxHeartRate) { _, newValue in
                            if let hrMax = Int(newValue), hrMax > 0 {
                                recalculateZones(from: hrMax)
                            }
                        }
                    Text("BPM")
                        .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text("Zone Ranges"),
                footer: Text("Zones are auto-calculated from max HR. You can override values.")
            ) {
                zoneRow(zone: .zone1, minValue: $zone1Min, maxValue: $zone1Max)
                zoneRow(zone: .zone2, minValue: $zone2Min, maxValue: $zone2Max)
                zoneRow(zone: .zone3, minValue: $zone3Min, maxValue: $zone3Max)
                zoneRow(zone: .zone4, minValue: $zone4Min, maxValue: $zone4Max)
                zoneRow(zone: .zone5, minValue: $zone5Min, maxValue: $zone5Max)
            }

            Section {
                Button("Reset Defaults") {
                    zoneStorage.config = nil
                    loadExistingConfiguration()
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Zone Settings")
        .onAppear {
            if !didLoadConfig {
                loadExistingConfiguration()
                didLoadConfig = true
            }
        }
        .onChange(of: maxHeartRate) { _, _ in
            applyZoneConfigIfValid()
        }
        .onChange(of: zone1Min) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone1Max) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone2Min) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone2Max) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone3Min) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone3Max) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone4Min) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone4Max) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone5Min) { _, _ in applyZoneConfigIfValid() }
        .onChange(of: zone5Max) { _, _ in applyZoneConfigIfValid() }
    }

    private func zoneRow(zone: HeartRateZone, minValue: Binding<String>, maxValue: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(zone.color)
                    .frame(width: 8, height: 8)
                Text(zone.fullName)
                    .font(.subheadline)
                Spacer()
                Text(zone.percentageRange)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                TextField("Min", text: numericBinding(minValue))
                    .keyboardType(.numberPad)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)

                Text("-")
                    .foregroundColor(.secondary)

                TextField("Max", text: numericBinding(maxValue))
                    .keyboardType(.numberPad)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)

                Text("BPM")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var isValidConfiguration: Bool {
        guard let hrMax = Int(maxHeartRate), hrMax > 0 else { return false }
        guard let z1Min = Int(zone1Min), let z1Max = Int(zone1Max) else { return false }
        guard let z2Min = Int(zone2Min), let z2Max = Int(zone2Max) else { return false }
        guard let z3Min = Int(zone3Min), let z3Max = Int(zone3Max) else { return false }
        guard let z4Min = Int(zone4Min), let z4Max = Int(zone4Max) else { return false }
        guard let z5Min = Int(zone5Min), let z5Max = Int(zone5Max) else { return false }

        guard z1Min < z1Max, z2Min < z2Max, z3Min < z3Max, z4Min < z4Max, z5Min < z5Max else {
            return false
        }
        guard z2Min >= z1Max, z3Min >= z2Max, z4Min >= z3Max, z5Min >= z4Max else {
            return false
        }

        return true
    }

    private func loadExistingConfiguration() {
        let config = zoneStorage.config ?? zoneStorage.effectiveConfig

        maxHeartRate = String(config.maxHeartRate)
        zone1Min = String(config.zone1Min)
        zone1Max = String(config.zone1Max)
        zone2Min = String(config.zone2Min)
        zone2Max = String(config.zone2Max)
        zone3Min = String(config.zone3Min)
        zone3Max = String(config.zone3Max)
        zone4Min = String(config.zone4Min)
        zone4Max = String(config.zone4Max)
        zone5Min = String(config.zone5Min)
        zone5Max = String(config.zone5Max)
    }

    private func recalculateZones(from hrMax: Int) {
        let config = HeartRateZoneConfig(maxHeartRate: hrMax)
        zone1Min = String(config.zone1Min)
        zone1Max = String(config.zone1Max)
        zone2Min = String(config.zone2Min)
        zone2Max = String(config.zone2Max)
        zone3Min = String(config.zone3Min)
        zone3Max = String(config.zone3Max)
        zone4Min = String(config.zone4Min)
        zone4Max = String(config.zone4Max)
        zone5Min = String(config.zone5Min)
        zone5Max = String(config.zone5Max)
    }

    private func applyZoneConfigIfValid() {
        guard let hrMax = Int(maxHeartRate),
              let z1Min = Int(zone1Min), let z1Max = Int(zone1Max),
              let z2Min = Int(zone2Min), let z2Max = Int(zone2Max),
              let z3Min = Int(zone3Min), let z3Max = Int(zone3Max),
              let z4Min = Int(zone4Min), let z4Max = Int(zone4Max),
              let z5Min = Int(zone5Min), let z5Max = Int(zone5Max) else {
            return
        }

        var config = HeartRateZoneConfig(maxHeartRate: hrMax)
        config.zone1Min = z1Min
        config.zone1Max = z1Max
        config.zone2Min = z2Min
        config.zone2Max = z2Max
        config.zone3Min = z3Min
        config.zone3Max = z3Max
        config.zone4Min = z4Min
        config.zone4Max = z4Max
        config.zone5Min = z5Min
        config.zone5Max = z5Max

        if isValidConfiguration {
            zoneStorage.config = config
        }
    }

    private func numericBinding(_ binding: Binding<String>, maxDigits: Int? = nil) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber }
                if let maxDigits {
                    binding.wrappedValue = String(filtered.prefix(maxDigits))
                } else {
                    binding.wrappedValue = filtered
                }
            }
        )
    }
}

private struct ZoneAlertSelectionView: View {
    @AppStorage(HeartRateAlertDefaultsKey.zoneSelections) private var zoneAlertSelections = "3,4,5"

    private var selectedZoneIds: Set<Int> {
        let values = zoneAlertSelections
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return Set(values)
    }

    var body: some View {
        List {
            Section {
                ForEach(HeartRateZone.allCases, id: \.self) { zone in
                    Toggle(isOn: zoneBinding(zone)) {
                        HStack {
                            Circle()
                                .fill(zone.color)
                                .frame(width: 10, height: 10)
                            Text(zone.fullName)
                        }
                    }
                }
            }
        }
        .navigationTitle("Selected Zones")
    }

    private func zoneBinding(_ zone: HeartRateZone) -> Binding<Bool> {
        Binding(
            get: {
                selectedZoneIds.contains(zone.rawValue)
            },
            set: { isOn in
                var next = selectedZoneIds
                if isOn {
                    next.insert(zone.rawValue)
                } else {
                    next.remove(zone.rawValue)
                }
                zoneAlertSelections = next.sorted().map(String.init).joined(separator: ",")
            }
        )
    }
}

#Preview {
    SettingsView()
}
