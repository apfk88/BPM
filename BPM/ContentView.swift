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

private enum TimerViewMode: String {
    case table
    case stats
    case chart

    mutating func cycle() {
        switch self {
        case .table:
            self = .stats
        case .stats:
            self = .chart
        case .chart:
            self = .table
        }
    }
}


struct HeartRateDisplayView: View {
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
    @State private var showDisconnectAlert = false
    @State private var portraitBottomContentHeight: CGFloat = 0
    @State private var heartRateExtremumDisplay: HeartRateExtremumDisplay = .max
    @State private var collapsedStatDisplay: CollapsedStatDisplay = .max
    @AppStorage("BPM_View_TimerMode") private var timerViewModeRawValue = TimerViewMode.table.rawValue
    @State private var showPresetSheet = false
    @State private var showPaywall = false
    @State private var showSettings = false
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var zoneStorage = HeartRateZoneStorage.shared
    @State private var showShareDialog = false
    @State private var showShareSheet = false
    @State private var shareText = ""
    @State private var shareSubject = ""
    @State private var hasSavedWorkout = false
    @State private var savedWorkoutId: UUID?
    @State private var showWorkoutTitlePrompt = false
    @State private var workoutTitleText = ""
    @FocusState private var isWorkoutTitleFocused: Bool
    @StateObject private var workoutStore = WorkoutStore.shared
    @State private var hasChangedTimerViewModeInSession = false

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

    private var isTimerEmptyState: Bool {
        timerViewModel.state == .idle && timerViewModel.sets.isEmpty
    }

