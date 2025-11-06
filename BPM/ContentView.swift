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

struct HeartRateDisplayView: View {
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @StateObject private var sharingService = SharingService.shared
    @State private var showDevicePicker = false
    @State private var appMode: AppMode = .myDevice
    @State private var portraitBottomContentHeight: CGFloat = 0
    @State private var landscapeBottomContentHeight: CGFloat = 0

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
        }
        .onChange(of: sharingService.isViewing) { oldValue, newValue in
            if newValue && appMode == .myDevice && !oldValue {
                appMode = .friendCode
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
        ZStack {
            heartRateDisplay(size: geometry.size, isLandscape: false)
                .offset(y: -portraitBottomContentHeight / 2)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                statsBar(isLandscape: false, screenWidth: geometry.size.width)
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                sharingStatus
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: BottomContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .onPreferenceChange(BottomContentHeightKey.self) { portraitBottomContentHeight = $0 }
        .overlay(alignment: .top) {
            sharingCodeDisplay
        }
    }
    
    @ViewBuilder
    private func landscapeLayout(geometry: GeometryProxy, useSideLayout: Bool) -> some View {
        if useSideLayout {
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
                    sharingStatus
                }
            }
            .overlay(alignment: .top) {
                sharingCodeDisplay
            }
        } else {
            ZStack {
                heartRateDisplay(size: geometry.size, isLandscape: true)
                    .offset(y: -landscapeBottomContentHeight / 2)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    statsBar(isLandscape: false, screenWidth: geometry.size.width)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                    sharingStatus
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: BottomContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(BottomContentHeightKey.self) { landscapeBottomContentHeight = $0 }
            .overlay(alignment: .top) {
                sharingCodeDisplay
            }
        }
    }
    
    private var sharingCodeDisplay: some View {
        Group {
            if appMode == .myDevice && sharingService.isSharing, let code = sharingService.shareCode {
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.top, 20)
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
            .font(.system(size: fittedFontSize, weight: .bold, design: .rounded))
            .monospacedDigit()
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
    
    @ViewBuilder
    private var sharingStatus: some View {
        if appMode == .friendCode {
            if let error = sharingService.errorMessage {
                HStack {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private func statsBar(isLandscape: Bool, screenWidth: CGFloat) -> some View {
        // Scale factor: smaller screens get smaller sizes
        // Base scale on iPhone SE (375pt) = 1.0, scale down proportionally
        let scaleFactor = min(1.0, screenWidth / 375.0)
        let scaledSpacing = isLandscape ? 40.0 : max(8.0, 20.0 * scaleFactor)
        let scaledPadding = isLandscape ? 40.0 : max(12.0, 20.0 * scaleFactor)
        let scaledButtonSize = isLandscape ? 32.0 : max(20.0, 24.0 * scaleFactor)
        let scaledButtonPadding = isLandscape ? 16.0 : max(8.0, 12.0 * scaleFactor)
        
        if appMode == .myDevice {
                if isLandscape {
                    // Landscape mode - vertical stack on the right
                    VStack(spacing: 20) {
                        statColumn(title: "MAX", value: bluetoothManager.maxHeartRateLastHour, scaleFactor: 1.0)
                        statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour, scaleFactor: 1.0)
                        
                        HStack(spacing: 16) {
                            Button {
                                showDevicePicker = true
                            } label: {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: scaledButtonSize))
                                    .foregroundColor(.white)
                                    .padding(scaledButtonPadding)
                                    .background(Color.gray.opacity(0.3))
                                    .clipShape(Circle())
                            }
                            
                            Button {
                                if sharingService.isSharing {
                                    sharingService.stopSharing()
                                } else {
                                    Task {
                                        do {
                                            try await sharingService.startSharing()
                                        } catch {
                                            // Error handled by sharingService
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
                        }
                    }
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.8))
                } else {
                    // Portrait mode - stats and buttons on same line
                    HStack(spacing: scaledSpacing) {
                        statColumn(title: "MAX", value: bluetoothManager.maxHeartRateLastHour, scaleFactor: scaleFactor)
                        statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour, scaleFactor: scaleFactor)
                        
                        Spacer()
                        
                        Button {
                            showDevicePicker = true
                        } label: {
                            Image(systemName: "heart.fill")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(.white)
                                .padding(scaledButtonPadding)
                                .background(Color.gray.opacity(0.3))
                                .clipShape(Circle())
                        }
                        
                        Button {
                            if sharingService.isSharing {
                                sharingService.stopSharing()
                            } else {
                                Task {
                                    do {
                                        try await sharingService.startSharing()
                                    } catch {
                                        // Error handled by sharingService
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
                    }
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, max(12.0, 16.0 * scaleFactor))
                    .background(Color.black.opacity(0.8))
                }
            } else {
                // Friend mode stats
                if isLandscape {
                    // Landscape mode - vertical stack on the right
                    VStack(spacing: 20) {
                        statColumn(title: "MAX", value: sharingService.friendMaxHeartRate, scaleFactor: 1.0)
                        statColumn(title: "AVG", value: sharingService.friendAvgHeartRate, scaleFactor: 1.0)
                        
                        HStack(spacing: 16) {
                            Button {
                                showDevicePicker = true
                            } label: {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: scaledButtonSize))
                                    .foregroundColor(.white)
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
                        }
                    }
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, 20)
                    .background(Color.black.opacity(0.8))
                } else {
                    // Portrait mode - stats and buttons on same line
                    HStack(spacing: scaledSpacing) {
                        Spacer()
                        statColumn(title: "MAX", value: sharingService.friendMaxHeartRate, scaleFactor: scaleFactor)
                        statColumn(title: "AVG", value: sharingService.friendAvgHeartRate, scaleFactor: scaleFactor)
                        
                        Spacer()
                        
                        Button {
                            showDevicePicker = true
                        } label: {
                            Image(systemName: "heart.fill")
                                .font(.system(size: scaledButtonSize))
                                .foregroundColor(.white)
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
                    }
                    .padding(.horizontal, scaledPadding)
                    .padding(.vertical, max(12.0, 16.0 * scaleFactor))
                    .background(Color.black.opacity(0.8))
                }
            }
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil, scaleFactor: Double = 1.0) -> some View {
        VStack(spacing: 4 * scaleFactor) {
            Text(title)
                .font(.system(size: 20 * scaleFactor, weight: .semibold))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: 36 * scaleFactor, weight: .bold))
                .foregroundColor((value == nil && customText == nil) ? .gray : .white)
        }
    }

    private struct BottomContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
}
