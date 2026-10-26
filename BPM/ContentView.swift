//
//  ContentView.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI
import UIKit

enum AppMode {
    case myDevice
    case friendCode
}

private enum HeartRateExtremumDisplay {
    case max
    case min

    var title: String {
        switch self {
        case .max:
            return "MAX"
        case .min:
            return "MIN"
        }
    }

    mutating func cycle() {
        self = self == .max ? .min : .max
    }
}

private enum CollapsedStatDisplay {
    case max
    case min
    case avg

    var title: String {
        switch self {
        case .max:
            return "MAX"
        case .min:
            return "MIN"
        case .avg:
            return "AVG"
        }
    }

    mutating func cycle() {
        switch self {
        case .max:
            self = .min
        case .min:
            self = .avg
        case .avg:
            self = .max
        }
    }
}

private enum TimerViewMode: String, CaseIterable, Hashable {
    case table
    case bpm
    case stats
    case chart
}

private enum SetTableBpmDisplay {
    case avg
    case max

    var title: String {
        switch self {
        case .avg:
            return "Avg BPM"
        case .max:
            return "Max BPM"
        }
    }

    mutating func toggle() {
        self = self == .avg ? .max : .avg
    }
}

private struct HealthKitSyncBannerState {
    let message: String
    let workoutId: UUID
    let activityOption: HealthKitActivityOption
}

enum ViewDefaultsKey {
    static let timerMode = "BPM_View_TimerMode"
}

private struct SetConfirmationOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @State private var flashOpacity = 0.0

    var body: some View {
        Color.white.opacity(flashOpacity).ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            flashOpacity = reduceMotion || dimFlashingLights ? 0 : 0.16
            do {
                try await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.4)) {
                    flashOpacity = 0
                }
            } catch {
                // A new tap or leaving the workout cancels this confirmation.
            }
        }
    }
}


