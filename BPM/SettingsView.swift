//
//  SettingsView.swift
//  BPM
//
//  Created by OpenAI on 11/5/25.
//
import Foundation
import SwiftUI
struct SettingsView: View {
    private let feedbackEmail = "bpm-support@proton.me"
    @Environment(\.dismiss) private var dismiss
    @CalorieProfileStorage private var calorieProfile
    @ObservedObject private var maxHRSuggestion = MaxHeartRateSuggestionStore.shared
    @AppStorage(WorkoutVoiceConsent.defaultsKey) private var hasVoiceConsent = false
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
        NavigationStack {
            List {
                if let maximum = maxHRSuggestion.pendingMaxHeartRate {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("New max detected: \(maximum) BPM", systemImage: "heart.fill")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("newMaxHRSuggestion")
                            Text("Update Max HR in settings?")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Button("Yes, update") { maxHRSuggestion.accept() }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("acceptNewMaxHR")
                                Button("No") { maxHRSuggestion.dismiss() }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("dismissNewMaxHR")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    NavigationLink {
                        ZoneSettingsView()
                    } label: {
                        Text("Zone Settings")
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
                    Toggle("Zone Alert", isOn: Binding(
                        get: { isZoneAlertEnabled },
                        set: { isZoneAlertEnabled = $0; AppAnalytics.setting(.zoneAlert, enabled: $0) }
                    ))
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
                        Text("Alerts above your threshold.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                ) {
                    Toggle("BPM Alert", isOn: Binding(
                        get: { isHeartRateAlertEnabled },
                        set: { isHeartRateAlertEnabled = $0; AppAnalytics.setting(.bpmAlert, enabled: $0) }
                    ))
                    HStack {
                        Text("Threshold")
                        Spacer()
                        TextField("Threshold", text: $heartRateAlertThresholdText)
                            .accessibilityLabel("BPM alert threshold")
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
                Section {
                    NavigationLink {
                        CalorieSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Text("Calorie Settings")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(calorieProfile.setupTitle)
                                .font(.subheadline)
                                .foregroundStyle(calorieProfile.needsCalorieSetupAttention ? .orange : .secondary)
                            if calorieProfile.needsCalorieSetupAttention {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityLabel("Calorie Settings")
                    .accessibilityValue(calorieProfile.setupTitle)
                    .accessibilityHint(calorieProfile.setupDetail)
                    .accessibilityIdentifier("calorieSettingsLink")
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
                Section("AI Voice Privacy") {
                    Button("Reset AI voice permission") {
                        hasVoiceConsent = false
                    }
                    .disabled(!hasVoiceConsent)
                }
                Section(header: Text("Support")) {
                    Link(destination: feedbackEmailURL) {
                        Label("Contact Support", systemImage: "envelope")
                    }
                    Link(destination: appStoreReviewURL) {
                        HStack {
                            Text("Rate BPM")
                            Spacer()
                            Image(systemName: "star")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Link(destination: privacyPolicyURL) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section {
                    VStack(spacing: 3) {
                        Text("Version \(appVersion)")
                        HStack(spacing: 4) {
                            Text("© 2026 Alex Kvamme")
                            Text("•")
                            Link(feedbackEmail, destination: feedbackEmailURL)
                                .foregroundColor(.accentColor)
                                .accessibilityLabel("Email feedback or report an issue")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .analyticsScreen(.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var feedbackEmailURL: URL {
        URL(string: "mailto:\(feedbackEmail)?subject=BPM%20Feedback")!
    }

    private var privacyPolicyURL: URL {
        URL(string: "https://bpmtracker.app/privacy.html")!
    }

    private var appStoreReviewURL: URL {
        URL(string: "https://apps.apple.com/app/id6754830191?action=write-review")!
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
        AppAnalytics.signal(.healthAccessRequested)
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
        .analyticsScreen(.zoneAlerts)
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