    private func cycleTimerViewMode() {
        var nextMode = timerViewMode
        nextMode.cycle()
        timerViewModeRawValue = nextMode.rawValue
        hasChangedTimerViewModeInSession = true
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                portraitLayout(geometry: geometry)
            }
        }
        .onChange(of: timerViewModel.sets.isEmpty) { _, isEmpty in
            if isEmpty {
                hasSavedWorkout = false
                savedWorkoutId = nil
            }
        }
        .onChange(of: isTimerMode) { _, isActive in
            if isActive && !hasChangedTimerViewModeInSession {
                timerViewModeRawValue = TimerViewMode.table.rawValue
            }
        }
        .onChange(of: showWorkoutTitlePrompt) { _, isPresented in
            if isPresented {
                workoutTitleText = "Workout"
                isWorkoutTitleFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                }
            } else {
                isWorkoutTitleFocused = false
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
        .sheet(isPresented: $showPaywall) {
            SharePaywallView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText], subject: shareSubject)
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
            // Restore mode based on saved state
            if sharingService.isViewing {
                appMode = .friendCode
            } else {
                appMode = .myDevice
            }
            
            if appMode == .myDevice {
                bluetoothManager.startScanning()
                IdleTimer.disable()
            }
            
            // Set up timer heart rate callback - use friend's heart rate when viewing
            timerViewModel.currentHeartRate = { [weak bluetoothManager, weak sharingService] in
                if sharingService?.isViewing == true {
                    return sharingService?.friendHeartRate
                } else {
                    return bluetoothManager?.currentHeartRate
                }
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
            
            // Update timer heart rate callback when mode changes
            timerViewModel.currentHeartRate = { [weak bluetoothManager, weak sharingService] in
                if sharingService?.isViewing == true {
                    return sharingService?.friendHeartRate
                } else {
                    return bluetoothManager?.currentHeartRate
                }
            }
        }
        .onChange(of: sharingService.isViewing) { oldValue, newValue in
            if newValue && appMode == .myDevice && !oldValue {
                appMode = .friendCode
            }
            
            // Update timer heart rate callback when viewing status changes
            timerViewModel.currentHeartRate = { [weak bluetoothManager, weak sharingService] in
                if sharingService?.isViewing == true {
                    return sharingService?.friendHeartRate
                } else {
                    return bluetoothManager?.currentHeartRate
                }
            }
        }
        .onDisappear {
            if appMode == .myDevice {
                bluetoothManager.stopScanning()
                IdleTimer.enable()
            } else {
                IdleTimer.enable() // Re-enable idle timer when leaving friend view
            }
        }
    }
    
    @ViewBuilder
    private func portraitLayout(geometry: GeometryProxy) -> some View {
        if isHRVMode {
            HRVMeasurementView(viewModel: hrvViewModel, onDismiss: {
                isHRVMode = false
            })
                .environmentObject(bluetoothManager)
                .environmentObject(sharingService)
        } else if isTimerMode {
            timerModeLayout(geometry: geometry, isLandscape: false)
        } else {
            let bpmOffset = -portraitBottomContentHeight / 2 - geometry.size.height * 0.1
            ZStack {
                heartRateDisplay(size: geometry.size)
                    .offset(y: bpmOffset)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    statsBar(screenWidth: geometry.size.width)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: BottomContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(BottomContentHeightKey.self) { portraitBottomContentHeight = $0 }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            topBarCircleIcon(
                                systemName: "gearshape",
                                accessibilityLabel: "Settings"
                            )
                        }
                    }
                    .padding(.horizontal, TopBarLayout.horizontalPadding)

                    VStack(spacing: 8) {
                        connectionPrompt
                        bluetoothMessageDisplay
                        errorMessageDisplay
                        sharingCodeDisplay
                    }
                    .frame(maxWidth: 320, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                .padding(.top, 4)
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
    }
    
    private var displayedHeartRate: Int? {
        if appMode == .myDevice {
            return bluetoothManager.currentHeartRate
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

        return HStack(spacing: 0) {
            summaryStatColumn(title: "Total Time", value: totalTimeValue, labelSize: labelSize, valueSize: valueSize)
            summaryStatColumn(title: "Avg Work Set", value: avgSetValue, labelSize: labelSize, valueSize: valueSize)
            summaryStatColumn(title: "Avg BPM", value: avgBPMValue, labelSize: labelSize, valueSize: valueSize)
        }
        .padding(.horizontal, 12)
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
        let tileWidth = max(1, floor((containerSize.width - (horizontalPadding * 2) - columnSpacing) / 2))
        let tileHeight = max(1, floor((containerSize.height - (verticalPadding * 2) - (rowSpacing * 3)) / 4))

        let columns = [
            GridItem(.fixed(tileWidth), spacing: columnSpacing),
            GridItem(.fixed(tileWidth), spacing: columnSpacing)
        ]

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

    private func summaryStatColumn(title: String, value: String, labelSize: CGFloat, valueSize: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(valueTextColor(value))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
            Text("Tap the heart to connect your strap or enter a friend's share code.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
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
    

    @ViewBuilder
    private func statsBar(screenWidth: CGFloat) -> some View {
        // Scale factor: smaller screens get smaller sizes
        // Base scale on iPhone SE (375pt) = 1.0, scale down proportionally
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let scaledPadding = max(12.0, 20.0 * scaleFactor)
        let scaledButtonSize = max(20.0, 24.0 * scaleFactor)
        let scaledButtonPadding = max(8.0, 12.0 * scaleFactor)
        
        if appMode == .myDevice {
            // Portrait mode - stats above buttons
            VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                // Stats row: Avg, Min, Max, Zone - equal width columns
                HStack(spacing: 0) {
                    statColumn(
                        title: "Avg",
                        value: bluetoothManager.avgHeartRateLastHour,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                    statColumn(
                        title: "Min",
                        value: bluetoothManager.minHeartRateLastHour,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                    statColumn(
                        title: "Max",
                        value: bluetoothManager.maxHeartRateLastHour,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                    zoneStatColumn(
                        heartRate: displayedHeartRate,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                }

                // Buttons row with labels - equal width
                HStack(spacing: max(6.0, 8.0 * scaleFactor)) {
                    Button {
                        showDevicePicker = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: heartIconName)
                                .font(.system(size: scaledButtonSize))
                            Text("Device")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(heartButtonColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }

                    Button {
                        if sharingService.isSharing {
                            showDisconnectAlert = true
                        } else {
                            Task {
                                let canShare = await subscriptionManager.canShare()
                                if canShare {
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
                                } else {
                                    showPaywall = true
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: scaledButtonSize))
                            HStack(spacing: 2) {
                                if !subscriptionManager.isSubscribed && !sharingService.isSharing {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: max(8, 10 * scaleFactor)))
                                }
                                Text("Share")
                            }
                            .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(sharingService.isSharing ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }

                    Button {
                        isTimerMode.toggle()
                        if !isTimerMode {
                            timerViewModel.reset()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "stopwatch")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                            Text("Workout")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(isTimerMode ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }

                    Button {
                        isHRVMode.toggle()
                        if !isHRVMode {
                            hrvViewModel.reset()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                            Text("HRV")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(isHRVMode ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, scaledPadding)
            .padding(.vertical, max(12.0, 16.0 * scaleFactor))
            .background(Color.black.opacity(0.8))
        } else {
            // Friend mode stats
            VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                // Stats row: Avg, Min, Max - equal width columns
                HStack(spacing: 0) {
                    statColumn(
                        title: "Avg",
                        value: sharingService.friendAvgHeartRate,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                    statColumn(
                        title: "Min",
                        value: sharingService.friendMinHeartRate,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                    statColumn(
                        title: "Max",
                        value: sharingService.friendMaxHeartRate,
                        scaleFactor: scaleFactor,
                        isLandscape: false
                    )
                    .frame(maxWidth: .infinity)
                }

                // Buttons row with labels - equal width
                HStack(spacing: max(6.0, 8.0 * scaleFactor)) {
                    Button {
                        showDevicePicker = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: heartIconName)
                                .font(.system(size: scaledButtonSize))
                            Text("Device")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(heartButtonColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }

                    Button {
                        // Disabled - no action
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: scaledButtonSize))
                            Text("Share")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        )
                    }
                    .disabled(true)

                    Button {
                        isTimerMode.toggle()
                        if !isTimerMode {
                            timerViewModel.reset()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "stopwatch")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                            Text("Workout")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(isTimerMode ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }

                    Button {
                        isHRVMode.toggle()
                        if !isHRVMode {
                            hrvViewModel.reset()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                            Text("HRV")
                                .font(.system(size: max(10.0, 12.0 * scaleFactor), weight: .medium))
                        }
                        .foregroundColor(isHRVMode ? .green : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaledButtonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, scaledPadding)
            .padding(.vertical, max(12.0, 16.0 * scaleFactor))
            .background(Color.black.opacity(0.8))
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

    private struct BottomContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
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
                    topBarCircleIcon(systemName: "xmark")
                }

                Spacer()

                Button {
                    cycleTimerViewMode()
                } label: {
                    topBarCircleIcon(
                        systemName: "eye",
                        accessibilityLabel: "Cycle View Mode"
                    )
                }

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
                    showSettings = true
                } label: {
                    topBarCircleIcon(
                        systemName: "gearshape",
                        accessibilityLabel: "Settings"
                    )
                }
            }
            .padding(.horizontal, TopBarLayout.horizontalPadding)
            .padding(.top, TopBarLayout.topPadding)
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
            .alert("Workout Title", isPresented: $showWorkoutTitlePrompt) {
                TextField("Title", text: $workoutTitleText)
                    .focused($isWorkoutTitleFocused)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                Button("Save") {
                    let trimmed = workoutTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    saveCurrentWorkout(title: trimmed.isEmpty ? "Workout" : trimmed)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Add a title for this workout (optional).")
            }

            if timerViewMode == .stats {
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
            } else {
                // Stopwatch display with BPM (or completion stats when done)
                stopwatchDisplay()
                    .padding(.top, 18)

                if timerViewMode == .chart {
                    GeometryReader { proxy in
                        let horizontalPadding: CGFloat = isLandscape ? 40 : 20
                        let chartSpacing: CGFloat = 12
                        let availableHeight = max(0, proxy.size.height - chartSpacing)
                        let panelHeight = availableHeight / 2

                        VStack(spacing: chartSpacing) {
                            HeartRateChartView(timerViewModel: timerViewModel, isLandscape: isLandscape)
                                .frame(maxWidth: .infinity, maxHeight: panelHeight)

                            TimerTimeInZoneView(timerViewModel: timerViewModel, zoneStorage: zoneStorage, isLandscape: isLandscape)
                                .frame(maxWidth: .infinity, maxHeight: panelHeight, alignment: .top)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                        .padding(.horizontal, isLandscape ? 40 : 20)
                        .padding(.top, 16)

                    setsTable(isLandscape: isLandscape, screenWidth: geometry.size.width)
                        .padding(.horizontal, isLandscape ? 40 : 20)
                        .padding(.top, 8)
                }
                if timerViewMode != .chart {
                    Spacer(minLength: 0)
                }
            }
            
            // Timer control buttons at bottom
            timerControlButtons(isLandscape: isLandscape, screenWidth: geometry.size.width)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
    
    @ViewBuilder
    private func stopwatchDisplay() -> some View {
        if isPad {
            landscapeStopwatchDisplay()
        } else {
            portraitStopwatchDisplay()
        }
    }
    
    @ViewBuilder
    private func landscapeStopwatchDisplay() -> some View {
        // Always show stats - don't hide them when completed
        let isCooldown = timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused
        let isPresetMode = timerViewModel.isPresetMode
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)

        if timerViewModel.isCompleted {
            completedSummaryRow(totalTime: totalTime)
        } else {
            // Set label changes based on mode
            let setLabel: String = "Set Time"

            // For cooldown, calculate countdown from 2 minutes
            // For preset mode, show countdown for current phase
            let displaySetTime: TimeInterval = {
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

            // Pre-calculate complex values to help compiler type-checking
            let totalTimeTitle = "Total Time"
            let totalTimeValue = isTimerEmptyState ? "---" : formatTime(totalTime, showTenths: false)
            let setTimeValue: String = {
                if isTimerEmptyState {
                    return "---"
                } else if timerViewModel.isCompleted {
                    return timerViewModel.avgSetTime.map { formatTime($0, showTenths: shouldShowTenthsInTimer) } ?? "---"
                } else {
                    return formatTime(displaySetTime, showTenths: shouldShowTenthsInTimer)
                }
            }()
            // Landscape: show Total, Set, BPM
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    landscapeStatColumn(
                        title: totalTimeTitle,
                        value: totalTimeValue,
                        alignment: .leading
                    )

                    Spacer()

                    landscapeStatColumn(
                        title: setLabel,
                        value: setTimeValue,
                        alignment: .center
                    )

                    Spacer()
                    
                    landscapeStatColumn(
                        title: "BPM",
                        value: displayedHeartRate.map(String.init) ?? "---",
                        alignment: .trailing
                    )
                }
                .padding(.horizontal, 20)
            }
        }
    }
    
    @ViewBuilder
    private func portraitStopwatchDisplay() -> some View {
        // Always show stats - don't hide them when completed
        let isCooldown = timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused
        let isPresetMode = timerViewModel.isPresetMode
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)

        if timerViewModel.isCompleted {
            completedSummaryRow(totalTime: totalTime)
        } else {
            // Set label changes based on mode
            let setLabel: String = "Set Time"

            // For cooldown, calculate countdown from 2 minutes
            // For preset mode, show countdown for current phase
            let displaySetTime: TimeInterval = {
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

            // Pre-calculate complex values
            let totalTimeTitle = "Total Time"
            let totalTimeValue = isTimerEmptyState ? "---" : formatTime(totalTime, showTenths: false)
            let setTimeValue: String = {
                if isTimerEmptyState {
                    return "---"
                } else if timerViewModel.isCompleted {
                    return timerViewModel.avgSetTime.map { formatTime($0, showTenths: shouldShowTenthsInTimer) } ?? "---"
                } else {
                    return formatTime(displaySetTime, showTenths: shouldShowTenthsInTimer)
                }
            }()
            
            // Calculate BPM display values
            let bpmTitle: String = "BPM"
            
            let bpmValue: String = displayedHeartRate.map(String.init) ?? "---"
            
            // Portrait: show Total, Set, BPM (realtime while running)
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    VStack(alignment: .center, spacing: 4) {
                        Text(totalTimeTitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text(totalTimeValue)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(valueTextColor(totalTimeValue))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    VStack(alignment: .center, spacing: 4) {
                        Text(setLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text(setTimeValue)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(valueTextColor(setTimeValue))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    VStack(alignment: .center, spacing: 4) {
                        Text(bpmTitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text(bpmValue)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(valueTextColor(bpmValue))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 8)
            }
        }
    }
    
    @ViewBuilder
    private func setsTable(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let fontSize = isLandscape ? 14.0 : max(16.0, 18.0 * scaleFactor)
        let headerFontSize: CGFloat = 14.0
        let columnSpacing: CGFloat = isLandscape ? 6.0 : max(6.0, 8.0 * scaleFactor)
        let columnCount = isLandscape ? 6 : 4 // 6 columns in landscape (add Max BPM and Min BPM), 4 in portrait
        let columnWidth = (screenWidth - (isLandscape ? 80 : 40) - 24 - (columnSpacing * CGFloat(columnCount - 1))) / CGFloat(columnCount) // Equal width columns
        let workSetCount = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
        let showDefaultEmptyRow = timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !timerViewModel.isPresetMode
        let showTenths = shouldShowTenthsInTimer
        
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
                            
                            Text("Avg BPM")
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

                                Text(avgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(valueTextColor(avgBPM.map(String.init) ?? "---", preferred: rowColor))
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
                            
                            HStack(spacing: columnSpacing) {
                                Text("\(nextSetNumber)")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(formatTime(timerViewModel.currentSetTime, showTenths: showTenths))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .center)
                                
                                Text(currentAvgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(valueTextColor(currentAvgBPM.map(String.init) ?? "---"))
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
                        }

                        // Remaining future placeholder rows for preset mode (grayed out, shown after active row)
                        if timerViewModel.isPresetMode && (timerViewModel.state == .running || timerViewModel.state == .paused || timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused) {
                            ForEach(timerViewModel.remainingPresetPlaceholderSets) { set in
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
                            
                            Text("Avg BPM")
                                .font(.system(size: headerFontSize, weight: .semibold))
                                .foregroundColor(.gray)
                                .frame(width: columnWidth, alignment: .center)
                            
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

    private enum WorkoutShareKind {
        case summary
        case detail
    }

    private func shareTotalTime() -> TimeInterval {
        timerViewModel.frozenElapsedTime > 0 ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime
    }

    private func presentShare(_ kind: WorkoutShareKind) {
        let totalTime = shareTotalTime()
        switch kind {
        case .summary:
            shareText = timerViewModel.workoutSummaryText(
                totalTime: totalTime,
                zoneConfig: zoneStorage.effectiveConfig
            )
            shareSubject = "Workout Summary"
        case .detail:
            if let record = timerViewModel.workoutRecord(
                zoneConfig: zoneStorage.effectiveConfig,
                workoutId: savedWorkoutId,
                title: nil
            ) {
                shareText = record.jsonString()
            } else {
                shareText = "{\"error\":\"No workout data available\"}"
            }
            shareSubject = "Workout Logs (JSON)"
        }
        showShareSheet = true
    }

    private func saveCurrentWorkout(title: String?) {
        guard let record = timerViewModel.workoutRecord(
            zoneConfig: zoneStorage.effectiveConfig,
            workoutId: savedWorkoutId,
            title: title
        ) else {
            return
        }
        workoutStore.saveWorkout(record)
        savedWorkoutId = record.id
        hasSavedWorkout = true
    }
    
    @ViewBuilder
    private func timerControlButtons(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let buttonSpacing = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
        let buttonPadding = isLandscape ? 40.0 : max(20.0, 24.0 * scaleFactor)
        let buttonFontSize = isLandscape ? 16.0 : max(14.0, 18.0 * scaleFactor)
        let buttonPaddingSize = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
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
                    workoutTitleText = "Workout"
                    showWorkoutTitlePrompt = true
                } label: {
                    Text(hasSavedWorkout ? "Saved" : "Save Workout")
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor(hasSavedWorkout ? .gray : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background(hasSavedWorkout ? Color.gray.opacity(0.15) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                }
                .frame(maxWidth: .infinity)
                .disabled(hasSavedWorkout)

                HStack(spacing: buttonSpacing) {
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
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        showShareDialog = true
                    } label: {
                        Text("Share")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .frame(maxWidth: .infinity)
                    .confirmationDialog("Share Workout", isPresented: $showShareDialog, titleVisibility: .visible) {
                        Button("Share Summary") {
                            presentShare(.summary)
                        }
                        Button("Share Logs (for AI)") {
                            presentShare(.detail)
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        } else if isStartState {
            VStack(spacing: buttonSpacing) {
                HStack(spacing: buttonSpacing) {
                    Button {
                        if isPresetMode {
                            timerViewModel.startPreset()
                        } else {
                            timerViewModel.start()
                        }
                    } label: {
                        Text("Start")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        showPresetSheet = true
                    } label: {
                        Text("Load Preset")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .frame(maxWidth: .infinity)
                }

                if !isPresetMode {
                    HStack(spacing: buttonSpacing) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                            Text("Work Set")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .allowsTightening(true)
                        }
                        .foregroundColor(.gray.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .overlay(
                            RoundedRectangle(cornerRadius: buttonPaddingSize)
                                .stroke(Color.gray.opacity(0.22), lineWidth: 1)
                        )

                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                            Text("Rest Set")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .allowsTightening(true)
                        }
                        .foregroundColor(.gray.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .overlay(
                            RoundedRectangle(cornerRadius: buttonPaddingSize)
                                .stroke(Color.gray.opacity(0.22), lineWidth: 1)
                        )
                    }
                } else {
                    presetNamePlaceholder(text: presetName, buttonFontSize: buttonFontSize, buttonPaddingSize: buttonPaddingSize)
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        } else if isLandscape {
            // Landscape: single row with all buttons
            HStack(spacing: buttonSpacing) {
                // Start/Pause/Reset button
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
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                }
                .frame(maxWidth: .infinity)

                // End button
                Button {
                    if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                        timerViewModel.stopCooldownAndComplete()
                    } else if isPresetMode {
                        // In preset mode, End stops the workout entirely (skips cooldown)
                        if timerViewModel.state == .running || timerViewModel.state == .paused {
                            timerViewModel.stopPresetAndComplete()
                        } else {
                            // Preset loaded but not started - just clear it
                            timerViewModel.clearPreset()
                        }
                    } else {
                        if timerViewModel.state == .running || timerViewModel.state == .paused {
                            timerViewModel.captureSet()
                        }
                        timerViewModel.stopAndComplete()
                    }
                } label: {
                    Text("End")
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
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
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background((isCooldownDisabled || isInCooldownMode || isCompleted) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(isCooldownDisabled || isInCooldownMode || isCompleted)
                    .frame(maxWidth: .infinity)
                }

                // Work Set button (hidden in preset mode)
                if !isPresetMode {
                    Button {
                        timerViewModel.captureSet()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                            Text("Work Set")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                        }
                        .foregroundColor(workSetDisabled ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background(workSetDisabled ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(workSetDisabled)
                    .frame(maxWidth: .infinity)

                    // Rest Set button
                    Button {
                        timerViewModel.captureRestSet()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                            Text("Rest Set")
                                .font(.system(size: buttonFontSize, weight: .semibold))
                        }
                        .foregroundColor(restSetDisabled ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background(restSetDisabled ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(restSetDisabled)
                    .frame(maxWidth: .infinity)
                } else {
                    presetNamePlaceholder(text: presetName, buttonFontSize: buttonFontSize, buttonPaddingSize: buttonPaddingSize)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        } else {
            // Portrait: always two rows
            VStack(spacing: buttonSpacing) {
                // Top row: Start/Pause/Reset, End, Cool (Cool hidden in preset mode)
                HStack(spacing: buttonSpacing) {
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
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                            timerViewModel.stopCooldownAndComplete()
                        } else if isPresetMode {
                            // In preset mode, End stops the workout entirely (skips cooldown)
                            if timerViewModel.state == .running || timerViewModel.state == .paused {
                                timerViewModel.stopPresetAndComplete()
                            } else {
                                // Preset loaded but not started - just clear it
                                timerViewModel.clearPreset()
                            }
                        } else {
                            if timerViewModel.state == .running || timerViewModel.state == .paused {
                                timerViewModel.captureSet()
                            }
                            timerViewModel.stopAndComplete()
                        }
                    } label: {
                        Text("End")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted ? .gray.opacity(0.5) : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background((timerViewModel.state == .idle && timerViewModel.sets.isEmpty && !isPresetMode) || isCompleted ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
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
                                .padding(.horizontal, buttonPaddingSize * 1.5)
                                .padding(.vertical, buttonPaddingSize)
                                .background((isCooldownDisabled || isInCooldownMode || isCompleted) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                                .cornerRadius(buttonPaddingSize)
                        }
                        .disabled(isCooldownDisabled || isInCooldownMode || isCompleted)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Bottom row: Work/Rest controls or preset label
                if !isPresetMode {
                    HStack(spacing: buttonSpacing) {
                        Button {
                            timerViewModel.captureSet()
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
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(workSetDisabled ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                        }
                        .disabled(workSetDisabled)
                        .frame(maxWidth: .infinity)

                        Button {
                            timerViewModel.captureRestSet()
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
                            .padding(.horizontal, buttonPaddingSize * 1.5)
                            .padding(.vertical, buttonPaddingSize)
                            .background(restSetDisabled ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                        }
                        .disabled(restSetDisabled)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    presetNamePlaceholder(text: presetName, buttonFontSize: buttonFontSize, buttonPaddingSize: buttonPaddingSize)
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
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
            .background(Color.gray.opacity(TopBarLayout.iconBackgroundOpacity))
            .clipShape(Circle())
            .accessibilityLabel(accessibilityLabel ?? systemName)
    }

}