struct HeartRateDisplayView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @StateObject private var sharingService = SharingService.shared
    @StateObject private var timerViewModel = TimerViewModel()
    @StateObject private var hrvViewModel = HRVMeasurementViewModel()
    @State private var showDevicePicker = false
    @State private var appMode: AppMode = .myDevice
    @State private var isTimerMode = false
    @State private var isHRVMode = false
    @State private var showClearAlert = false
    @State private var showResetAlert = false
    @State private var showWorkoutStartAlert = false
    @State private var pendingRecoverySessionID: UUID?
    @State private var showDisconnectAlert = false
    @State private var heartRateExtremumDisplay: HeartRateExtremumDisplay = .max
    @State private var collapsedStatDisplay: CollapsedStatDisplay = .max
    @AppStorage(ViewDefaultsKey.timerMode) private var timerViewModeRawValue = TimerViewMode.table.rawValue
    @AppStorage(HealthKitWorkoutTypeDefaultsKey.quickSelection)
    private var healthKitQuickTypesRawValue = HealthKitWorkoutTypeSettings.defaultQuickSelectionRawValue()
    @State private var showPresetSheet = false
    @State private var showSettings = false
    @State private var showWorkoutHistory = false
    @StateObject private var zoneStorage = HeartRateZoneStorage.shared
    @State private var pendingWorkoutShare: SavedWorkoutShareRequest?
    @State private var savedWorkoutShare: SavedWorkoutShareRequest?
    @State private var hasSavedWorkout = false
    @State private var savedWorkoutId: UUID?
    @State private var showWorkoutTitlePrompt = false
    @State private var workoutTitleText = ""
    @State private var workoutNotesText = ""
    @StateObject private var workoutStore = WorkoutStore.shared
    @StateObject private var healthKitSyncService = HealthKitWorkoutSyncService.shared
    @State private var hasChangedTimerViewModeInSession = false
    @State private var showWorkoutTypePicker = false
    @State private var pendingHealthKitSelectionFromSheet: HealthKitActivityOption?
    @State private var pendingHealthKitActivityOption: HealthKitActivityOption = .functionalStrength
    @State private var healthKitSyncBannerState: HealthKitSyncBannerState?
    @State private var isHealthKitSyncInFlight = false
    @State private var workoutSaveBannerMessage: String?
    @State private var workoutSaveBannerDismissTask: Task<Void, Never>?
    @State private var setTableBpmDisplay: SetTableBpmDisplay = .avg
    @State private var setConfirmation: UUID?

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var shouldShowTenthsInTimer: Bool {
        var total = max(timerViewModel.elapsedTime, timerViewModel.frozenElapsedTime)
        if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
            total = max(total, timerViewModel.frozenElapsedTime + timerViewModel.currentSetTime)
        }
        return total < 3600
    }

    private var timerViewMode: TimerViewMode {
        TimerViewMode(rawValue: timerViewModeRawValue) ?? .table
    }

    private var timerViewModeSelection: Binding<TimerViewMode> {
        Binding(
            get: { timerViewMode },
            set: { mode in
                guard timerViewModeRawValue != mode.rawValue else { return }
                timerViewModeRawValue = mode.rawValue
                hasChangedTimerViewModeInSession = true
            }
        )
    }

    private var isTimerEmptyState: Bool {
        timerViewModel.state == .idle && timerViewModel.sets.isEmpty
    }

    private var configuredHealthKitQuickTypes: [HealthKitActivityOption] {
        HealthKitWorkoutTypeSettings.quickSelection(from: healthKitQuickTypesRawValue)
    }

    private var defaultHealthKitActivityOption: HealthKitActivityOption {
        configuredHealthKitQuickTypes.first ?? .functionalStrength
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                responsiveLayout(geometry: geometry)
                if isTimerMode, let setConfirmation {
                    SetConfirmationOverlay()
                        .id(setConfirmation)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let workoutSaveBannerMessage {
                        SuccessHUDView(message: workoutSaveBannerMessage)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                    if let healthKitSyncBannerState {
                        StatusBannerView(
                            style: .warning,
                            message: healthKitSyncBannerState.message,
                            actionTitle: isHealthKitSyncInFlight ? "Retrying..." : "Retry",
                            isActionDisabled: isHealthKitSyncInFlight,
                            action: retryFailedHealthKitSync
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, geometry.size.width > geometry.size.height ? 40 : 20)
                .padding(.top, TopBarLayout.topPadding + TopBarLayout.iconSize + 16)
            }
        }
        .onChange(of: timerViewModel.sets.isEmpty) { _, isEmpty in
            if isEmpty {
                hasSavedWorkout = false
                savedWorkoutId = nil
                healthKitSyncBannerState = nil
            }
        }
        .onChange(of: isTimerMode) { _, isActive in
            setConfirmation = nil
            if isActive && !hasChangedTimerViewModeInSession {
                timerViewModeRawValue = TimerViewMode.table.rawValue
            }
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView()
                .environmentObject(bluetoothManager)
                .environmentObject(sharingService)
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetConfigurationView(
                isPresented: $showPresetSheet,
                currentPresetId: timerViewModel.activePreset?.id,
                onLoadPreset: { preset in
                    timerViewModel.loadPreset(preset)
                },
                onClearPreset: {
                    timerViewModel.clearPreset()
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showWorkoutHistory) {
            workoutHistorySheet()
        }
        .sheet(isPresented: $showWorkoutTitlePrompt, onDismiss: dismissSaveWorkoutSheet) {
            saveWorkoutSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $savedWorkoutShare) { request in
            WorkoutShareDrawer(record: request.record)
        }
        .sheet(isPresented: $showWorkoutTypePicker, onDismiss: applyPendingHealthKitSelectionFromSheet) {
            workoutTypePickerSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.disabled)
        }
        .alert("Disconnect Sharing", isPresented: $showDisconnectAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect", role: .destructive) {
                sharingService.stopSharing()
            }
        } message: {
            Text("Are you sure you want to disconnect? You'll need to start a new session and share a new code.")
        }
        .onAppear {
            let bluetoothManager = self.bluetoothManager

            // Restore mode based on saved state
            if sharingService.isViewing {
                appMode = .friendCode
            } else {
                appMode = .myDevice
            }

            if timerViewModel.hasRestorableSession {
                isTimerMode = true
            }
            
            if appMode == .myDevice {
                bluetoothManager.startScanning()
                IdleTimer.disable()
            }
            healthKitSyncService.refreshAuthorizationState()
            healthKitQuickTypesRawValue = HealthKitWorkoutTypeSettings.encodedQuickSelection(
                HealthKitWorkoutTypeSettings.quickSelection(from: healthKitQuickTypesRawValue)
            )
            pendingHealthKitActivityOption = defaultHealthKitActivityOption
            
            timerViewModel.observeHeartRate(from: bluetoothManager)
            timerViewModel.currentHeartRate = { [weak bluetoothManager] in
                bluetoothManager?.freshHeartRate
            }
        }
        .onChange(of: appMode) { oldMode, newMode in
            if newMode == .myDevice {
                bluetoothManager.startScanning()
                IdleTimer.disable()
                sharingService.stopViewing()
            } else {
                bluetoothManager.stopScanning()
                IdleTimer.disable() // Keep screen on when viewing friend's heart rate
            }
            heartRateExtremumDisplay = .max
        }
        .onChange(of: sharingService.isViewing) { oldValue, newValue in
            if newValue && appMode == .myDevice && !oldValue {
                appMode = .friendCode
            }
        }
        .onDisappear {
            workoutSaveBannerDismissTask?.cancel()
            if appMode == .myDevice {
                bluetoothManager.stopScanning()
                IdleTimer.enable()
            } else {
                IdleTimer.enable() // Re-enable idle timer when leaving friend view
            }
        }
    }
    
    @ViewBuilder
    private func responsiveLayout(geometry: GeometryProxy) -> some View {
        if isHRVMode {
            HRVMeasurementView(viewModel: hrvViewModel, onDismiss: {
                isHRVMode = false
            })
                .environmentObject(bluetoothManager)
                .environmentObject(sharingService)
        } else if isTimerMode {
            timerModeLayout(geometry: geometry, isLandscape: geometry.size.width > geometry.size.height)
        } else if geometry.size.width > geometry.size.height {
            landscapeHomeLayout(geometry: geometry)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        topBarCircleIcon(systemName: "gearshape", accessibilityLabel: "Settings")
                    }
                }
                .padding(.horizontal, TopBarLayout.horizontalPadding)
                .padding(.top, TopBarLayout.topPadding)

                VStack(spacing: 8) {
                    connectionPrompt
                    bluetoothMessageDisplay
                    errorMessageDisplay
                    sharingCodeDisplay
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                GeometryReader { displayGeometry in
                    heartRateDisplay(size: displayGeometry.size)
                }
                statsBar(screenWidth: geometry.size.width)
            }
        }
    }
    
    private var sharingCodeDisplay: some View {
        Group {
            if appMode == .myDevice && sharingService.isSharing, let code = sharingService.shareCode {
                Text("SHARE CODE: \(formattedShareCode(code))")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if appMode == .friendCode && sharingService.isViewing, let code = sharingService.friendCode {
                Button {
                    showDevicePicker = true
                } label: {
                    Text("Viewing: \(formattedShareCode(code))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func heartRateDisplay(size: CGSize) -> some View {
        // Base font size anchored to screen height, but cap by width to fit 3 digits comfortably
        let baseFontSize: CGFloat = size.height * 0.65

        // Measure width of the widest expected value (three digits) at the base font size
        let referenceText = "888"
        let baseUIFont = UIFont.systemFont(ofSize: baseFontSize, weight: .bold)
        let baseWidth = referenceText.size(withAttributes: [.font: baseUIFont]).width

        // Leave some horizontal padding so the number never abuts the edges
        let horizontalAllowance: CGFloat = size.width * 0.9
        let fittedFontSize = baseWidth > 0
            ? min(baseFontSize, horizontalAllowance / baseWidth * baseFontSize)
            : baseFontSize

        let value = displayedHeartRate
        let text = value.map(String.init) ?? "---"
        let color: Color = value == nil ? .gray : .white

        Text(text)
            .font(.system(size: fittedFontSize, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Heart rate")
            .accessibilityValue(value.map { "\($0) beats per minute" } ?? "No current reading")
    }
    
    private var displayedHeartRate: Int? {
        if isTimerMode || appMode == .myDevice {
            return bluetoothManager.freshHeartRate
        } else {
            return sharingService.friendHeartRate
        }
    }

    private var heartButtonColor: Color {
        if bluetoothManager.hasActiveDataSource {
            return .green
        } else if appMode == .friendCode && sharingService.isViewing {
            return .green
        } else {
            return .white
        }
    }

    private var heartIconName: String {
        bluetoothManager.hasActiveDataSource ? "heart.fill" : "heart"
    }

    private func completedSummaryRow(totalTime: TimeInterval) -> some View {
        let labelSize: CGFloat = 14.0
        let valueSize: CGFloat = isPad ? 28.0 : 32.0
        let totalTimeValue = formatTime(totalTime, showTenths: false)
        let avgSetValue = timerViewModel.avgSetTime.map { formatTime($0, showTenths: shouldShowTenthsInTimer) } ?? "---"
        let avgBPMValue = timerViewModel.avgHeartRate.map(String.init) ?? "---"

        return timerSummaryRow([
            ("Total Time", totalTimeValue),
            ("Avg Work Set", avgSetValue),
            ("Avg BPM", avgBPMValue)
        ], labelSize: labelSize, valueSize: valueSize)
    }

    private var caloriesDisplayValue: String {
        guard appMode == .myDevice else { return "---" }
        switch timerViewModel.caloriesStatus {
        case .available(let estimate):
            return String(Int(round(estimate.totalKcal)))
        case .insufficient(let remaining):
            return isTimerEmptyState ? "---" : formatWaitTime(remaining)
        case .disabled:
            return "---"
        }
    }

    private func formatWaitTime(_ remaining: TimeInterval) -> String {
        let clamped = max(0, remaining)
        let totalSeconds = Int(ceil(clamped))
        return "\(totalSeconds)s"
    }

    private func valueTextColor(_ value: String, preferred: Color = .white) -> Color {
        value == "---" ? .gray : preferred
    }

    private func timerDisplayTimes() -> (total: TimeInterval, set: TimeInterval) {
        let isCooldown = timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused
        let isPresetMode = timerViewModel.isPresetMode
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)
        let setTime: TimeInterval = {
            if timerViewModel.isCompleted {
                return timerViewModel.avgSetTime ?? 0
            } else if isCooldown || (isPresetMode && timerViewModel.presetPhase == .cooldown) {
                return timerViewModel.presetPhaseTimeRemaining > 0 ? timerViewModel.presetPhaseTimeRemaining : max(0, 120.0 - timerViewModel.currentSetTime)
            } else if isPresetMode {
                return timerViewModel.presetPhaseTimeRemaining
            } else {
                return timerViewModel.currentSetTime
            }
        }()
        return (total: totalTime, set: setTime)
    }

    private func runningExpandedPanel(totalTime: TimeInterval, setTime: TimeInterval, isLandscape: Bool, containerSize: CGSize) -> some View {
        let isCompleted = timerViewModel.isCompleted
        let bpmValue = displayedHeartRate.map(String.init) ?? "---"
        let totalTimeValue = isTimerEmptyState ? "---" : formatTime(totalTime, showTenths: false)
        let setNumberTitle = isCompleted ? "Work Sets" : "Set Number"
        let setNumberValue = expandedSetNumberValue
        let setTimeTitle = isCompleted ? "Avg Work" : "Set Time"
        let setTimeValue: String = {
            if isTimerEmptyState {
                return "---"
            }
            if isCompleted {
                return timerViewModel.avgSetTime.map { formatTime($0, showTenths: false) } ?? "---"
            }
            return formatTime(setTime, showTenths: false)
        }()
        let maxBPMValue = timerViewModel.maxHeartRate.map(String.init) ?? "---"
        let avgBPMValue = timerViewModel.avgHeartRate.map(String.init) ?? "---"
        let caloriesValue = caloriesDisplayValue
        let zoneTitle = isCompleted ? "Top Zone" : "Zone"
        let zoneAndColor: (value: String, color: Color) = {
            if isCompleted {
                let topZone = timerViewModel
                    .timeInZones(config: zoneStorage.effectiveConfig)
                    .filter { $0.duration > 0 }
                    .max { lhs, rhs in
                        if lhs.duration == rhs.duration {
                            return lhs.zone.rawValue > rhs.zone.rawValue
                        }
                        return lhs.duration < rhs.duration
                    }?.zone
                return (topZone?.displayName ?? "---", topZone?.color ?? .gray)
            } else {
                let zone = zoneStorage.currentZone(for: displayedHeartRate)
                return (zone?.displayName ?? "---", zone?.color ?? .gray)
            }
        }()
        let horizontalPadding: CGFloat = isLandscape ? 14 : 8
        let verticalPadding: CGFloat = isLandscape ? 12 : 10
        let columnSpacing: CGFloat = isLandscape ? 12 : 10
        let rowSpacing: CGFloat = isLandscape ? 12 : 10
        let columnCount = isLandscape ? 4 : 2
        let rowCount = isLandscape ? 2 : 4
        let tileWidth = max(1, floor((containerSize.width - horizontalPadding * 2 - columnSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)))
        let tileHeight = max(1, floor((containerSize.height - verticalPadding * 2 - rowSpacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)))
        let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: columnSpacing), count: columnCount)

        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, alignment: .center, spacing: rowSpacing) {
                expandedMetricCell(title: "BPM", value: bpmValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: "Total Time", value: totalTimeValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: setNumberTitle, value: setNumberValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: setTimeTitle, value: setTimeValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: "Avg BPM", value: avgBPMValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: "Max BPM", value: maxBPMValue, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: zoneTitle, value: zoneAndColor.value, valueColor: zoneAndColor.color, tileWidth: tileWidth, tileHeight: tileHeight)
                expandedMetricCell(title: "Calories", value: caloriesValue, tileWidth: tileWidth, tileHeight: tileHeight)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private var expandedSetNumberValue: String {
        if timerViewModel.isCompleted {
            let totalWorkSets = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
            return String(totalWorkSets)
        }

        if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
            let nextCooldownNumber = timerViewModel.sets.filter { $0.isCooldownSet }.count + 1
            return "C\(nextCooldownNumber)"
        }

        if timerViewModel.state == .running || timerViewModel.state == .paused {
            if timerViewModel.isTimingRestSet {
                if let activeRestSet = timerViewModel.sets.last(where: { $0.isRestSet && !$0.isCooldownSet }),
                   let associatedWorkSetNumber = activeRestSet.associatedWorkSetNumber {
                    return "\(associatedWorkSetNumber)R"
                }
                let completedWorkSets = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
                return completedWorkSets > 0 ? "\(completedWorkSets)R" : "---"
            }
            let completedWorkSets = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
            return String(completedWorkSets + 1)
        }

        if let lastSet = timerViewModel.sets.last {
            return timerViewModel.displayLabel(for: lastSet)
        }
        return "---"
    }

    private func expandedMetricCell(title: String, value: String, valueColor: Color = .white, tileWidth: CGFloat, tileHeight: CGFloat) -> some View {
        let labelSize = max(8, tileHeight * 0.13)
        let valueSize = max(13, tileHeight * 0.38)
        let verticalInset = max(8, tileHeight * 0.08)
        return VStack(spacing: max(2, tileHeight * 0.04)) {
            Text(title)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(valueTextColor(value, preferred: valueColor))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalInset)
        .frame(width: tileWidth, height: tileHeight, alignment: .center)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Reserve real gaps and fit every value at the same size, including hour-long timers.
    private func timerSummaryRow(_ metrics: [(title: String, value: String)], labelSize: CGFloat = 14,
                                 valueSize: CGFloat = 32) -> some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 16
            let columnWidth = max(1, (geometry.size.width - spacing * 2) / 3)
            let font = UIFont.monospacedSystemFont(ofSize: valueSize, weight: .bold)
            let widestValue = metrics.map { $0.value.size(withAttributes: [.font: font]).width }.max() ?? 1
            let fittedSize = min(valueSize, valueSize * max(1, columnWidth - 8) / max(1, widestValue))

            HStack(alignment: .top, spacing: spacing) {
                ForEach(metrics.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text(metrics[index].title)
                            .font(.system(size: labelSize, weight: .medium))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(metrics[index].value)
                            .font(.system(size: fittedSize, weight: .bold, design: .monospaced))
                            .foregroundColor(valueTextColor(metrics[index].value))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: valueSize * 1.2)
                    }
                    .frame(width: columnWidth)
                }
            }
        }
        .frame(height: labelSize * 1.2 + 6 + valueSize * 1.2)
        .padding(.horizontal, 20)
    }

    private struct LineChartIcon: View {
        let color: Color

        var body: some View {
            GeometryReader { geometry in
                let size = geometry.size
                let scale = min(size.width / 165.0, size.height / 165.0)
                let xOffset = (size.width - 165.0 * scale) / 2.0
                let yOffset = (size.height - 165.0 * scale) / 2.0
                let lineWidth = 15.0 * scale

                Path { path in
                    path.move(to: CGPoint(x: xOffset + 17.5 * scale, y: yOffset + 132.0 * scale))
                    path.addLine(to: CGPoint(x: xOffset + 57.5 * scale, y: yOffset + 78.5 * scale))
                    path.addLine(to: CGPoint(x: xOffset + 93.0 * scale, y: yOffset + 97.1603 * scale))
                    path.addLine(to: CGPoint(x: xOffset + 130.0 * scale, y: yOffset + 47.0 * scale))
                }
                .stroke(color, lineWidth: lineWidth)

                Path { path in
                    path.move(to: CGPoint(x: xOffset + 142.108 * scale, y: yOffset + 30.1184 * scale))
                    path.addLine(to: CGPoint(x: xOffset + 142.728 * scale, y: yOffset + 57.0924 * scale))
                    path.addLine(to: CGPoint(x: xOffset + 116.253 * scale, y: yOffset + 37.8348 * scale))
                    path.closeSubpath()
                }
                .fill(color)
            }
        }
    }

    private struct BarsChartIcon: View {
        let color: Color

        var body: some View {
            GeometryReader { geometry in
                let size = geometry.size
                let barHeight = size.height * 0.18
                let spacing = size.height * 0.14
                VStack(alignment: .leading, spacing: spacing) {
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(color)
                        .frame(width: size.width * 0.9, height: barHeight)
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(color)
                        .frame(width: size.width * 0.7, height: barHeight)
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(color)
                        .frame(width: size.width * 0.5, height: barHeight)
                }
                .frame(width: size.width, height: size.height, alignment: .center)
            }
        }
    }

    private func formattedShareCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    private func myDeviceExtremumValue(for display: HeartRateExtremumDisplay) -> Int? {
        switch display {
        case .max:
            return bluetoothManager.maxHeartRateLastHour
        case .min:
            return bluetoothManager.minHeartRateLastHour
        }
    }

    private func friendExtremumValue(for display: HeartRateExtremumDisplay) -> Int? {
        switch display {
        case .max:
            return sharingService.friendMaxHeartRate
        case .min:
            return sharingService.friendMinHeartRate
        }
    }

    private func cycleHeartRateExtremumDisplay() {
        heartRateExtremumDisplay.cycle()
    }
    
    private func myDeviceCollapsedStatValue(for display: CollapsedStatDisplay) -> Int? {
        switch display {
        case .max:
            return bluetoothManager.maxHeartRateLastHour
        case .min:
            return bluetoothManager.minHeartRateLastHour
        case .avg:
            return bluetoothManager.avgHeartRateLastHour
        }
    }
    
    private func friendCollapsedStatValue(for display: CollapsedStatDisplay) -> Int? {
        switch display {
        case .max:
            return sharingService.friendMaxHeartRate
        case .min:
            return sharingService.friendMinHeartRate
        case .avg:
            return sharingService.friendAvgHeartRate
        }
    }
    
    private func cycleCollapsedStatDisplay() {
        collapsedStatDisplay.cycle()
    }
    
    @ViewBuilder
    private var errorMessageDisplay: some View {
        if let error = sharingService.errorMessage, shouldShowError(for: appMode) {
            Text(error)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var connectionPrompt: some View {
        if shouldShowConnectionPrompt {
            Text("No device connected. Tap Device to connect.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var bluetoothMessageDisplay: some View {
        if appMode == .myDevice, let message = bluetoothManager.connectionMessage {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var shouldShowConnectionPrompt: Bool {
        let hasDeviceConnection = bluetoothManager.hasActiveDataSource
        let hasFriendConnection = sharingService.isViewing && sharingService.friendCode != nil
        return !hasDeviceConnection && !hasFriendConnection
    }
    

    private func statsBar(screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        return VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
            homeStatistics(isLandscape: false, scaleFactor: scaleFactor)
            homeButtons(screenWidth: screenWidth, isLandscape: false)
        }
        .padding(.horizontal, max(12.0, 20.0 * scaleFactor))
        .padding(.vertical, max(12.0, 16.0 * scaleFactor))
        .background(Color.black.opacity(0.8))
    }

    private func homeStatistics(isLandscape: Bool, scaleFactor: CGFloat = 1) -> some View {
        HStack(spacing: 0) {
            statColumn(title: "Avg", value: appMode == .myDevice ? bluetoothManager.avgHeartRateLastHour : sharingService.friendAvgHeartRate, scaleFactor: scaleFactor, isLandscape: isLandscape)
                .frame(maxWidth: .infinity)
            statColumn(title: "Min", value: appMode == .myDevice ? bluetoothManager.minHeartRateLastHour : sharingService.friendMinHeartRate, scaleFactor: scaleFactor, isLandscape: isLandscape)
                .frame(maxWidth: .infinity)
            statColumn(title: "Max", value: appMode == .myDevice ? bluetoothManager.maxHeartRateLastHour : sharingService.friendMaxHeartRate, scaleFactor: scaleFactor, isLandscape: isLandscape)
                .frame(maxWidth: .infinity)
            if appMode == .myDevice {
                zoneStatColumn(heartRate: displayedHeartRate, scaleFactor: scaleFactor, isLandscape: isLandscape)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func landscapeHomeLayout(geometry: GeometryProxy) -> some View {
        HStack(spacing: 20) {
            VStack(spacing: 8) {
                VStack(spacing: 6) {
                    connectionPrompt
                    bluetoothMessageDisplay
                    errorMessageDisplay
                    sharingCodeDisplay
                }
                GeometryReader { proxy in
                    heartRateDisplay(size: proxy.size)
                }
                homeStatistics(isLandscape: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GeometryReader { controlsGeometry in
                ScrollView {
                    VStack(spacing: 12) {
                        Button {
                            showSettings = true
                        } label: {
                            topBarCircleIcon(systemName: "gearshape", accessibilityLabel: "Settings")
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        homeButtons(screenWidth: geometry.size.width, isLandscape: true)
                    }
                    .frame(minHeight: controlsGeometry.size.height, alignment: .center)
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: landscapeControlsWidth(for: geometry.size.width))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func landscapeControlsWidth(for width: CGFloat) -> CGFloat {
        min(200, max(150, width * 0.23))
    }

    @ViewBuilder
    private func homeButtons(screenWidth: CGFloat, isLandscape: Bool) -> some View {
        BPMGlassContainer {
            if dynamicTypeSize.isAccessibilitySize && !isLandscape {
                VStack(spacing: 8) {
                    homeButtonContent(screenWidth: screenWidth, isLandscape: false)
                }
            } else {
                let layout = isLandscape
                    ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    homeButtonContent(screenWidth: screenWidth, isLandscape: isLandscape)
                }
            }
        }
        .bpmActionStyle()
    }

    @ViewBuilder
    private func homeButtonContent(screenWidth: CGFloat, isLandscape: Bool) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let scaledButtonSize = isLandscape ? 20 : max(20.0, 24.0 * scaleFactor)
        let scaledButtonPadding: CGFloat = isLandscape ? 0 : 6
        Button {
            showDevicePicker = true
        } label: {
            (isLandscape || dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))) {
                Image(systemName: heartIconName)
                    .font(.system(size: scaledButtonSize))
                    .frame(height: scaledButtonSize + 3)
                Text("Device")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(heartButtonColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, scaledButtonPadding)
            .frame(minHeight: 30)
        }

        Button {
            if sharingService.isSharing {
                showDisconnectAlert = true
            } else {
                Task {
                    if !bluetoothManager.hasActiveDataSource {
                        sharingService.errorMessage = "Please connect a heart rate device before sharing."
                        sharingService.errorContext = .sharing
                    } else {
                        do {
                            try await sharingService.startSharing()
                        } catch {
                            // Error handled by sharingService
                        }
                    }
                }
            }
        } label: {
            (isLandscape || dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: scaledButtonSize))
                    .frame(height: scaledButtonSize + 3)
                Text("Share")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(appMode == .friendCode ? .gray : (sharingService.isSharing ? .green : .white))
            .frame(maxWidth: .infinity)
            .padding(.vertical, scaledButtonPadding)
            .frame(minHeight: 30)
        }
        .disabled(appMode == .friendCode)

        Button {
            isTimerMode.toggle()
            if !isTimerMode {
                timerViewModel.reset()
            }
        } label: {
            (isLandscape || dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))) {
                Image(systemName: "stopwatch")
                    .renderingMode(.template)
                    .font(.system(size: scaledButtonSize))
                    .frame(height: scaledButtonSize + 3)
                Text("Workout")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(isTimerMode ? .green : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, scaledButtonPadding)
            .frame(minHeight: 30)
        }

        Button {
            isHRVMode.toggle()
            if !isHRVMode {
                hrvViewModel.reset()
            }
        } label: {
            (isLandscape || dynamicTypeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))) {
                Image(systemName: "waveform.path.ecg")
                    .renderingMode(.template)
                    .font(.system(size: scaledButtonSize))
                    .frame(height: scaledButtonSize + 3)
                Text("HRV")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(isHRVMode ? .green : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, scaledButtonPadding)
            .frame(minHeight: 30)
        }
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0, isLandscape: Bool = false, onTap: (() -> Void)? = nil) -> some View {
        // Use same font sizes as timer bar stats
        let labelSize: CGFloat = 14.0
        let valueSize: CGFloat = isLandscape ? 24.0 : 32.0
        let displayValue = customText ?? value.map(String.init) ?? "---"
        return VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(.gray)
            Text(displayValue)
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(valueTextColor(displayValue))
                .frame(minWidth: 60 * scaleFactor) // Ensure enough width for triple digits
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(OptionalTapModifier(onTap: onTap))
    }

    private struct OptionalTapModifier: ViewModifier {
        let onTap: (() -> Void)?

        func body(content: Content) -> some View {
            if let onTap {
                content
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else {
                content
            }
        }
    }

    private func zoneStatColumn(heartRate: Int?, scaleFactor: Double, isLandscape: Bool) -> some View {
        let labelSize: CGFloat = 14.0
        let valueSize: CGFloat = isLandscape ? 24.0 : 32.0
        let zone = zoneStorage.currentZone(for: heartRate)

        return VStack(spacing: 4 * scaleFactor) {
            Text("Zone")
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(.gray)
            Text(zone?.displayName ?? "---")
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(zone?.color ?? .gray)
                .frame(minWidth: 40 * scaleFactor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shouldShowError(for mode: AppMode) -> Bool {
        guard let context = sharingService.errorContext else {
            return true
        }
        
        switch (mode, context) {
        case (.myDevice, .sharing), (.friendCode, .viewing):
            return true
        default:
            return false
        }
    }

    // MARK: - Timer Mode UI
    
    @ViewBuilder
    private func landscapeStatColumn(title: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(valueTextColor(value))
                .frame(minWidth: alignment == .center ? 90 : 100, alignment: alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
        }
    }
    
    @ViewBuilder
    private func landscapeBPMOrHRRColumn(isCompleted: Bool) -> some View {
        if isCompleted {
            VStack(alignment: .center, spacing: 4) {
                Text("HRR")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                Text(timerViewModel.heartRateRecovery.map(String.init) ?? "---")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(valueTextColor(timerViewModel.heartRateRecovery.map(String.init) ?? "---"))
                    .frame(minWidth: 50, alignment: .center)
            }
        } else {
            VStack(alignment: .center, spacing: 4) {
                Text("BPM")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                Text(displayedHeartRate.map(String.init) ?? "---")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(valueTextColor(displayedHeartRate.map(String.init) ?? "---"))
                    .frame(minWidth: 50, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func landscapeZoneColumn() -> some View {
        let zone = zoneStorage.currentZone(for: displayedHeartRate)
        VStack(alignment: .trailing, spacing: 4) {
            Text("Zone")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.gray)
            Text(zone?.displayName ?? "---")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(zone?.color ?? .gray)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showSettings = true
        }
    }

    @ViewBuilder
    private func timerModeLayout(geometry: GeometryProxy, isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            // Top bar with device picker, view settings, and clear button
            HStack(spacing: TopBarLayout.buttonSpacing) {
                Button {
                    // Only show alert if there's workout data to lose
                    if hasSavedWorkout {
                        timerViewModel.reset()
                        isTimerMode = false
                    } else if !timerViewModel.sets.isEmpty || timerViewModel.state != .idle {
                        showClearAlert = true
                    } else {
                        timerViewModel.reset()
                        isTimerMode = false
                    }
                } label: {
                    topBarCircleIcon(systemName: "xmark", accessibilityLabel: "Close workout")
                        .accessibilityIdentifier("xmark")
                }

                Spacer()

                HStack(spacing: TopBarLayout.buttonSpacing) {
                    Button {
                        showDevicePicker = true
                    } label: {
                        topBarCircleIcon(
                            systemName: heartIconName,
                            color: heartButtonColor,
                            accessibilityLabel: "Device Picker"
                        )
                    }

                    Button {
                        showWorkoutHistory = true
                    } label: {
                        topBarCircleIcon(
                            systemName: "clock.arrow.circlepath",
                            accessibilityLabel: "Workout History"
                        )
                    }

                    Button {
                        showSettings = true
                    } label: {
                        topBarCircleIcon(
                            systemName: "gearshape",
                            accessibilityLabel: "Settings"
                        )
                    }
                }
                .frame(width: TopBarLayout.trailingButtonGroupWidth, alignment: .trailing)
            }
            .bpmGlassGroup()
            .padding(.horizontal, TopBarLayout.horizontalPadding)
            .padding(.top, TopBarLayout.topPadding)
            .alert("Start Workout", isPresented: $showWorkoutStartAlert) {
                Button("Start from now") {
                    pendingRecoverySessionID = nil
                    timerViewModel.start()
                }
                Button("Include previous measurements") {
                    timerViewModel.start(includingPreviousMeasurementsFrom: pendingRecoverySessionID)
                    pendingRecoverySessionID = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRecoverySessionID = nil
                }
            } message: {
                Text("Include available measurements from this sensor session (up to the last hour), or start now? Including them starts the workout at the earliest included measurement.")
            }
            .alert("Clear Workout", isPresented: $showClearAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    timerViewModel.reset()
                    isTimerMode = false
                }
            } message: {
                Text("Are you sure you want to clear all workout data? This cannot be undone.")
            }
            .alert("Reset Workout", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    timerViewModel.reset()
                }
            } message: {
                Text("Are you sure you want to reset? This will clear all workout data.")
            }

            let contentLayout = isLandscape
                ? AnyLayout(HStackLayout(spacing: 16))
                : AnyLayout(VStackLayout(spacing: 0))
            contentLayout {
                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        timerPages(size: proxy.size, isLandscape: isLandscape)
                    }
                    timerViewPageDots(isLandscape: isLandscape)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isLandscape {
                    GeometryReader { controlsGeometry in
                        ScrollView {
                            timerControlButtons(isLandscape: true, screenWidth: geometry.size.width)
                                .frame(minHeight: controlsGeometry.size.height, alignment: .center)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .frame(width: landscapeControlsWidth(for: geometry.size.width))
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                } else {
                    timerControlButtons(isLandscape: false, screenWidth: geometry.size.width)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
            }

        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func timerPages(size: CGSize, isLandscape: Bool) -> some View {
        TabView(selection: timerViewModeSelection) {
            VStack(spacing: 0) {
                // Stopwatch display with BPM (or completion stats when done)
                stopwatchDisplay(isLandscape: isLandscape)
                    .padding(.top, isLandscape ? 8 : 18)

                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, isLandscape ? 12 : 20)
                    .padding(.top, isLandscape ? 8 : 16)

                setsTable(isLandscape: false, screenWidth: size.width)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .tag(TimerViewMode.table)

            GeometryReader { proxy in
                heartRateDisplay(size: proxy.size)
            }
            .tag(TimerViewMode.bpm)

            GeometryReader { proxy in
                let times = timerDisplayTimes()
                runningExpandedPanel(
                    totalTime: times.total,
                    setTime: times.set,
                    isLandscape: isLandscape,
                    containerSize: proxy.size
                )
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .tag(TimerViewMode.stats)

            VStack(spacing: 0) {
                // Stopwatch display with BPM (or completion stats when done)
                stopwatchDisplay(isLandscape: isLandscape)
                    .padding(.top, isLandscape ? 8 : 18)

                GeometryReader { proxy in
                    let horizontalPadding: CGFloat = isLandscape ? 12 : 20
                    let chartSpacing: CGFloat = 12
                    let availableHeight = max(0, proxy.size.height - chartSpacing)
                    let panelHeight = isLandscape ? availableHeight : availableHeight / 2

                    (isLandscape ? AnyLayout(HStackLayout(spacing: chartSpacing)) : AnyLayout(VStackLayout(spacing: chartSpacing))) {
                        HeartRateChartView(timerViewModel: timerViewModel, isLandscape: isLandscape)
                            .frame(maxWidth: .infinity, maxHeight: panelHeight)

                        TimerTimeInZoneView(timerViewModel: timerViewModel, zoneStorage: zoneStorage, isLandscape: isLandscape)
                            .frame(maxWidth: .infinity, maxHeight: panelHeight, alignment: .top)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .tag(TimerViewMode.chart)
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    }

    private func timerViewPageDots(isLandscape: Bool) -> some View {
        HStack(spacing: isLandscape ? 8 : 9) {
            ForEach(TimerViewMode.allCases, id: \.self) { mode in
                Circle()
                    .fill(mode == timerViewMode ? Color.white : Color.gray.opacity(0.45))
                    .frame(width: isLandscape ? 6 : 7, height: isLandscape ? 6 : 7)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer view page: \(timerViewMode.rawValue)")
        .accessibilityValue("\((TimerViewMode.allCases.firstIndex(of: timerViewMode) ?? 0) + 1) of \(TimerViewMode.allCases.count)")
        .accessibilityAdjustableAction { direction in
            let modes = TimerViewMode.allCases
            guard let index = modes.firstIndex(of: timerViewMode) else { return }
            switch direction {
            case .increment where index < modes.count - 1:
                timerViewModeSelection.wrappedValue = modes[index + 1]
            case .decrement where index > 0:
                timerViewModeSelection.wrappedValue = modes[index - 1]
            default:
                break
            }
        }
    }
    
    @ViewBuilder
    private func stopwatchDisplay(isLandscape: Bool = false) -> some View {
        if isLandscape {
            compactWorkoutHeader()
        } else if isPad {
            landscapeStopwatchDisplay()
        } else {
            portraitStopwatchDisplay()
        }
    }
    
    private func compactWorkoutHeader() -> some View {
        let times = timerDisplayTimes()
        return timerSummaryRow([
            ("Total Time", isTimerEmptyState ? "---" : formatTime(times.total, showTenths: false)),
            (timerViewModel.isCompleted ? "Avg Work" : "Set Time",
             isTimerEmptyState ? "---" : formatTime(times.set, showTenths: shouldShowTenthsInTimer)),
            ("BPM", displayedHeartRate.map(String.init) ?? "---")
        ], labelSize: 12, valueSize: 28)
    }

    private func landscapeStopwatchDisplay() -> some View {
        portraitStopwatchDisplay()
    }

    @ViewBuilder
    private func portraitStopwatchDisplay() -> some View {
        let times = timerDisplayTimes()
        if timerViewModel.isCompleted {
            completedSummaryRow(totalTime: times.total)
        } else {
            timerSummaryRow([
                ("Total Time", isTimerEmptyState ? "---" : formatTime(times.total, showTenths: false)),
                ("Set Time", isTimerEmptyState ? "---" : formatTime(times.set, showTenths: shouldShowTenthsInTimer)),
                ("BPM", displayedHeartRate.map(String.init) ?? "---")
            ], valueSize: isPad ? 28 : 32)
        }
    }

    @ViewBuilder
    private func setsTable(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let fontSize = isLandscape ? 14.0 : max(16.0, 18.0 * scaleFactor)
        let headerFontSize: CGFloat = 14.0
        let columnSpacing: CGFloat = isLandscape ? 6.0 : max(6.0, 8.0 * scaleFactor)
        let columnCount = isLandscape ? 6 : 4 // 6 columns in landscape (add Max BPM and Min BPM), 4 in portrait
        let columnWidth = (screenWidth - (isLandscape ? 24 : 40) - 24 - (columnSpacing * CGFloat(columnCount - 1))) / CGFloat(columnCount) // Equal width columns
        let workSetCount = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
        let showDefaultEmptyRow = timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !timerViewModel.isPresetMode
        let showTenths = shouldShowTenthsInTimer
        let primaryBpmTitle = isLandscape ? "Avg BPM" : setTableBpmDisplay.title
        
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Spacer to account for pinned header
                        HStack(spacing: columnSpacing) {
                            Text("Set")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .center)
                            
                            Text("Time")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .center)
                            
                            Text(primaryBpmTitle)
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .center)
                            
                            if isLandscape {
                                Text("Min BPM")
                                    .font(.system(size: headerFontSize, weight: .semibold))
                                    .foregroundColor(.clear)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text("Max BPM")
                                    .font(.system(size: headerFontSize, weight: .semibold))
                                    .foregroundColor(.clear)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            
                            Text("Total")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .center)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("header")
                        
                        // Completed sets (actual recorded data)
                        ForEach(timerViewModel.sets) { set in
                            let isActiveRestSet = timerViewModel.isActiveRestSet(set)
                            let avgBPM = timerViewModel.displayAvgBPM(for: set)
                            let maxBPM = timerViewModel.displayMaxBPM(for: set)
                            let minBPM = timerViewModel.displayMinBPM(for: set)
                            let primaryBPM = (isLandscape || setTableBpmDisplay == .avg) ? avgBPM : maxBPM
                            let setTime = timerViewModel.displaySetTime(for: set)
                            let totalTime = timerViewModel.displayTotalTime(for: set)
                            let rowColor: Color = isActiveRestSet ? .white : .gray

                            HStack(spacing: columnSpacing) {
                                Text(timerViewModel.displayLabel(for: set))
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)

                                Text(formatTime(setTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)

                                Text(primaryBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(valueTextColor(primaryBPM.map(String.init) ?? "---", preferred: rowColor))
                                    .frame(width: columnWidth, alignment: .center)

                                if isLandscape {
                                    Text(minBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(minBPM.map(String.init) ?? "---", preferred: rowColor))
                                        .frame(width: columnWidth, alignment: .center)

                                    Text(maxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(maxBPM.map(String.init) ?? "---", preferred: rowColor))
                                        .frame(width: columnWidth, alignment: .center)
                                }

                                Text(formatTime(totalTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id(set.id)
                        }

                        if showDefaultEmptyRow {
                            let rowColor: Color = .gray.opacity(0.5)
                            HStack(spacing: columnSpacing) {
                                Text("1")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)

                                Text("---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)

                                Text("---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)

                                if isLandscape {
                                    Text("")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(rowColor)
                                        .frame(width: columnWidth, alignment: .center)

                                    Text("")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(rowColor)
                                        .frame(width: columnWidth, alignment: .center)
                                }

                                Text("---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id("empty-placeholder-1")
                        }

                        // Future placeholder rows for preset mode (grayed out)
                        if timerViewModel.isPresetMode && timerViewModel.state == .idle && timerViewModel.sets.isEmpty {
                            // Show all placeholders when not started
                            ForEach(timerViewModel.presetPlaceholderSets) { set in
                                presetPlaceholderRow(set: set, fontSize: fontSize, columnWidth: columnWidth, columnSpacing: columnSpacing, isLandscape: isLandscape, showTenths: showTenths)
                            }
                        }
                        
                        // Active set row (if timer is running or paused)
                        if (timerViewModel.state == .running || timerViewModel.state == .paused) && !timerViewModel.isTimingRestSet {
                            let nextSetNumber = workSetCount + 1
                            // Calculate avg BPM for current set so far
                            let currentAvgBPM = timerViewModel.avgBPMForCurrentSet()
                            // Calculate max BPM for current set so far
                            let currentMaxBPM = timerViewModel.maxBPMForCurrentSet()
                            // Calculate min BPM for current set so far
                            let currentMinBPM = timerViewModel.minBPMForCurrentSet()
                            let currentPrimaryBPM = (isLandscape || setTableBpmDisplay == .avg) ? currentAvgBPM : currentMaxBPM
                            
                            HStack(spacing: columnSpacing) {
                                Text("\(nextSetNumber)")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(formatTime(timerViewModel.currentSetTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(currentPrimaryBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(valueTextColor(currentPrimaryBPM.map(String.init) ?? "---"))
                                    .frame(width: columnWidth, alignment: .center)
                                
                                if isLandscape {
                                    Text(currentMinBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(currentMinBPM.map(String.init) ?? "---"))
                                        .frame(width: columnWidth, alignment: .center)
                                    
                                    Text(currentMaxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(currentMaxBPM.map(String.init) ?? "---"))
                                        .frame(width: columnWidth, alignment: .center)
                                }
                                
                                Text(formatTime(timerViewModel.elapsedTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id("active")
                        }
                        
                        // Active rest row (if in cooldown)
                        if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                            let cooldownSets = timerViewModel.sets.filter { $0.isCooldownSet }
                            let nextCooldownNumber = cooldownSets.count + 1
                            let currentHR = displayedHeartRate
                            let workoutTime = timerViewModel.frozenElapsedTime
                            let totalTime = workoutTime + timerViewModel.currentSetTime
                            // For cooldown, show current heart rate as avg (since it's a single point measurement)
                            let cooldownAvgBPM = currentHR
                            let cooldownMaxBPM = currentHR
                            let cooldownMinBPM = currentHR
                            
                            HStack(spacing: columnSpacing) {
                                Text("C\(nextCooldownNumber)")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(formatTime(timerViewModel.currentSetTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(cooldownAvgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(valueTextColor(cooldownAvgBPM.map(String.init) ?? "---"))
                                    .frame(width: columnWidth, alignment: .center)
                                
                                if isLandscape {
                                    Text(cooldownMinBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(cooldownMinBPM.map(String.init) ?? "---"))
                                        .frame(width: columnWidth, alignment: .center)
                                    
                                    Text(cooldownMaxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(valueTextColor(cooldownMaxBPM.map(String.init) ?? "---"))
                                        .frame(width: columnWidth, alignment: .center)
                                }
                                
                                Text(formatTime(totalTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id("activeRest")

                            if nextCooldownNumber == 1 {
                                let upcomingCooldownSet = SetRecord(
                                    setNumber: 2,
                                    setTime: 60,
                                    heartRate: nil,
                                    totalTime: timerViewModel.frozenElapsedTime + 120,
                                    isRestSet: true,
                                    isCooldownSet: true,
                                    associatedWorkSetNumber: nil
                                )
                                presetPlaceholderRow(
                                    set: upcomingCooldownSet,
                                    fontSize: fontSize,
                                    columnWidth: columnWidth,
                                    columnSpacing: columnSpacing,
                                    isLandscape: isLandscape,
                                    showTenths: showTenths
                                )
                            }
                        }

                        // Remaining future placeholder rows for preset mode (grayed out, shown after active row)
                        if timerViewModel.isPresetMode && (timerViewModel.state == .running || timerViewModel.state == .paused || timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused) {
                            let remainingPlaceholderSets = (timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused)
                                ? timerViewModel.remainingPresetPlaceholderSets.filter { !$0.isCooldownSet }
                                : timerViewModel.remainingPresetPlaceholderSets
                            ForEach(remainingPlaceholderSets) { set in
                                presetPlaceholderRow(set: set, fontSize: fontSize, columnWidth: columnWidth, columnSpacing: columnSpacing, isLandscape: isLandscape, showTenths: showTenths)
                            }
                        }
                    }
                }

                // Pinned header
                        HStack(spacing: columnSpacing) {
                            Text("Set")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.gray)
                                .frame(width: columnWidth, alignment: .center)
                            
                            Text("Time")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.gray)
                                .frame(width: columnWidth, alignment: .center)
                            
                            Text(primaryBpmTitle)
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.gray)
                                .frame(width: columnWidth, alignment: .center)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !isLandscape else { return }
                                    setTableBpmDisplay.toggle()
                                }
                            
                            if isLandscape {
                                Text("Min BPM")
                                    .font(.system(size: headerFontSize, weight: .semibold))
                                    .foregroundColor(.gray)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text("Max BPM")
                                    .font(.system(size: headerFontSize, weight: .semibold))
                                    .foregroundColor(.gray)
                                    .frame(width: columnWidth, alignment: .center)
                            }
                            
                            Text("Total")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.gray)
                                .frame(width: columnWidth, alignment: .center)
                        }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.9))
            }
            .onChange(of: timerViewModel.sets.count) { _, _ in
                if isLandscape {
                    // In landscape, always scroll to active row
                    scrollToActiveRow(proxy: proxy, isLandscape: isLandscape)
                } else {
                    // In portrait, scroll to most recent set
                    if let lastSet = timerViewModel.sets.last {
                        withAnimation {
                            proxy.scrollTo(lastSet.id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: timerViewModel.state) { _, _ in
                scrollToActiveRow(proxy: proxy, isLandscape: isLandscape)
            }
            .onChange(of: timerViewModel.isTimingRestSet) { _, _ in
                scrollToActiveRow(proxy: proxy, isLandscape: isLandscape)
            }
            .onAppear {
                // Scroll to active row when view appears in landscape
                if isLandscape {
                    scrollToActiveRow(proxy: proxy, isLandscape: isLandscape)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(maxHeight: isLandscape ? 600 : 700)
    }
    
    private func scrollToActiveRow(proxy: ScrollViewProxy, isLandscape: Bool) {
        guard isLandscape else { return }
        
        withAnimation {
            if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                proxy.scrollTo("activeRest", anchor: .center)
            } else if timerViewModel.state == .running || timerViewModel.state == .paused {
                if timerViewModel.isTimingRestSet {
                    // Find the active rest set
                    if let activeRestSet = timerViewModel.sets.first(where: { timerViewModel.isActiveRestSet($0) }) {
                        proxy.scrollTo(activeRestSet.id, anchor: .center)
                    } else {
                        proxy.scrollTo("active", anchor: .center)
                    }
                } else {
                    proxy.scrollTo("active", anchor: .center)
                }
            }
        }
    }

    private func saveWorkoutSheet() -> some View {
        WorkoutCaptureView(title: $workoutTitleText, notes: $workoutNotesText,
                           prepareAudio: timerViewModel.prepareForWorkoutDictation) {
            let trimmed = workoutTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = timerViewModel.defaultWorkoutTitle ?? pendingHealthKitActivityOption.title
            try await saveCurrentWorkout(
                title: trimmed.isEmpty ? fallbackTitle : trimmed,
                notes: workoutNotesText,
                activityOption: pendingHealthKitActivityOption
            )
        }
    }

    @ViewBuilder
    private func workoutHistorySheet() -> some View {
        NavigationStack {
            WorkoutHistoryView(store: workoutStore)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showWorkoutHistory = false
                        }
                    }
                }
        }
    }

    private func dismissSaveWorkoutSheet() {
        pendingHealthKitActivityOption = defaultHealthKitActivityOption
        workoutNotesText = ""
        if let request = pendingWorkoutShare {
            pendingWorkoutShare = nil
            // Finish any first-use Health permission sheet before presenting the share drawer.
            Task {
                await syncSavedWorkoutToHealthKit(record: request.record, activityOption: request.activityOption)
                savedWorkoutShare = request
            }
        }
    }

    private func workoutTypePickerSheet() -> some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    ForEach(configuredHealthKitQuickTypes) { option in
                        Button(option.title) {
                            selectHealthKitActivityFromSheet(option)
                        }
                    }
                }

                Section("All Workout Types") {
                    ForEach(HealthKitActivityOption.allCases.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { option in
                        Button(option.title) {
                            selectHealthKitActivityFromSheet(option)
                        }
                    }
                }
            }
            .navigationTitle("Workout Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showWorkoutTypePicker = false
                    }
                }
            }
        }
    }

    private func selectHealthKitActivityFromSheet(_ option: HealthKitActivityOption) {
        pendingHealthKitSelectionFromSheet = option
        showWorkoutTypePicker = false
    }

    private func applyPendingHealthKitSelectionFromSheet() {
        guard let option = pendingHealthKitSelectionFromSheet else { return }
        pendingHealthKitSelectionFromSheet = nil
        selectHealthKitActivity(option)
    }

    private func selectHealthKitActivity(_ option: HealthKitActivityOption) {
        pendingHealthKitActivityOption = option
        workoutTitleText = timerViewModel.defaultWorkoutTitle ?? option.title
        workoutNotesText = ""
        showWorkoutTitlePrompt = true
    }

    @MainActor
    private func saveCurrentWorkout(title: String?, notes: String?, activityOption: HealthKitActivityOption) async throws {
        guard let record = timerViewModel.workoutRecord(
            zoneConfig: zoneStorage.effectiveConfig,
            workoutId: savedWorkoutId,
            title: title,
            notes: notes
        ) else {
            throw WorkoutStore.DetailEditError.saveFailed
        }
        let saved: WorkoutRecord = try await withCheckedThrowingContinuation { continuation in
            workoutStore.saveWorkout(record) { continuation.resume(with: $0) }
        }
        AppAnalytics.signal(.workoutSave)
        savedWorkoutId = saved.id
        hasSavedWorkout = true
        pendingWorkoutShare = SavedWorkoutShareRequest(record: saved, activityOption: activityOption)
        timerViewModel.reset()
        isTimerMode = false
    }

    @MainActor
    private func syncSavedWorkoutToHealthKit(record: WorkoutRecord, activityOption: HealthKitActivityOption) async {
        if record.healthKitWorkoutUUID != nil {
            healthKitSyncBannerState = nil
            return
        }

        isHealthKitSyncInFlight = true
        defer { isHealthKitSyncInFlight = false }

        do {
            let result = try await healthKitSyncService.syncWorkout(
                record: record,
                activityType: activityOption.workoutType
            )
            workoutStore.updateHealthKitSync(
                for: record.id,
                workoutUUID: result.workoutUUID,
                syncedAt: Date(),
                lastError: nil
            )
            healthKitSyncBannerState = nil
        } catch let syncError as HealthKitSyncError {
            workoutStore.updateHealthKitSync(
                for: record.id,
                workoutUUID: nil,
                syncedAt: nil,
                lastError: syncError.userFacingMessage
            )
            healthKitSyncBannerState = HealthKitSyncBannerState(
                message: syncError.userFacingMessage,
                workoutId: record.id,
                activityOption: activityOption
            )
        } catch {
            let message = "Could not save workout to Apple Health: \(error.localizedDescription)"
            workoutStore.updateHealthKitSync(
                for: record.id,
                workoutUUID: nil,
                syncedAt: nil,
                lastError: message
            )
            healthKitSyncBannerState = HealthKitSyncBannerState(
                message: message,
                workoutId: record.id,
                activityOption: activityOption
            )
        }
    }

    @MainActor
    private func retryFailedHealthKitSync() {
        guard let bannerState = healthKitSyncBannerState else { return }
        guard let record = workoutStore.workouts.first(where: { $0.id == bannerState.workoutId }) else {
            healthKitSyncBannerState = nil
            return
        }

        Task {
            await syncSavedWorkoutToHealthKit(record: record, activityOption: bannerState.activityOption)
        }
    }

    @MainActor
    private func showWorkoutSaveFeedback(_ message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        workoutSaveBannerDismissTask?.cancel()
        withAnimation {
            workoutSaveBannerMessage = message
        }
        workoutSaveBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation {
                workoutSaveBannerMessage = nil
            }
            workoutSaveBannerDismissTask = nil
        }
    }
    
    @ViewBuilder
    private func timerControlButtons(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let buttonSpacing = isLandscape ? 8.0 : max(12.0, 16.0 * scaleFactor)
        let buttonPadding = isLandscape ? 0.0 : max(20.0, 24.0 * scaleFactor)
        let buttonFontSize = isLandscape ? 16.0 : max(14.0, 18.0 * scaleFactor)
        let buttonPaddingSize = isLandscape ? 8.0 : max(12.0, 16.0 * scaleFactor)
        let rowLayout = isLandscape ? AnyLayout(VStackLayout(spacing: buttonSpacing)) : AnyLayout(HStackLayout(spacing: buttonSpacing))
        let isCooldownDisabled = timerViewModel.state == .idle && !timerViewModel.isPresetMode
        let isInCooldownMode = timerViewModel.isInCooldownMode
        let isCompleted = timerViewModel.isCompleted
        let isPresetMode = timerViewModel.isPresetMode
        let isStartState = timerViewModel.state == .idle && timerViewModel.sets.isEmpty
        let presetName = timerViewModel.activePreset?.name.isEmpty == false ? (timerViewModel.activePreset?.name ?? "") : "Custom Preset"

        // Work Set and Rest Set are completely disabled in preset mode
        // Otherwise: Work Set is available while the workout timer is running (both work and rest phases)
        // Rest Set is available only during work phases
        let workSetDisabled = isPresetMode || timerViewModel.state != .running || isInCooldownMode || isCompleted
        let restSetDisabled = isPresetMode || timerViewModel.state != .running || isInCooldownMode || timerViewModel.isTimingRestSet || isCompleted
        
        if isCompleted {
            VStack(spacing: buttonSpacing) {
                Button {
                    pendingHealthKitActivityOption = defaultHealthKitActivityOption
                    pendingHealthKitSelectionFromSheet = nil
                    showWorkoutTypePicker = true
                } label: {
                    Text(hasSavedWorkout ? "Saved" : "Save Workout")
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor(hasSavedWorkout ? .gray : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 2)
                        .padding(.vertical, isLandscape ? 0 : 6)
                        .frame(minHeight: 30)
                }
                .frame(maxWidth: .infinity)
                .disabled(hasSavedWorkout)

                rowLayout {
                Button {
                    if hasSavedWorkout {
                        timerViewModel.reset()
                    } else {
                        showResetAlert = true
                    }
                } label: {
                        Text("Reset")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        timerViewModel.resumeEndedWorkout()
                    } label: {
                        Text("Resume")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("resumeEndedWorkout")
                }
            }
            .bpmActionStyle()
            .bpmGlassGroup()
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, isLandscape ? 4 : 20)
            .background(Color.black.opacity(0.8))
        } else if isStartState {
            VStack(spacing: buttonSpacing) {
                rowLayout {
                    Button {
                        if isPresetMode {
                            timerViewModel.startPreset()
                        } else if let sessionID = timerViewModel.recoverableSessionID {
                            pendingRecoverySessionID = sessionID
                            showWorkoutStartAlert = true
                        } else {
                            timerViewModel.start()
                        }
                    } label: {
                        Text("Start")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .bpmActionStyle(prominent: true)
                    .tint(.white)
                    .frame(maxWidth: .infinity)

                    Button {
                        showPresetSheet = true
                    } label: {
                        Text("Load Preset")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)
                }

                if !isPresetMode {
                    rowLayout {
                        Button {
                            timerViewModel.captureSet()
                            setConfirmation = UUID()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                Text("Work Set")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            }
                            .foregroundColor(workSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                        }
                        .disabled(workSetDisabled)
                        .frame(maxWidth: .infinity)

                        Button {
                            timerViewModel.captureRestSet()
                            setConfirmation = UUID()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                Text("Rest Set")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            }
                            .foregroundColor(restSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                        }
                        .disabled(restSetDisabled)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    presetNamePlaceholder(text: presetName, buttonFontSize: buttonFontSize, buttonPaddingSize: buttonPaddingSize)
                }
            }
            .bpmActionStyle()
            .bpmGlassGroup()
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, isLandscape ? 4 : 20)
            .background(Color.black.opacity(0.8))
        } else {
            // Stack each control on the right in landscape; use two rows in portrait.
            VStack(spacing: buttonSpacing) {
                // Top row: Start/Pause/Reset, End, Cool (Cool hidden in preset mode)
                rowLayout {
                    Button {
                        if timerViewModel.state == .running {
                            if isPresetMode {
                                timerViewModel.pausePreset()
                            } else {
                                timerViewModel.stop()
                            }
                        } else if timerViewModel.state == .cooldown {
                            // Pause cooldown (works for both preset and non-preset)
                            timerViewModel.toggleCooldown()
                        } else if timerViewModel.state == .cooldownPaused {
                            // Resume cooldown
                            timerViewModel.toggleCooldown()
                        } else if isCompleted {
                            if hasSavedWorkout {
                                timerViewModel.reset()
                            } else {
                                // Reset button - show confirmation alert
                                showResetAlert = true
                            }
                        } else if timerViewModel.state == .paused {
                            if isPresetMode {
                                timerViewModel.startPreset()
                            } else {
                                timerViewModel.start()
                            }
                        } else {
                            if isPresetMode {
                                timerViewModel.startPreset()
                            } else {
                                timerViewModel.start()
                            }
                        }
                    } label: {
                        let buttonText: String = {
                            if isCompleted { return "Reset" }
                            if timerViewModel.state == .running || timerViewModel.state == .cooldown { return "Pause" }
                            if timerViewModel.state == .paused || timerViewModel.state == .cooldownPaused { return "Start" }
                            return "Start"
                        }()
                        Text(buttonText)
                            // Keep the state label crisp while the glass button animates its press feedback.
                            .contentTransition(.identity)
                            .transaction {
                                $0.animation = nil
                                $0.disablesAnimations = true
                            }
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        timerViewModel.endWorkout()
                    } label: {
                        Text("End")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted ? .gray.opacity(0.5) : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                    }
                    .disabled((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted)
                    .frame(maxWidth: .infinity)

                    // Cool button (hidden in preset mode)
                    if !isPresetMode {
                        Button {
                            if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                                timerViewModel.toggleCooldown()
                            } else {
                                if timerViewModel.state == .running || timerViewModel.state == .paused {
                                    timerViewModel.captureSet()
                                }
                                timerViewModel.end()
                            }
                        } label: {
                            Text("Cool")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                                .foregroundColor(isCooldownDisabled || isInCooldownMode || isCompleted ? .gray.opacity(0.5) : .white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 2)
                                .padding(.vertical, isLandscape ? 0 : 6)
                                .frame(minHeight: 30)
                        }
                        .disabled(isCooldownDisabled || isInCooldownMode || isCompleted)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Bottom row: Work/Rest controls or preset label
                if !isPresetMode {
                    rowLayout {
                        Button {
                            timerViewModel.captureSet()
                            setConfirmation = UUID()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                Text("Work Set")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            }
                            .foregroundColor(workSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                        }
                        .disabled(workSetDisabled)
                        .frame(maxWidth: .infinity)

                        Button {
                            timerViewModel.captureRestSet()
                            setConfirmation = UUID()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                Text("Rest Set")
                                    .font(.system(size: buttonFontSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .allowsTightening(true)
                            }
                            .foregroundColor(restSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 2)
                            .padding(.vertical, isLandscape ? 0 : 6)
                            .frame(minHeight: 30)
                        }
                        .disabled(restSetDisabled)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    presetNamePlaceholder(text: presetName, buttonFontSize: buttonFontSize, buttonPaddingSize: buttonPaddingSize)
                }
            }
            .bpmActionStyle()
            .bpmGlassGroup()
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, isLandscape ? 4 : 20)
            .background(Color.black.opacity(0.8))
        }
    }

    private func presetNamePlaceholder(text: String, buttonFontSize: CGFloat, buttonPaddingSize: CGFloat) -> some View {
        Text("Preset: \(text)")
            .font(.system(size: buttonFontSize, weight: .semibold))
            .foregroundColor(.gray.opacity(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, buttonPaddingSize * 1.5)
            .padding(.vertical, buttonPaddingSize)
            .overlay(
                RoundedRectangle(cornerRadius: buttonPaddingSize)
                    .stroke(Color.gray.opacity(0.22), lineWidth: 1)
            )
    }
    
    @ViewBuilder
    private func presetPlaceholderRow(set: SetRecord, fontSize: CGFloat, columnWidth: CGFloat, columnSpacing: CGFloat, isLandscape: Bool, showTenths: Bool) -> some View {
        let rowColor: Color = .gray.opacity(0.4)

        HStack(spacing: columnSpacing) {
            Text(timerViewModel.displayLabel(for: set))
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .center)

            Text(formatTime(set.setTime, showTenths: showTenths))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .center)

            Text("---")
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .center)

            if isLandscape {
                Text("---")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor)
                    .frame(width: columnWidth, alignment: .center)

                Text("---")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor)
                    .frame(width: columnWidth, alignment: .center)
            }

            Text(formatTime(set.totalTime, showTenths: showTenths))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .id("placeholder-\(set.id)")
    }

    private func formatTime(_ time: TimeInterval, showTenths: Bool = true) -> String {
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let tenths = Int((time.truncatingRemainder(dividingBy: 1)) * 10)

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if !showTenths || minutes >= 10 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%d:%02d.%d", minutes, seconds, tenths)
        }
    }

    private func topBarCircleIcon(systemName: String, color: Color = .white, accessibilityLabel: String? = nil) -> some View {
        Image(systemName: systemName)
            .font(.system(size: TopBarLayout.iconFontSize))
            .foregroundColor(color)
            .frame(width: TopBarLayout.iconSize, height: TopBarLayout.iconSize)
            .bpmCircleSurface()
            .accessibilityLabel(accessibilityLabel ?? systemName)
    }

}
