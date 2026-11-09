//
//  HRVMeasurementView.swift
//  BPM
//
//  Created for HRV measurement feature
//

import SwiftUI
import UIKit
import Combine

struct HRVMeasurementView: View {
    @CalorieProfileStorage private var calorieProfile
    @ObservedObject private var maxHRSuggestion = MaxHeartRateSuggestionStore.shared
    @ObservedObject var viewModel: HRVMeasurementViewModel
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject var sharingService: SharingService
    var onDismiss: () -> Void
    var localWorkoutNeedsConfirmation = false
    var onJoinFriend: ((String) -> Void)? = nil
    @State private var showClearAlert = false
    @State private var showStopAlert = false
    @State private var showDevicePicker = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showFirstTimeAlert = false
    @State private var hasShownFirstTimeAlert = false
    @State private var pendingMeasurement = false
    @State private var dismissAfterSharedCancel = false
    @State private var hasSavedRecord = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedRecordId: UUID?
    @State private var saveFeedbackMessage: String?
    @State private var saveFeedbackDismissTask: Task<Void, Never>?
    @StateObject private var hrvStore = HRVStore.shared
    @State private var readinessTicks = MeasurementClock.ticks
    @State private var readinessAnalytics = HRVReadinessAnalytics()

    private var startReadiness: HRVStartReadiness {
        Self.readiness(bluetoothManager: bluetoothManager, sharingService: sharingService,
                       nowTicks: max(readinessTicks, MeasurementClock.ticks))
    }

    private static func readiness(bluetoothManager: HeartRateBluetoothManager?, sharingService: SharingService?,
                                  nowTicks: TimeInterval) -> HRVStartReadiness {
        if sharingService?.isViewing == true {
            guard sharingService?.friendWorkoutIsFresh == true,
                  let snapshot = sharingService?.friendWorkout?.hrv else {
                return HRVStartReadiness(source: .shared, reason: .sharedDataUnavailable)
            }
            return HRVStartReadiness(source: .shared, reason: snapshot.readinessReason)
        }
        return .local(isConnected: bluetoothManager?.hasActiveDataSource == true,
                      hasSensorContact: bluetoothManager?.sensorContactStatus != .notDetected,
                      hasFreshHeartRate: bluetoothManager?.freshHeartRate != nil,
                      supportsRR: bluetoothManager?.supportsRRIntervals == true,
                      latestRRTicks: bluetoothManager?.rrIntervals.last?.receivedTicks,
                      nowTicks: nowTicks)
    }

    private func recordReadiness() {
        guard viewModel.state == .idle,
              var parameters = readinessAnalytics.observation(startReadiness) else { return }
        if startReadiness.source == .local {
            parameters.merge(bluetoothManager.sensorAnalyticsIdentity.parameters) { _, new in new }
        }
        AppAnalytics.signal(.hrvReadiness, parameters: parameters)
    }

    private var displayedHeartRate: Int? {
        if sharingService.isViewing {
            return sharingService.friendHeartRate
        } else {
            return bluetoothManager.freshHeartRate
        }
    }

    private var heartButtonColor: Color {
        if bluetoothManager.hasActiveDataSource {
            return .green
        } else if sharingService.isViewing {
            return .green
        } else {
            return .white
        }
    }

    private var heartIconName: String {
        bluetoothManager.hasActiveDataSource ? "heart.fill" : "heart"
    }

