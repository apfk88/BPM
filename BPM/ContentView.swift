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
    @State private var showDevicePicker = false
    @State private var appMode: AppMode = .myDevice
    @State private var isTimerMode = false
    @State private var showClearAlert = false
    @State private var showStartNewWorkoutAlert = false
    @State private var portraitBottomContentHeight: CGFloat = 0
    @State private var landscapeBottomContentHeight: CGFloat = 0
    @State private var heartRateExtremumDisplay: HeartRateExtremumDisplay = .max
    @State private var timerBPMDisplay: TimerBPMDisplay = .avg

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
        if isTimerMode {
            timerModeLayout(geometry: geometry, isLandscape: false)
        } else {
            ZStack {
                heartRateDisplay(size: geometry.size, isLandscape: false)
                    .offset(y: -portraitBottomContentHeight / 2 - geometry.size.height * 0.1)
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
        if isTimerMode {
            timerModeLayout(geometry: geometry, isLandscape: true)
        } else if useSideLayout {
            HStack(spacing: 0) {
                // BPM display on the left, taking most of the space
                heartRateDisplay(size: geometry.size, isLandscape: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Stats/buttons bar on the right side, vertically arranged
                VStack(spacing: 0) {
                    Spacer()
                    statsBar(isLandscape: true, screenWidth: geometry.size.width)
                        .padding(.trailing, geometry.safeAreaInsets.trailing)
                    Spacer()
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    connectionPrompt
                    errorMessageDisplay
                    sharingCodeDisplay
                }
            }
        } else {
            ZStack {
                heartRateDisplay(size: geometry.size, isLandscape: true)
                    .offset(y: -landscapeBottomContentHeight / 2)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    statsBar(isLandscape: true, screenWidth: geometry.size.width, useSplitLayout: true)
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
                Text(formattedShareCode(code))
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
        let baseFontSize = isLandscape
            ? min(size.width * 0.35, size.height * 0.8)
            : size.height * 0.65

        // Measure width of the widest expected value (three digits) at the base font size
        let referenceText = "888"
        let baseUIFont = UIFont.systemFont(ofSize: baseFontSize, weight: .bold)
        let baseWidth = referenceText.size(withAttributes: [.font: baseUIFont]).width

        // Leave some horizontal padding so the number never abuts the edges
        let horizontalAllowance = isLandscape ? size.width * 0.55 : size.width * 0.9
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
        (appMode == .friendCode && sharingService.isViewing) ? .green : .white
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
        let hasDeviceConnection = bluetoothManager.connectedDevice != nil
        let hasFriendConnection = sharingService.isViewing && sharingService.friendCode != nil
        return !hasDeviceConnection && !hasFriendConnection
    }

    @ViewBuilder
    private func statsBar(isLandscape: Bool, screenWidth: CGFloat, useSplitLayout: Bool = false) -> some View {
        // Scale factor: smaller screens get smaller sizes
        // Base scale on iPhone SE (375pt) = 1.0, scale down proportionally
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let scaledSpacing = isLandscape ? 40.0 : max(8.0, 20.0 * scaleFactor)
        let scaledPadding = isLandscape ? 40.0 : max(12.0, 20.0 * scaleFactor)
        let scaledButtonSize = isLandscape ? 32.0 : max(20.0, 24.0 * scaleFactor)
        let scaledButtonPadding = isLandscape ? 16.0 : max(8.0, 12.0 * scaleFactor)
        let splitLayoutSpacing = useSplitLayout ? max(24.0, scaledSpacing * 0.6) : scaledSpacing
        
        if appMode == .myDevice {
                if isLandscape {
                    if useSplitLayout {
                        HStack(alignment: .center, spacing: splitLayoutSpacing) {
                            HStack(spacing: splitLayoutSpacing) {
                                statColumn(
                                    title: heartRateExtremumDisplay.title,
                                    value: myDeviceExtremumValue(for: heartRateExtremumDisplay),
                                    scaleFactor: 1.0,
                                    onTap: cycleHeartRateExtremumDisplay
                                )
                                statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour, scaleFactor: 1.0)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 16) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(heartButtonColor)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                                
                                Button {
                                    if sharingService.isSharing {
                                        sharingService.stopSharing()
                                    } else {
                                        if bluetoothManager.connectedDevice == nil {
                                            sharingService.errorMessage = "Please connect a heart rate device before sharing."
                                            sharingService.errorContext = .sharing
                                        } else {
                                            Task {
                                                do {
                                                    try await sharingService.startSharing()
                                                } catch {
                                                    // Error handled by sharingService
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(sharingService.isSharing ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                                
                                Button {
                                    isTimerMode.toggle()
                                    if !isTimerMode {
                                        timerViewModel.reset()
                                    }
                                } label: {
                                    Image(systemName: "stopwatch")
                                        .renderingMode(.template)
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(isTimerMode ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaledPadding)
                        .padding(.vertical, 20)
                        .background(Color.black.opacity(0.8))
                    } else {
                        // Landscape mode - vertical stack on the right
                        VStack(spacing: 20) {
                            statColumn(
                                title: heartRateExtremumDisplay.title,
                                value: myDeviceExtremumValue(for: heartRateExtremumDisplay),
                                scaleFactor: 1.0,
                                onTap: cycleHeartRateExtremumDisplay
                            )
                            statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour, scaleFactor: 1.0)

                            HStack(spacing: 16) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(heartButtonColor)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                                
                                Button {
                                    if sharingService.isSharing {
                                        sharingService.stopSharing()
                                    } else {
                                        if bluetoothManager.connectedDevice == nil {
                                            sharingService.errorMessage = "Please connect a heart rate device before sharing."
                                            sharingService.errorContext = .sharing
                                        } else {
                                            Task {
                                                do {
                                                    try await sharingService.startSharing()
                                                } catch {
                                                    // Error handled by sharingService
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(sharingService.isSharing ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                                
                                Button {
                                    isTimerMode.toggle()
                                    if !isTimerMode {
                                        timerViewModel.reset()
                                    }
                                } label: {
                                    Image(systemName: "stopwatch")
                                        .renderingMode(.template)
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(isTimerMode ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, scaledPadding)
                        .padding(.vertical, 20)
                        .background(Color.black.opacity(0.8))
                    }
                } else {
                    // Portrait mode - stats and buttons on same line
                    HStack(spacing: scaledSpacing) {
                        statColumn(
                            title: heartRateExtremumDisplay.title,
                            value: myDeviceExtremumValue(for: heartRateExtremumDisplay),
                            scaleFactor: scaleFactor,
                            onTap: cycleHeartRateExtremumDisplay
                        )
                        statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour, scaleFactor: scaleFactor)

                        Spacer()

                        Button {
                            showDevicePicker = true
                        } label: {
                            Image(systemName: "heart.fill")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(heartButtonColor)
                                .padding(scaledButtonPadding)
                                .background(
                                    Circle().fill(Color.gray.opacity(0.3))
                                )
                        }
                        
                        Button {
                            if sharingService.isSharing {
                                sharingService.stopSharing()
                            } else {
                                if bluetoothManager.connectedDevice == nil {
                                    sharingService.errorMessage = "Please connect a heart rate device before sharing."
                                    sharingService.errorContext = .sharing
                                } else {
                                    Task {
                                        do {
                                            try await sharingService.startSharing()
                                        } catch {
                                            // Error handled by sharingService
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(sharingService.isSharing ? .green : .white)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                        
                        Button {
                            isTimerMode.toggle()
                            if !isTimerMode {
                                timerViewModel.reset()
                            }
                        } label: {
                            Image(systemName: "stopwatch")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(isTimerMode ? .green : .white)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, max(12.0, 16.0 * scaleFactor))
                    .background(Color.black.opacity(0.8))
                }
            } else {
                // Friend mode stats
                if isLandscape {
                    if useSplitLayout {
                        HStack(alignment: .center, spacing: splitLayoutSpacing) {
                            HStack(spacing: splitLayoutSpacing) {
                                statColumn(
                                    title: heartRateExtremumDisplay.title,
                                    value: friendExtremumValue(for: heartRateExtremumDisplay),
                                    scaleFactor: 1.0,
                                    onTap: cycleHeartRateExtremumDisplay
                                )
                                statColumn(title: "AVG", value: sharingService.friendAvgHeartRate, scaleFactor: 1.0)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 16) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(heartButtonColor)
                                        .padding(scaledButtonPadding)
                                        .background(Color.gray.opacity(0.3))
                                        .clipShape(Circle())
                                }
                                
                                Button {
                                    // Disabled - no action
                                } label: {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(.gray)
                                        .padding(scaledButtonPadding)
                                        .background(Color.gray.opacity(0.2))
                                        .clipShape(Circle())
                                }
                                .disabled(true)
                                
                                Button {
                                    isTimerMode.toggle()
                                    if !isTimerMode {
                                        timerViewModel.reset()
                                    }
                                } label: {
                                    Image(systemName: "stopwatch")
                                        .renderingMode(.template)
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(isTimerMode ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(
                                            Circle().fill(Color.gray.opacity(0.3))
                                        )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scaledPadding)
                        .padding(.vertical, 20)
                        .background(Color.black.opacity(0.8))
                    } else {
                        // Landscape mode - vertical stack on the right
                        VStack(spacing: 20) {
                            statColumn(
                                title: heartRateExtremumDisplay.title,
                                value: friendExtremumValue(for: heartRateExtremumDisplay),
                                scaleFactor: 1.0,
                                onTap: cycleHeartRateExtremumDisplay
                            )
                            statColumn(title: "AVG", value: sharingService.friendAvgHeartRate, scaleFactor: 1.0)

                            HStack(spacing: 16) {
                                Button {
                                    showDevicePicker = true
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(heartButtonColor)
                                        .padding(scaledButtonPadding)
                                        .background(Color.gray.opacity(0.3))
                                        .clipShape(Circle())
                                }
                                
                                Button {
                                    // Disabled - no action
                                } label: {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(.gray)
                                        .padding(scaledButtonPadding)
                                        .background(Color.gray.opacity(0.2))
                                        .clipShape(Circle())
                                }
                                .disabled(true)
                                
                                Button {
                                    isTimerMode.toggle()
                                    if !isTimerMode {
                                        timerViewModel.reset()
                                    }
                                } label: {
                                    Image(systemName: "stopwatch")
                                        .renderingMode(.template)
                                        .font(.system(size: scaledButtonSize))
                                        .foregroundColor(isTimerMode ? .green : .white)
                                        .padding(scaledButtonPadding)
                                        .background(Color.gray.opacity(0.3))
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.horizontal, scaledPadding)
                        .padding(.vertical, 20)
                        .background(Color.black.opacity(0.8))
                    }
                } else {
                    // Portrait mode - stats and buttons on same line
                    HStack(spacing: scaledSpacing) {
                        statColumn(
                            title: heartRateExtremumDisplay.title,
                            value: friendExtremumValue(for: heartRateExtremumDisplay),
                            scaleFactor: scaleFactor,
                            onTap: cycleHeartRateExtremumDisplay
                        )
                        statColumn(title: "AVG", value: sharingService.friendAvgHeartRate, scaleFactor: scaleFactor)

                        Spacer()

                        Button {
                            showDevicePicker = true
                        } label: {
                            Image(systemName: "heart.fill")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(heartButtonColor)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                        
                        Button {
                            // Disabled - no action
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(.gray)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.2))
                                .clipShape(Circle())
                        }
                        .disabled(true)
                        
                        Button {
                            isTimerMode.toggle()
                            if !isTimerMode {
                                timerViewModel.reset()
                            }
                        } label: {
                            Image(systemName: "stopwatch")
                                .renderingMode(.template)
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(isTimerMode ? .green : .white)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, max(12.0, 16.0 * scaleFactor))
                    .background(Color.black.opacity(0.8))
                }
            }
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0, onTap: (() -> Void)? = nil) -> some View {
        VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: 20 * scaleFactor, weight: .semibold))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: 36 * scaleFactor, weight: .bold, design: .monospaced))
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
                .foregroundColor(.white)
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
            }
        } else {
            VStack(alignment: .center, spacing: 4) {
                Text("BPM")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray)
                Text(displayedHeartRate.map(String.init) ?? "---")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }
    
    @ViewBuilder
    private func timerModeLayout(geometry: GeometryProxy, isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            // Top bar with device picker and clear button
            HStack(spacing: 16) {
                Button {
                    showDevicePicker = true
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20))
                        .foregroundColor(heartButtonColor)
                        .padding(12)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
                
                Spacer()
                
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
            .alert("Start New Workout", isPresented: $showStartNewWorkoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Start", role: .destructive) {
                    timerViewModel.reset()
                    timerViewModel.start()
                }
            } message: {
                Text("Starting a new workout will clear all current timer data. This cannot be undone.")
            }
            
            // Stopwatch display with BPM (or completion stats when done)
            stopwatchDisplay(isLandscape: isLandscape)
                .padding(.top, 12)
            
            // Set tracking table
            if !timerViewModel.sets.isEmpty || timerViewModel.state == .running || timerViewModel.state == .paused || timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                setsTable(isLandscape: isLandscape, screenWidth: geometry.size.width)
                    .padding(.horizontal, isLandscape ? 40 : 20)
                    .padding(.top, 8)
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
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)
        let setLabel = isCooldown ? "Cooldown" : (timerViewModel.isCompleted ? "Avg Set" : "Set")
        
        // For cooldown, calculate countdown from 2 minutes
        let cooldownTotal = 120.0 // 2 minutes
        let displaySetTime: TimeInterval = isCooldown 
            ? max(0, cooldownTotal - timerViewModel.currentSetTime)
            : (timerViewModel.isCompleted ? (timerViewModel.avgSetTime ?? 0) : timerViewModel.currentSetTime)
        
        // Pre-calculate complex values to help compiler type-checking
        let totalTimeTitle = timerViewModel.isCompleted ? "Total Time" : "Total"
        let setTimeValue: String = {
            if timerViewModel.isCompleted {
                return timerViewModel.avgSetTime.map(formatTime) ?? "---"
            } else {
                return formatTime(displaySetTime)
            }
        }()
        let avgRestValue = timerViewModel.avgRestTime.map(formatTime) ?? "---"
        let maxBPMValue = timerViewModel.maxHeartRate.map(String.init) ?? "---"
        let avgBPMValue = timerViewModel.avgHeartRate.map(String.init) ?? "---"
        
        // Landscape: show Total, Set, Avg Rest, Current BPM/HRR, Max BPM, Avg BPM
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                landscapeStatColumn(
                    title: totalTimeTitle,
                    value: formatTime(totalTime),
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
                    alignment: .trailing
                )
            }
            .padding(.horizontal, 20)
        }
    }
    
    @ViewBuilder
    private func portraitStopwatchDisplay() -> some View {
        // Always show stats - don't hide them when completed
        let isCooldown = timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused
        let totalTime = isCooldown ? timerViewModel.frozenElapsedTime : (timerViewModel.isCompleted ? timerViewModel.frozenElapsedTime : timerViewModel.elapsedTime)
        let setLabel = isCooldown ? "Cooldown" : (timerViewModel.isCompleted ? "Avg Set" : "Set")
        
        // For cooldown, calculate countdown from 2 minutes
        let cooldownTotal = 120.0 // 2 minutes
        let displaySetTime: TimeInterval = isCooldown 
            ? max(0, cooldownTotal - timerViewModel.currentSetTime)
            : (timerViewModel.isCompleted ? (timerViewModel.avgSetTime ?? 0) : timerViewModel.currentSetTime)
        
        // Pre-calculate complex values
        let totalTimeTitle = timerViewModel.isCompleted ? "Total Time" : "Total"
        let setTimeValue: String = {
            if timerViewModel.isCompleted {
                return timerViewModel.avgSetTime.map(formatTime) ?? "---"
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
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(totalTimeTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(formatTime(totalTime))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .center, spacing: 4) {
                    Text(setLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(setTimeValue)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(bpmTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                    Text(bpmValue)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if timerViewModel.isCompleted {
                        timerBPMDisplay.cycle()
                    }
                }
            }
            .padding(.horizontal, 20)
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
                        
                        // Data rows
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
                // Auto-scroll to most recent set
                if let lastSet = timerViewModel.sets.last {
                    withAnimation {
                        proxy.scrollTo(lastSet.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: timerViewModel.state) { _, _ in
                // Scroll to active row when state changes
                if timerViewModel.state == .running {
                    withAnimation {
                        proxy.scrollTo("active", anchor: .bottom)
                    }
                } else if timerViewModel.state == .cooldown {
                    withAnimation {
                        proxy.scrollTo("activeRest", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: isLandscape ? 600 : 700)
    }
    
    @ViewBuilder
    private func timerControlButtons(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let buttonSpacing = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
        let buttonPadding = isLandscape ? 40.0 : max(20.0, 24.0 * scaleFactor)
        let buttonFontSize = isLandscape ? 16.0 : max(16.0, 18.0 * scaleFactor)
        let buttonPaddingSize = isLandscape ? 12.0 : max(12.0, 16.0 * scaleFactor)
        let isCooldownDisabled = timerViewModel.state == .idle
        let isInCooldownMode = timerViewModel.isInCooldownMode
        
        // Work Set is available while the workout timer is running (both work and rest phases)
        // Rest Set is available only during work phases
        let workSetDisabled = timerViewModel.state != .running || isInCooldownMode
        let restSetDisabled = timerViewModel.state != .running || isInCooldownMode || timerViewModel.isTimingRestSet
        
        if isLandscape {
            // Landscape: single row with all buttons
            HStack(spacing: buttonSpacing) {
                // Start/Pause button
                Button {
                    if timerViewModel.state == .running {
                        timerViewModel.stop()
                    } else {
                        if timerViewModel.isCompleted {
                            showStartNewWorkoutAlert = true
                        } else {
                            timerViewModel.start()
                        }
                    }
                } label: {
                    Text(timerViewModel.state == .running ? "Pause" : "Start")
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor(isInCooldownMode ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background(isInCooldownMode ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                }
                .disabled(isInCooldownMode)
                .frame(maxWidth: .infinity)
                
                // End button
                Button {
                    if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                        timerViewModel.stopCooldownAndComplete()
                    } else {
                        if timerViewModel.state == .running || timerViewModel.state == .paused {
                            timerViewModel.captureSet()
                        }
                        timerViewModel.stopAndComplete()
                    }
                } label: {
                    Text("End")
                        .font(.system(size: buttonFontSize, weight: .semibold))
                        .foregroundColor((timerViewModel.state == .idle && timerViewModel.sets.isEmpty) ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background((timerViewModel.state == .idle && timerViewModel.sets.isEmpty) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                }
                .disabled(timerViewModel.state == .idle && timerViewModel.sets.isEmpty)
                .frame(maxWidth: .infinity)
                
                // HRR button
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
                        .foregroundColor(isCooldownDisabled || isInCooldownMode ? .gray.opacity(0.5) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, buttonPaddingSize * 1.5)
                        .padding(.vertical, buttonPaddingSize)
                        .background((isCooldownDisabled || isInCooldownMode) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                        .cornerRadius(buttonPaddingSize)
                }
                .disabled(isCooldownDisabled || isInCooldownMode)
                .frame(maxWidth: .infinity)
                
                // Work Set button
                Button {
                    timerViewModel.captureSet()
                } label: {
                    Text("Work Set")
                        .font(.system(size: buttonFontSize, weight: .semibold))
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
                    Text("Rest Set")
                        .font(.system(size: buttonFontSize, weight: .semibold))
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
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        } else {
            // Portrait: two rows
            VStack(spacing: buttonSpacing) {
                // Top row: Start/Pause, End, HRR
                HStack(spacing: buttonSpacing) {
                    Button {
                        if timerViewModel.state == .running {
                            timerViewModel.stop()
                        } else {
                            if timerViewModel.isCompleted {
                                showStartNewWorkoutAlert = true
                            } else {
                                timerViewModel.start()
                            }
                        }
                    } label: {
                        Text(timerViewModel.state == .running ? "Pause" : "Start")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor(isInCooldownMode ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
                            .padding(.vertical, buttonPaddingSize)
                            .background(isInCooldownMode ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(isInCooldownMode)
                    .frame(maxWidth: .infinity)
                    
                    Button {
                        if timerViewModel.state == .cooldown || timerViewModel.state == .cooldownPaused {
                            timerViewModel.stopCooldownAndComplete()
                        } else {
                            if timerViewModel.state == .running || timerViewModel.state == .paused {
                                timerViewModel.captureSet()
                            }
                            timerViewModel.stopAndComplete()
                        }
                    } label: {
                        Text("End")
                            .font(.system(size: buttonFontSize, weight: .semibold))
                            .foregroundColor((timerViewModel.state == .idle && timerViewModel.sets.isEmpty) ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
                            .padding(.vertical, buttonPaddingSize)
                            .background((timerViewModel.state == .idle && timerViewModel.sets.isEmpty) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(timerViewModel.state == .idle && timerViewModel.sets.isEmpty)
                    .frame(maxWidth: .infinity)
                    
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
                            .foregroundColor(isCooldownDisabled || isInCooldownMode ? .gray.opacity(0.5) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, buttonPaddingSize * 2)
                            .padding(.vertical, buttonPaddingSize)
                            .background((isCooldownDisabled || isInCooldownMode) ? Color.gray.opacity(0.1) : Color.gray.opacity(0.3))
                            .cornerRadius(buttonPaddingSize)
                    }
                    .disabled(isCooldownDisabled || isInCooldownMode)
                    .frame(maxWidth: .infinity)
                }
                
                // Bottom row: Work Set, Rest Set
                HStack(spacing: buttonSpacing) {
                    Button {
                        timerViewModel.captureSet()
                    } label: {
                        Text("Work Set")
                            .font(.system(size: buttonFontSize, weight: .semibold))
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
                        Text("Rest Set")
                            .font(.system(size: buttonFontSize, weight: .semibold))
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
            .padding(.horizontal, buttonPadding)
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, milliseconds)
    }
}

