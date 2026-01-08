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

private enum TimerBPMDisplay {
    case avg
    case max
    case hrr

    mutating func cycle() {
        switch self {
        case .avg:
            self = .max
        case .max:
            self = .hrr
        case .hrr:
            self = .avg
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
    @State private var landscapeBottomContentHeight: CGFloat = 0
    @State private var heartRateExtremumDisplay: HeartRateExtremumDisplay = .max
    @State private var collapsedStatDisplay: CollapsedStatDisplay = .max
    @State private var timerBPMDisplay: TimerBPMDisplay = .avg
    @State private var showChart = false
    @State private var showZones = false
    @State private var showSessionZones = false
    @State private var showPresetSheet = false
    @State private var showPaywall = false
    @State private var showZoneConfig = false
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var zoneStorage = HeartRateZoneStorage.shared

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                Color.black.ignoresSafeArea()

                if isLandscape {
                    landscapeLayout(geometry: geometry, useSideLayout: !isPad)
                } else {
                    portraitLayout(geometry: geometry)
                }
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
        .sheet(isPresented: $showZoneConfig) {
            HeartRateZoneConfigView(isPresented: $showZoneConfig)
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
                heartRateDisplay(size: geometry.size, isLandscape: false)
                    .offset(y: bpmOffset)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    statsBar(isLandscape: false, screenWidth: geometry.size.width)
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
                    connectionPrompt
                    errorMessageDisplay
                    sharingCodeDisplay
                }
            }
        }
    }
    
    @ViewBuilder
    private func landscapeLayout(geometry: GeometryProxy, useSideLayout: Bool) -> some View {
        if isHRVMode {
            HRVMeasurementView(viewModel: hrvViewModel, onDismiss: {
                isHRVMode = false
            })
                .environmentObject(bluetoothManager)
                .environmentObject(sharingService)
        } else if isTimerMode {
            timerModeLayout(geometry: geometry, isLandscape: true)
        } else if useSideLayout {
            HStack(spacing: 0) {
                // Left side: BPM display with stats below
                VStack(spacing: 0) {
                    Spacer(minLength: isPad ? 40 : 20)
                    heartRateDisplay(size: geometry.size, isLandscape: true)
                    if appMode == .myDevice, showSessionZones {
                        Spacer(minLength: isPad ? 16 : 12)
                    }
                    landscapeStatsRow(screenWidth: geometry.size.width)
                        .padding(.bottom, showSessionZones && appMode == .myDevice ? (isPad ? 20 : 12) : (isPad ? 40 : 20))
                    if appMode == .myDevice, showSessionZones {
                        sessionZoneSection(isLandscape: true, horizontalPadding: 20)
                            .padding(.bottom, isPad ? 24 : 16)
                    }
                    Spacer(minLength: isPad ? 80 : 40)
                }
                .frame(maxWidth: .infinity)

                // Right side: Buttons vertically arranged
                landscapeButtonsColumn(screenWidth: geometry.size.width)
                    .padding(.trailing, geometry.safeAreaInsets.trailing)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    connectionPrompt
                    errorMessageDisplay
                    sharingCodeDisplay
                }
            }
        } else {
            let bpmOffset = -landscapeBottomContentHeight / 2
            ZStack {
                heartRateDisplay(size: geometry.size, isLandscape: true)
                    .offset(y: bpmOffset)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    statsBar(isLandscape: true, screenWidth: geometry.size.width)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: BottomContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(BottomContentHeightKey.self) { landscapeBottomContentHeight = $0 }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    connectionPrompt
                    errorMessageDisplay
                    sharingCodeDisplay
                }
            }
        }
    }

    private var sharingCodeDisplay: some View {
        Group {
            if appMode == .myDevice && sharingService.isSharing, let code = sharingService.shareCode {
                Text("SHARE CODE: \(formattedShareCode(code))")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.top, 20)
            } else if appMode == .friendCode && sharingService.isViewing, let code = sharingService.friendCode {
                Button {
                    showDevicePicker = true
                } label: {
                    Text("Viewing: \(formattedShareCode(code))")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(.top, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func heartRateDisplay(size: CGSize, isLandscape: Bool) -> some View {
        // Base font size anchored to screen height, but cap by width to fit 3 digits comfortably
        // iPad in landscape gets larger sizing
        let baseFontSize: CGFloat = {
            if isLandscape {
                if isPad {
                    // iPad landscape: allow bigger BPM display
                    return min(size.width * 0.35, size.height * 0.7)
                } else {
                    return min(size.width * 0.25, size.height * 0.6)
                }
            } else {
                return size.height * 0.65
            }
        }()

        // Measure width of the widest expected value (three digits) at the base font size
        let referenceText = "888"
        let baseUIFont = UIFont.systemFont(ofSize: baseFontSize, weight: .bold)
        let baseWidth = referenceText.size(withAttributes: [.font: baseUIFont]).width

        // Leave some horizontal padding so the number never abuts the edges
        // iPad in landscape gets more allowance since BPM is on left side
        let horizontalAllowance: CGFloat = {
            if isLandscape && isPad {
                return size.width * 0.5
            } else if isLandscape {
                return size.width * 0.4
            } else {
                return size.width * 0.9
            }
        }()
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
                .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var connectionPrompt: some View {
        if shouldShowConnectionPrompt {
            Text("Tap the heart to connect your strap or enter a friend's share code.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
                .padding(.top, 20)
        }
    }

    private var shouldShowConnectionPrompt: Bool {
        let hasDeviceConnection = bluetoothManager.hasActiveDataSource
        let hasFriendConnection = sharingService.isViewing && sharingService.friendCode != nil
        return !hasDeviceConnection && !hasFriendConnection
    }
    

    @ViewBuilder
    private func statsBar(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        // Scale factor: smaller screens get smaller sizes
        // Base scale on iPhone SE (375pt) = 1.0, scale down proportionally
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let scaledPadding = isLandscape ? 40.0 : max(12.0, 20.0 * scaleFactor)
        let scaledButtonSize = isLandscape ? 32.0 : max(20.0, 24.0 * scaleFactor)
        let scaledButtonPadding = isLandscape ? 16.0 : max(8.0, 12.0 * scaleFactor)
        
        if appMode == .myDevice {
                if isLandscape {
                    // Landscape mode - stats centered, buttons in 2x2 grid
                    VStack(spacing: max(16.0, 20.0 * scaleFactor)) {
                        VStack(spacing: showSessionZones ? 4.0 : 0.0) {
                            // Stats row: Avg, Min, Max, Zone - equal width columns
                            HStack(spacing: 0) {
                                statColumn(
                                    title: "Avg",
                                    value: bluetoothManager.avgHeartRateLastHour,
                                    scaleFactor: 1.0,
                                    isLandscape: true
                                )
                                .frame(maxWidth: .infinity)
                                statColumn(
                                    title: "Min",
                                    value: bluetoothManager.minHeartRateLastHour,
                                    scaleFactor: 1.0,
                                    isLandscape: true
                                )
                                .frame(maxWidth: .infinity)
                                statColumn(
                                    title: "Max",
                                    value: bluetoothManager.maxHeartRateLastHour,
                                    scaleFactor: 1.0,
                                    isLandscape: true
                                )
                                .frame(maxWidth: .infinity)
                                zoneStatColumn(
                                    heartRate: displayedHeartRate,
                                    scaleFactor: 1.0,
                                    isLandscape: true,
                                    isExpanded: showSessionZones
                                ) {
                                    toggleSessionZones()
                                }
                                .frame(maxWidth: .infinity)
                            }

                            if showSessionZones {
                                sessionZoneSection(isLandscape: true, horizontalPadding: 0)
                            }
                        }

                        // Buttons in 2x2 grid
                        VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                            HStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: heartIconName)
                                            .font(.system(size: scaledButtonSize))
                                        Text("Device")
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                                        .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
                                    }
                                    .foregroundColor(sharingService.isSharing ? .green : .white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, scaledButtonPadding)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.gray.opacity(0.3))
                                    )
                                }
                            }

                            HStack(spacing: max(12.0, 16.0 * scaleFactor)) {
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
                                        Text("Timer")
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.8))
                } else {
                    // Portrait mode - stats above buttons
                    VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                        VStack(spacing: showSessionZones ? 4.0 : 0.0) {
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
                                    isLandscape: false,
                                    isExpanded: showSessionZones
                                ) {
                                    toggleSessionZones()
                                }
                                .frame(maxWidth: .infinity)
                            }

                            if showSessionZones {
                                sessionZoneSection(isLandscape: false, horizontalPadding: 0)
                            }
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
                                    Text("Timer")
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
            } else {
                // Friend mode stats
                if isLandscape {
                    // Landscape mode - stats centered, buttons in 2x2 grid
                    VStack(spacing: max(16.0, 20.0 * scaleFactor)) {
                        // Stats row: Avg, Min, Max - equal width columns
                        HStack(spacing: 0) {
                            statColumn(
                                title: "Avg",
                                value: sharingService.friendAvgHeartRate,
                                scaleFactor: 1.0,
                                isLandscape: true
                            )
                            .frame(maxWidth: .infinity)
                            statColumn(
                                title: "Min",
                                value: sharingService.friendMinHeartRate,
                                scaleFactor: 1.0,
                                isLandscape: true
                            )
                            .frame(maxWidth: .infinity)
                            statColumn(
                                title: "Max",
                                value: sharingService.friendMaxHeartRate,
                                scaleFactor: 1.0,
                                isLandscape: true
                            )
                            .frame(maxWidth: .infinity)
                        }

                        // Buttons in 2x2 grid
                        VStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                            HStack(spacing: max(12.0, 16.0 * scaleFactor)) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: heartIconName)
                                            .font(.system(size: scaledButtonSize))
                                        Text("Device")
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                            }
                            
                            HStack(spacing: max(12.0, 16.0 * scaleFactor)) {
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
                                        Text("Timer")
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                                            .font(.system(size: max(12.0, 14.0 * scaleFactor), weight: .medium))
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
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.8))
                } else {
                    // Portrait mode - stats above buttons
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
                                    Text("Timer")
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
    }

    private func toggleSessionZones() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showSessionZones.toggle()
        }
    }

    @ViewBuilder
    private func sessionZoneSection(isLandscape: Bool, horizontalPadding: CGFloat) -> some View {
        let buttonSize: CGFloat = isLandscape ? 11.0 : 12.0
        let chartTopPadding: CGFloat = isLandscape ? 1.5 : 2.0
        let chartBottomPadding: CGFloat = isLandscape ? 2.0 : 4.0

        VStack(spacing: isLandscape ? 4 : 6) {
            SessionTimeInZoneView(
                bluetoothManager: bluetoothManager,
                zoneStorage: zoneStorage,
                isLandscape: isLandscape,
                verticalPadding: isLandscape ? 4.0 : 6.0
            )
            .frame(maxWidth: .infinity)
            .padding(.top, chartTopPadding)
            .padding(.bottom, chartBottomPadding)

            Button {
                showZoneConfig = true
            } label: {
                Text("Configure")
                    .font(.system(size: buttonSize, weight: .semibold))
                    .foregroundColor(.gray)
                    .underline()
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, horizontalPadding)
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0, isLandscape: Bool = false, onTap: (() -> Void)? = nil) -> some View {
        // Use same font sizes as timer bar stats
        let labelSize: CGFloat = 14.0
        let valueSize: CGFloat = isLandscape ? 24.0 : 32.0
        return VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor((value == nil && customText == nil) ? .gray : .white)
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

    private func zoneStatColumn(heartRate: Int?, scaleFactor: Double, isLandscape: Bool, isExpanded: Bool, onTap: @escaping () -> Void) -> some View {
        let labelSize: CGFloat = 14.0
        let valueSize: CGFloat = isLandscape ? 24.0 : 32.0
        let zone = zoneStorage.currentZone(for: heartRate)

        return VStack(spacing: 4 * scaleFactor) {
            HStack(spacing: 2) {
                Text("Zone")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
            }
            .font(.system(size: labelSize, weight: .medium))
            .foregroundColor(.gray)
            Text(zone?.displayName ?? "---")
                .font(.system(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(zone?.color ?? .gray)
                .frame(minWidth: 40 * scaleFactor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

    // MARK: - Landscape Side Layout

    @ViewBuilder
    private func landscapeStatsRow(screenWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            statColumn(
                title: "Avg",
                value: appMode == .myDevice ? bluetoothManager.avgHeartRateLastHour : sharingService.friendAvgHeartRate,
                scaleFactor: 1.0,
                isLandscape: true
            )
            .frame(maxWidth: .infinity)
            statColumn(
                title: "Min",
                value: appMode == .myDevice ? bluetoothManager.minHeartRateLastHour : sharingService.friendMinHeartRate,
                scaleFactor: 1.0,
                isLandscape: true
            )
            .frame(maxWidth: .infinity)
            statColumn(
                title: "Max",
                value: appMode == .myDevice ? bluetoothManager.maxHeartRateLastHour : sharingService.friendMaxHeartRate,
                scaleFactor: 1.0,
                isLandscape: true
            )
            .frame(maxWidth: .infinity)
            if appMode == .myDevice {
                zoneStatColumn(
                    heartRate: displayedHeartRate,
                    scaleFactor: 1.0,
                    isLandscape: true,
                    isExpanded: showSessionZones
                ) {
                    toggleSessionZones()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func landscapeButtonsColumn(screenWidth: CGFloat) -> some View {
        let buttonSize: CGFloat = 28.0
        let buttonPadding: CGFloat = 12.0
        let fontSize: CGFloat = 12.0

        VStack(spacing: 12) {
            Button {
                showDevicePicker = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: heartIconName)
                        .font(.system(size: buttonSize))
                    Text("Device")
                        .font(.system(size: fontSize, weight: .medium))
                }
                .foregroundColor(heartButtonColor)
                .frame(width: 80)
                .padding(.vertical, buttonPadding)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                )
            }

            if appMode == .myDevice {
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
                            .font(.system(size: buttonSize))
                        HStack(spacing: 2) {
                            if !subscriptionManager.isSubscribed && !sharingService.isSharing {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                            }
                            Text("Share")
                        }
                        .font(.system(size: fontSize, weight: .medium))
                    }
                    .foregroundColor(sharingService.isSharing ? .green : .white)
                    .frame(width: 80)
                    .padding(.vertical, buttonPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                    )
                }
            } else {
                Button {
                    // Disabled in friend mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: buttonSize))
                        Text("Share")
                            .font(.system(size: fontSize, weight: .medium))
                    }
                    .foregroundColor(.gray)
                    .frame(width: 80)
                    .padding(.vertical, buttonPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                    )
                }
                .disabled(true)
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
                        .font(.system(size: buttonSize))
                    Text("Timer")
                        .font(.system(size: fontSize, weight: .medium))
                }
                .foregroundColor(isTimerMode ? .green : .white)
                .frame(width: 80)
                .padding(.vertical, buttonPadding)
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
                        .font(.system(size: buttonSize))
                    Text("HRV")
                        .font(.system(size: fontSize, weight: .medium))
                }
                .foregroundColor(isHRVMode ? .green : .white)
                .frame(width: 80)
                .padding(.vertical, buttonPadding)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                )
            }
        }
        .padding(.vertical, 20)
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
                .foregroundColor(.white)
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
                    .foregroundColor(.white)
                    .frame(minWidth: 50, alignment: .center)
            }
        } else {
            VStack(alignment: .center, spacing: 4) {
                Text("BPM")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                Text(displayedHeartRate.map(String.init) ?? "---")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
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
            showZoneConfig = true
        }
    }

    @ViewBuilder
    private func timerModeLayout(geometry: GeometryProxy, isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            // Top bar with device picker, chart toggle, zone toggle, and clear button
            HStack(spacing: 8) {
                Button {
                    showDevicePicker = true
                } label: {
                    Image(systemName: heartIconName)
                        .font(.system(size: 20))
                        .foregroundColor(heartButtonColor)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }

                Spacer()

                // Preset button (always visible when preset active, tappable only when idle/reset)
                if timerViewModel.state == .idle && timerViewModel.sets.isEmpty {
                    Button {
                        showPresetSheet = true
                    } label: {
                        Image(systemName: timerViewModel.isPresetMode ? "star.fill" : "star")
                            .font(.system(size: 20))
                            .foregroundColor(timerViewModel.isPresetMode ? .green : .white)
                            .padding(12)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                } else if timerViewModel.isPresetMode {
                    Image(systemName: "star.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }

                // Chart toggle button
                Button {
                    showChart.toggle()
                } label: {
                    Image(systemName: showChart ? "chart.bar.fill" : "chart.bar")
                        .font(.system(size: 20))
                        .foregroundColor(showChart ? .green : .white)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }

                // Zone time toggle button
                Button {
                    showZones.toggle()
                } label: {
                    Image(systemName: showZones ? "chart.pie.fill" : "chart.pie")
                        .font(.system(size: 20))
                        .foregroundColor(showZones ? .green : .white)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }

                Button {
                    // Only show alert if there's workout data to lose
                    if !timerViewModel.sets.isEmpty || timerViewModel.state != .idle {
                        showClearAlert = true
                    } else {
                        timerViewModel.reset()
                        isTimerMode = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .alert("Clear Timer", isPresented: $showClearAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    timerViewModel.reset()
                    isTimerMode = false
                }
            } message: {
                Text("Are you sure you want to clear all timer data? This cannot be undone.")
            }
            .alert("Reset Timer", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    timerViewModel.reset()
                }
            } message: {
                Text("Are you sure you want to reset? This will clear all timer data.")
            }

            // Stopwatch display with BPM (or completion stats when done)
            stopwatchDisplay(isLandscape: isLandscape)
                .padding(.top, 12)

            // Heart rate chart (when enabled)
            if showChart {
                HeartRateChartView(timerViewModel: timerViewModel, isLandscape: isLandscape)
                    .padding(.horizontal, isLandscape ? 40 : 20)
                    .padding(.top, 12)
            }

            // Time in Zone view (when enabled)
            if showZones {
                TimerTimeInZoneView(timerViewModel: timerViewModel, zoneStorage: zoneStorage, isLandscape: isLandscape)
                    .padding(.horizontal, isLandscape ? 40 : 20)
                    .padding(.top, showChart ? 12 : 8)
            }

            // Set tracking table
            if !timerViewModel.sets.isEmpty || timerViewModel.state == .running || timerViewModel.state == .paused || timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused || (timerViewModel.isPresetMode && timerViewModel.state == .idle) {
                setsTable(isLandscape: isLandscape, screenWidth: geometry.size.width)
                    .padding(.horizontal, isLandscape ? 40 : 20)
                    .padding(.top, (showChart || showZones) ? 12 : 8)
            }
            
            Spacer(minLength: 0)
            
            // Timer control buttons at bottom
            timerControlButtons(isLandscape: isLandscape, screenWidth: geometry.size.width)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
        }
    }
    
    @ViewBuilder
    private func stopwatchDisplay(isLandscape: Bool) -> some View {
        if isLandscape {
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

        // Set label changes based on mode
        let setLabel: String = {
            if timerViewModel.isCompleted {
                return "Avg Set"
            } else if isCooldown {
                return "Cooldown"
            } else if isPresetMode {
                let phase = timerViewModel.presetPhase
                let setNum = timerViewModel.presetCurrentSet
                let totalSets = timerViewModel.activePreset?.numberOfSets ?? 0
                if phase == .work {
                    return "Work \(setNum)/\(totalSets)"
                } else if phase == .rest {
                    return "Rest \(setNum)/\(totalSets)"
                } else {
                    return "Cooldown"
                }
            } else {
                return "Set"
            }
        }()

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
        let totalTimeTitle = timerViewModel.isCompleted ? "Total Time" : "Total"
        let setTimeValue: String = {
            if timerViewModel.isCompleted {
                return timerViewModel.avgSetTime.map { formatTime($0) } ?? "---"
            } else {
                return formatTime(displaySetTime)
            }
        }()
        let avgRestValue = timerViewModel.avgRestTime.map { formatTime($0) } ?? "---"
        let maxBPMValue = timerViewModel.maxHeartRate.map(String.init) ?? "---"
        let avgBPMValue = timerViewModel.avgHeartRate.map(String.init) ?? "---"
        
        // Landscape: show Total, Set, Avg Rest, Current BPM/HRR, Max BPM, Avg BPM, Zone
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                landscapeStatColumn(
                    title: totalTimeTitle,
                    value: formatTime(totalTime, showTenths: false),
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
                    title: "Avg Rest",
                    value: avgRestValue,
                    alignment: .center
                )

                Spacer()

                landscapeBPMOrHRRColumn(isCompleted: timerViewModel.isCompleted)

                Spacer()

                landscapeStatColumn(
                    title: "Max BPM",
                    value: maxBPMValue,
                    alignment: .center
                )

                Spacer()

                landscapeStatColumn(
                    title: "Avg BPM",
                    value: avgBPMValue,
                    alignment: .center
                )

                Spacer()

                landscapeZoneColumn()
            }
            .padding(.horizontal, 20)
        }
    }
    
    @ViewBuilder
    private func portraitStopwatchDisplay() -> some View {
        // Always show stats - don't hide them when completed
        let isCooldown = timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused
        let isPresetMode = timerViewModel.isPresetMode
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)

        // Set label changes based on mode
        let setLabel: String = {
            if timerViewModel.isCompleted {
                return "Avg Set"
            } else if isCooldown {
                return "Cooldown"
            } else if isPresetMode {
                let phase = timerViewModel.presetPhase
                let setNum = timerViewModel.presetCurrentSet
                let totalSets = timerViewModel.activePreset?.numberOfSets ?? 0
                if phase == .work {
                    return "Work \(setNum)/\(totalSets)"
                } else if phase == .rest {
                    return "Rest \(setNum)/\(totalSets)"
                } else {
                    return "Cooldown"
                }
            } else {
                return "Set"
            }
        }()

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
        let totalTimeTitle = timerViewModel.isCompleted ? "Total Time" : "Total"
        let setTimeValue: String = {
            if timerViewModel.isCompleted {
                return timerViewModel.avgSetTime.map { formatTime($0) } ?? "---"
            } else {
                return formatTime(displaySetTime)
            }
        }()
        
        // Calculate BPM display values
        let bpmTitle: String = {
            if timerViewModel.isCompleted {
                switch timerBPMDisplay {
                case .avg: return "Avg BPM"
                case .max: return "Max BPM"
                case .hrr: return "HRR"
                }
            } else {
                return "BPM"
            }
        }()
        
        let bpmValue: String = {
            if timerViewModel.isCompleted {
                switch timerBPMDisplay {
                case .avg: return timerViewModel.avgHeartRate.map(String.init) ?? "---"
                case .max: return timerViewModel.maxHeartRate.map(String.init) ?? "---"
                case .hrr: return timerViewModel.heartRateRecovery.map(String.init) ?? "---"
                }
            } else {
                return displayedHeartRate.map(String.init) ?? "---"
            }
        }()
        
        // Portrait: show Total, Set, BPM (realtime while running, Avg/Max/HRR when completed)
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(totalTimeTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(formatTime(totalTime, showTenths: false))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text(setLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(setTimeValue)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text(bpmTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(bpmValue)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if timerViewModel.isCompleted {
                        timerBPMDisplay.cycle()
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
    
    @ViewBuilder
    private func setsTable(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let fontSize = isLandscape ? 14.0 : max(16.0, 18.0 * scaleFactor)
        let columnCount = isLandscape ? 6 : 4 // 6 columns in landscape (add Max BPM and Min BPM), 4 in portrait
        let columnWidth = (screenWidth - (isLandscape ? 80 : 40) - 24) / CGFloat(columnCount) // Equal width columns
        let workSetCount = timerViewModel.sets.filter { !$0.isRestSet && !$0.isCooldownSet }.count
        
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Spacer to account for pinned header
                        HStack(spacing: 0) {
                            Text("Set")
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .leading)
                            
                            Text("Set Time")
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .leading)
                            
                            Text("Avg BPM")
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .trailing)
                            
                            if isLandscape {
                                Text("Min BPM")
                                    .font(.system(size: fontSize, weight: .semibold))
                                    .foregroundColor(.clear)
                                    .frame(width: columnWidth, alignment: .trailing)
                                
                                Text("Max BPM")
                                    .font(.system(size: fontSize, weight: .semibold))
                                    .foregroundColor(.clear)
                                    .frame(width: columnWidth, alignment: .trailing)
                            }
                            
                            Text("Total")
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundColor(.clear)
                                .frame(width: columnWidth, alignment: .trailing)
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

                            HStack(spacing: 0) {
                                Text(timerViewModel.displayLabel(for: set))
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .leading)

                                Text(formatTime(setTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .leading)

                                Text(avgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .trailing)

                                if isLandscape {
                                    Text(minBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(rowColor)
                                        .frame(width: columnWidth, alignment: .trailing)

                                    Text(maxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(rowColor)
                                        .frame(width: columnWidth, alignment: .trailing)
                                }

                                Text(formatTime(totalTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(rowColor)
                                    .frame(width: columnWidth, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id(set.id)
                        }

                        // Future placeholder rows for preset mode (grayed out)
                        if timerViewModel.isPresetMode && timerViewModel.state == .idle && timerViewModel.sets.isEmpty {
                            // Show all placeholders when not started
                            ForEach(timerViewModel.presetPlaceholderSets) { set in
                                presetPlaceholderRow(set: set, fontSize: fontSize, columnWidth: columnWidth, isLandscape: isLandscape)
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
                            
                            HStack(spacing: 0) {
                                Text("\(nextSetNumber)")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .leading)
                                
                                Text(formatTime(timerViewModel.currentSetTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .leading)
                                
                                Text(currentAvgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .trailing)
                                
                                if isLandscape {
                                    Text(currentMinBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(width: columnWidth, alignment: .trailing)
                                    
                                    Text(currentMaxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(width: columnWidth, alignment: .trailing)
                                }
                                
                                Text(formatTime(timerViewModel.elapsedTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .trailing)
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
                            
                            HStack(spacing: 0) {
                                Text("C\(nextCooldownNumber)")
                                    .font(.system(size: fontSize, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .leading)
                                
                                Text(formatTime(timerViewModel.currentSetTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .leading)
                                
                                Text(cooldownAvgBPM.map(String.init) ?? "---")
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .trailing)
                                
                                if isLandscape {
                                    Text(cooldownMinBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(width: columnWidth, alignment: .trailing)
                                    
                                    Text(cooldownMaxBPM.map(String.init) ?? "---")
                                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .frame(width: columnWidth, alignment: .trailing)
                                }
                                
                                Text(formatTime(totalTime))
                                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: columnWidth, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .id("activeRest")
                        }

                        // Remaining future placeholder rows for preset mode (grayed out, shown after active row)
                        if timerViewModel.isPresetMode && (timerViewModel.state == .running || timerViewModel.state == .paused || timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused) {
                            ForEach(timerViewModel.remainingPresetPlaceholderSets) { set in
                                presetPlaceholderRow(set: set, fontSize: fontSize, columnWidth: columnWidth, isLandscape: isLandscape)
                            }
                        }
                    }
                }

                // Pinned header
                HStack(spacing: 0) {
                    Text("Set")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: columnWidth, alignment: .leading)
                    
                    Text("Set Time")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: columnWidth, alignment: .leading)
                    
                    Text("Avg BPM")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: columnWidth, alignment: .trailing)
                    
                    if isLandscape {
                        Text("Min BPM")
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: columnWidth, alignment: .trailing)
                        
                        Text("Max BPM")
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: columnWidth, alignment: .trailing)
                    }
                    
                    Text("Total")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: columnWidth, alignment: .trailing)
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
    
    @ViewBuilder
    private func timerControlButtons(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let buttonSpacing = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
        let buttonPadding = isLandscape ? 40.0 : max(20.0, 24.0 * scaleFactor)
        let buttonFontSize = isLandscape ? 16.0 : max(16.0, 18.0 * scaleFactor)
        let buttonPaddingSize = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
        let isCooldownDisabled = timerViewModel.state == .idle && !timerViewModel.isPresetMode
        let isInCooldownMode = timerViewModel.isInCooldownMode
        let isCompleted = timerViewModel.isCompleted
        let isPresetMode = timerViewModel.isPresetMode

        // Work Set and Rest Set are completely disabled in preset mode
        // Otherwise: Work Set is available while the workout timer is running (both work and rest phases)
        // Rest Set is available only during work phases
        let workSetDisabled = isPresetMode || timerViewModel.state != .running || isInCooldownMode || isCompleted
        let restSetDisabled = isPresetMode || timerViewModel.state != .running || isInCooldownMode || timerViewModel.isTimingRestSet || isCompleted
        
        if isLandscape {
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
                        // Reset button - show confirmation alert
                        showResetAlert = true
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
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        } else {
            // Portrait: two rows (or one row in preset mode)
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
                            // Reset button - show confirmation alert
                            showResetAlert = true
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
                            .padding(.horizontal, buttonPaddingSize * 2)
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
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
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
                                .padding(.horizontal, buttonPaddingSize * 2)
                                .padding(.vertical, buttonPaddingSize)
                                .background((isCooldownDisabled || isInCooldownMode || isCompleted) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                                .cornerRadius(buttonPaddingSize)
                        }
                        .disabled(isCooldownDisabled || isInCooldownMode || isCompleted)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Bottom row: Work Set, Rest Set (hidden in preset mode)
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
                            }
                            .foregroundColor(workSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
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
                            }
                            .foregroundColor(restSetDisabled ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
                            .padding(.vertical, buttonPaddingSize)
                            .background(restSetDisabled ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                        }
                        .disabled(restSetDisabled)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        }
    }
    
    @ViewBuilder
    private func presetPlaceholderRow(set: SetRecord, fontSize: CGFloat, columnWidth: CGFloat, isLandscape: Bool) -> some View {
        let rowColor: Color = .gray.opacity(0.4)

        HStack(spacing: 0) {
            Text(timerViewModel.displayLabel(for: set))
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .leading)

            Text(formatTime(set.setTime))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .leading)

            Text("---")
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .trailing)

            if isLandscape {
                Text("---")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor)
                    .frame(width: columnWidth, alignment: .trailing)

                Text("---")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(rowColor)
                    .frame(width: columnWidth, alignment: .trailing)
            }

            Text(formatTime(set.totalTime))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(rowColor)
                .frame(width: columnWidth, alignment: .trailing)
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

}