    private var buttonText: String {
        if viewModel.state == .idle && startReadiness.shouldConnectMonitor {
            return "Connect monitor"
        } else if viewModel.hasError {
            return "OK"
        } else if viewModel.isCompleted {
            return "Measure HRV"
        } else if case .countingDown = viewModel.state {
            return "Measuring..."
        } else {
            return "Measure HRV"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let primaryDisplayFontSize = min(geometry.size.width * 0.32, geometry.size.height * 0.27)
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top bar with close on left and controls on right
                    HStack(spacing: TopBarLayout.buttonSpacing) {
                        Button {
                            if sharingService.isViewing {
                                if viewModel.state == .countingDown { showStopAlert = true }
                                else { onDismiss() }
                            } else if viewModel.isCompleted {
                                if hasSavedRecord {
                                    viewModel.reset()
                                    onDismiss()
                                } else {
                                    showClearAlert = true
                                }
                            } else if case .countingDown = viewModel.state {
                                showStopAlert = true
                            } else {
                                viewModel.reset()
                                onDismiss()
                            }
                        } label: {
                            topBarCircleIcon(systemName: "xmark", accessibilityLabel: "Close HRV measurement")
                                .accessibilityIdentifier("xmark")
                        }

                        Spacer()

                        HStack(spacing: TopBarLayout.buttonSpacing) {
                            Button {
                                showDevicePicker = true
                            } label: {
                                SharedConnectionIcon(symbol: heartIconName, isShared: sharingService.isViewing,
                                                     size: TopBarLayout.iconFontSize)
                                    .foregroundStyle(heartButtonColor)
                                    .frame(width: TopBarLayout.iconSize, height: TopBarLayout.iconSize)
                                    .bpmCircleSurface()
                            }
                            .accessibilityLabel("Device Picker")
                            .accessibilityIdentifier("deviceConnectionMenu")
                            .accessibilityValue(sharingService.isViewing ? "Viewing shared BPM" :
                                                bluetoothManager.hasActiveDataSource ? "Monitor connected" : "Not connected")

                            Button {
                                showHistory = true
                            } label: {
                                topBarCircleIcon(
                                    systemName: "clock.arrow.circlepath",
                                    accessibilityLabel: "HRV History"
                                )
                            }

                            Button {
                                showSettings = true
                            } label: {
                                topBarCircleIcon(systemName: "gearshape", accessibilityLabel: "Settings")
                                    .overlay(alignment: .topTrailing) {
                                        if calorieProfile.needsCalorieSetupAttention || maxHRSuggestion.pendingMaxHeartRate != nil {
                                            CalorieSetupBadge().offset(x: 2, y: -2)
                                        }
                                    }
                            }
                            .accessibilityIdentifier("settingsButton")
                            .accessibilityValue(maxHRSuggestion.pendingMaxHeartRate != nil ? "New max HR detected" : calorieProfile.needsCalorieSetupAttention ? "Calorie setup needed" : calorieProfile.setupTitle)
                        }
                        .frame(width: TopBarLayout.trailingButtonGroupWidth, alignment: .trailing)
                    }
                    .bpmGlassGroup()
                    .padding(.horizontal, TopBarLayout.horizontalPadding)
                    .padding(.top, TopBarLayout.topPadding)
                    .sheet(isPresented: $showDevicePicker) {
                        DevicePickerView(localWorkoutNeedsConfirmation: localWorkoutNeedsConfirmation, onJoinFriend: onJoinFriend)
                            .environmentObject(bluetoothManager)
                            .environmentObject(sharingService)
                    }
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                    }
                    .sheet(isPresented: $showHistory) {
                        historySheet()
                    }
                    .alert("Stop Measurement", isPresented: $showStopAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Stop", role: .destructive) {
                            if sharingService.isViewing {
                                dismissAfterSharedCancel = true
                                resetMeasurement(remoteAction: .hrvCancel)
                            } else {
                                viewModel.reset()
                                onDismiss()
                            }
                        }
                        .disabled(sharingService.isViewing && !canSend(.hrvCancel))
                        if sharingService.isViewing {
                            Button("Leave screen") { onDismiss() }
                        }
                    } message: {
                        Text(sharingService.isViewing
                             ? "Stop ends the measurement on both screens. Leaving this screen keeps it running."
                             : "Are you sure you want to stop the measurement? All progress will be lost.")
                    }
                    .alert("Clear Measurement", isPresented: $showClearAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) {
                            viewModel.reset()
                            onDismiss()
                        }
                    } message: {
                        Text("Are you sure you want to clear the existing measurement? This cannot be undone.")
                    }
                    .alert("Starting Measurement", isPresented: $showFirstTimeAlert) {
                        Button("OK") {
                            hasShownFirstTimeAlert = true
                            if pendingMeasurement {
                                startMeasurement()
                                pendingMeasurement = false
                            }
                        }
                    } message: {
                        Text(sharingService.isViewing
                             ? "Ask the person wearing the monitor to lie still for two minutes. Keep this screen open."
                             : "Lay down, close your eyes, and keep the app open.")
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .accessibilityIdentifier("hrvReadinessMessage")
                    }

                    let contentLayout = isLandscape
                        ? AnyLayout(HStackLayout(spacing: 20))
                        : AnyLayout(VStackLayout(spacing: 0))
                    contentLayout {
                        VStack(spacing: 0) {
                            Spacer(minLength: 8)
                            measurementDisplay(primaryDisplayFontSize: primaryDisplayFontSize)
                                .padding(.horizontal, 24)
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isLandscape {
                            GeometryReader { controlsGeometry in
                                ScrollView {
                                    measurementControls(isLandscape: true)
                                        .frame(minHeight: controlsGeometry.size.height, alignment: .center)
                                }
                                .scrollIndicators(.hidden)
                            }
                            .frame(width: min(200, max(150, geometry.size.width * 0.23)))
                        } else {
                            measurementControls(isLandscape: false)
                        }
                    }
                    .padding(.horizontal, isLandscape ? 20 : 0)
                    .padding(.vertical, isLandscape ? 8 : 0)

                }
            }
            .overlay(alignment: .top) {
                if let saveFeedbackMessage {
                    SuccessHUDView(message: saveFeedbackMessage)
                        .padding(.top, geometry.safeAreaInsets.top + TopBarLayout.iconSize + 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .alert("Could not save HRV", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Please try again.")
        }
        .onAppear {
            hasShownFirstTimeAlert = false
            configureMeasurementSource()
            recordReadiness()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.state == .idle { readinessTicks = MeasurementClock.ticks }
        }
        .onChange(of: startReadiness) { _, _ in recordReadiness() }
        .onDisappear {
            viewModel.stopLiveHeartRateUpdates()
            saveFeedbackDismissTask?.cancel()
        }
        .onChange(of: sharingService.isViewing) { _, _ in
            configureMeasurementSource()
        }
        .onChange(of: sharingService.friendCode) { _, _ in
            configureMeasurementSource()
        }
        .onChange(of: sharingService.workoutControlError) { _, error in
            if error != nil { dismissAfterSharedCancel = false }
        }
        .onChange(of: viewModel.state) { _, newValue in
            if dismissAfterSharedCancel && newValue != .countingDown {
                dismissAfterSharedCancel = false
                onDismiss()
            }
            if case .countingDown = newValue {
                hasSavedRecord = false
                savedRecordId = nil
            } else if case .idle = newValue {
                hasSavedRecord = false
                savedRecordId = nil
                recordReadiness()
            }
        }
    }

    private func measurementDisplay(primaryDisplayFontSize: CGFloat) -> some View {
        // Main display area
        VStack(spacing: 40) {
            // Timer/HRV display - fixed position
            VStack(spacing: 16) {
                if viewModel.hasError {
                    // Show error message
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                } else if viewModel.isCompleted {
                    // Show HRV value in same position as timer
                    if let hrv = viewModel.hrvValue {
                        Text("\(Int(hrv.rounded()))ms")
                            .accessibilityIdentifier("hrvResult")
                            .font(.system(size: primaryDisplayFontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    } else {
                        Text("---")
                            .font(.system(size: primaryDisplayFontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                } else {
                    // Show countdown timer
                    Text(formatTime(viewModel.remainingTime))
                        .accessibilityIdentifier("hrvCountdown")
                        .font(.system(size: primaryDisplayFontSize, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                // Stats bar - BPM, Min, Max (BPM becomes avg when completed)
                // Only show stats if not in error state
                if !viewModel.hasError {
                    HStack(spacing: 12) {
                        statColumn(
                            title: viewModel.isCompleted ? "Avg" : "BPM",
                            value: viewModel.isCompleted ? viewModel.avgHeartRate : viewModel.currentBPM,
                            scaleFactor: 1.0
                        )

                        statColumn(
                            title: "Min",
                            value: viewModel.minHeartRate,
                            scaleFactor: 1.0
                        )

                        statColumn(
                            title: "Max",
                            value: viewModel.maxHeartRate,
                            scaleFactor: 1.0
                        )
                    }
                }
            }
        }

    }

    @ViewBuilder
    private func measurementControls(isLandscape: Bool) -> some View {
        if viewModel.isCompleted {
            (isLandscape ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))) {
                if viewModel.canSaveMeasurement && !sharingService.isViewing {
                    Button {
                        saveCurrentRecord()
                    } label: {
                        Text(hasSavedRecord ? "Saved" : "Save")
                            .font(.headline)
                            .foregroundColor(hasSavedRecord ? .gray : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 30)
                    }
                    .disabled(hasSavedRecord || isSaving)
                }

                Button {
                    resetMeasurement(remoteAction: .hrvReset)
                    hasSavedRecord = false
                    savedRecordId = nil
                } label: {
                    Text("Reset")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .frame(minHeight: 30)
                }
                .disabled(sharingService.isViewing && !canSend(.hrvReset))
                .accessibilityIdentifier("resetHRVButton")
            }
            .bpmActionStyle()
            .bpmGlassGroup()
            .padding(.horizontal, isLandscape ? 0 : 24)
            .padding(.bottom, isLandscape ? 0 : 16)
        } else {
            // Measure HRV button
            Button {
                if viewModel.state == .idle && startReadiness.shouldConnectMonitor {
                    showDevicePicker = true
                } else if viewModel.hasError {
                    resetMeasurement(remoteAction: .hrvReset)
                } else if case .idle = viewModel.state {
                    // Check if this is the first measurement in this session
                    if !hasShownFirstTimeAlert {
                        showFirstTimeAlert = true
                        pendingMeasurement = true
                    } else {
                        // Start new measurement
                        startMeasurement()
                    }
                } else if viewModel.isCompleted {
                    // Start new measurement (clears existing one automatically)
                    startMeasurement()
                }
            } label: {
                Text(buttonText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .frame(minHeight: 30)
            }
            .disabled(measurementButtonDisabled)
            .accessibilityIdentifier("measureHRVButton")
            .bpmActionStyle()
            .bpmGlassGroup()
            .padding(.horizontal, isLandscape ? 0 : 24)
            .padding(.bottom, isLandscape ? 0 : 16)
        }
    }

    private var statusMessage: String? {
        if sharingService.isViewing {
            if let error = sharingService.workoutControlError { return error }
            if sharingService.isWorkoutControlPending { return "Sending change…" }
            if !sharingService.friendWorkoutIsFresh || sharingService.friendWorkout?.hrv == nil {
                return "Waiting for measurement updates…"
            }
        }
        return viewModel.state == .idle && !startReadiness.isReady ? startReadiness.message : nil
    }

    private var measurementButtonDisabled: Bool {
        if sharingService.isViewing {
            return !canSend(viewModel.hasError ? .hrvReset : .hrvStart)
        }
        return viewModel.state == .countingDown ||
            (viewModel.state == .idle && !startReadiness.isReady && !startReadiness.shouldConnectMonitor)
    }

    private func canSend(_ action: SharedWorkoutAction) -> Bool {
        sharingService.friendWorkoutIsFresh && !sharingService.isWorkoutControlPending &&
            sharingService.friendWorkout?.permits(action) == true
    }

    private func startMeasurement() {
        if sharingService.isViewing {
            Task { await sharingService.requestWorkoutControl(.hrvStart) }
        } else {
            viewModel.startMeasurement()
        }
    }

    private func resetMeasurement(remoteAction: SharedWorkoutAction) {
        if sharingService.isViewing {
            Task { await sharingService.requestWorkoutControl(remoteAction) }
        } else {
            viewModel.reset()
        }
    }

    private func configureMeasurementSource() {
        if sharingService.isViewing {
            viewModel.mirrorSharedMeasurement(sharingService.friendWorkout?.hrv,
                                            age: sharingService.friendWorkoutPresentationAge)
        } else {
            viewModel.configureLocalSource(bluetoothManager)
            viewModel.startLiveHeartRateUpdates()
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0) -> some View {
        VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: 20 * scaleFactor, weight: .semibold))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: 36 * scaleFactor, weight: .bold, design: .monospaced))
                .foregroundColor((value == nil && customText == nil) ? .gray : .white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func topBarCircleIcon(systemName: String, color: Color = .white, accessibilityLabel: String? = nil) -> some View {
        Image(systemName: systemName)
            .font(.system(size: TopBarLayout.iconFontSize))
            .foregroundColor(color)
            .frame(width: TopBarLayout.iconSize, height: TopBarLayout.iconSize)
            .bpmCircleSurface()
            .accessibilityLabel(accessibilityLabel ?? systemName)
    }

    @ViewBuilder
    private func historySheet() -> some View {
        NavigationStack {
            HRVHistoryView(store: hrvStore)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showHistory = false
                        }
                    }
                }
        }
    }

    private func saveCurrentRecord() {
        guard !sharingService.isViewing, viewModel.canSaveMeasurement else { return }
        guard let record = viewModel.hrvRecord(recordId: savedRecordId) else { return }
        guard !isSaving else { return }
        let savingRevision = viewModel.sharingRevision
        isSaving = true
        hrvStore.saveRecord(record) { saved in
            isSaving = false
            guard saved else {
                saveError = "Your measurement is still here. Please try saving again."
                return
            }
            AppAnalytics.signal(.hrvSave)
            showSaveFeedback("HRV saved")
            if viewModel.sharingRevision == savingRevision {
                viewModel.reset()
                hasSavedRecord = false
                savedRecordId = nil
            }
        }
    }

    @MainActor
    private func showSaveFeedback(_ message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        saveFeedbackDismissTask?.cancel()
        withAnimation {
            saveFeedbackMessage = message
        }
        saveFeedbackDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation {
                saveFeedbackMessage = nil
            }
            saveFeedbackDismissTask = nil
        }
    }
}
