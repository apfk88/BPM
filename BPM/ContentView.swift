//
//  ContentView.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI

enum AppMode {
    case myDevice
    case friendCode
}

struct HeartRateDisplayView: View {
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @StateObject private var sharingService = SharingService.shared
    @State private var showDevicePicker = false
    @State private var appMode: AppMode = .myDevice

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    heartRateDisplay(height: geometry.size.height)
                    statsBar
                    sharingStatus
                }
                .overlay(alignment: .top) {
                    sharingCodeDisplay
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
                IdleTimer.enable()
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
    private func heartRateDisplay(height: CGFloat) -> some View {
        let fontSize = height * 0.88
        Group {
            if appMode == .myDevice {
                if let heartRate = bluetoothManager.currentHeartRate {
                    Text("\(heartRate)")
                } else {
                    Text("---")
                }
            } else {
                if let heartRate = sharingService.friendHeartRate {
                    Text("\(heartRate)")
                } else {
                    Text("---")
                }
            }
        }
        .font(.system(size: fontSize, weight: .bold, design: .rounded))
        .foregroundColor(displayedHeartRate == nil ? .gray : .white)
        .minimumScaleFactor(0.1)
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
    private var statsBar: some View {
        if appMode == .myDevice {
            HStack(spacing: 40) {
                if let connectedDevice = bluetoothManager.connectedDevice,
                   let deviceName = bluetoothManager.getDeviceName(for: connectedDevice.identifier) {
                    statColumn(title: "NAME", value: nil, customText: deviceName)
                    Spacer()
                }
                statColumn(title: "MAX", value: bluetoothManager.maxHeartRateLastHour)
                Spacer()
                statColumn(title: "AVG", value: bluetoothManager.avgHeartRateLastHour)
                Spacer()
                Button {
                    showDevicePicker = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .padding()
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
                    Image(systemName: sharingService.isSharing ? "link.circle.fill" : "link.circle")
                        .font(.system(size: 32))
                        .foregroundColor(sharingService.isSharing ? .green : .white)
                        .padding()
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 30)
            .background(Color.black.opacity(0.8))
        } else {
            // Friend mode stats
            HStack(spacing: 40) {
                Spacer()
                statColumn(title: "MAX", value: sharingService.friendMaxHeartRate)
                Spacer()
                statColumn(title: "AVG", value: sharingService.friendAvgHeartRate)
                Spacer()
                Button {
                    showDevicePicker = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 30)
            .background(Color.black.opacity(0.8))
        }
    }

    private func statColumn(title: String, value: Int?, customText: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.gray)
            Text(customText ?? value.map(String.init) ?? "---")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor((value == nil && customText == nil) ? .gray : .white)
        }
    }
}
