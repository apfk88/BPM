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
    @State private var friendCodeInput: String = ""
    @State private var showFriendCodeInput = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    modeSelector
                    heartRateDisplay(height: geometry.size.height)
                    statsBar
                    sharingStatus
                }
            }
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView()
                .environmentObject(bluetoothManager)
        }
        .alert("Enter Friend's Code", isPresented: $showFriendCodeInput) {
            TextField("Code", text: $friendCodeInput)
                .textInputAutocapitalization(.characters)
            Button("Cancel", role: .cancel) {
                friendCodeInput = ""
            }
            Button("Connect") {
                if !friendCodeInput.isEmpty {
                    sharingService.startViewing(code: friendCodeInput)
                    appMode = .friendCode
                    friendCodeInput = ""
                }
            }
        } message: {
            Text("Enter the 6-character share code")
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
        .onDisappear {
            if appMode == .myDevice {
                bluetoothManager.stopScanning()
                IdleTimer.enable()
            }
        }
    }
    
    private var modeSelector: some View {
        HStack(spacing: 20) {
            Button {
                appMode = .myDevice
            } label: {
                Text("My Device")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(appMode == .myDevice ? .white : .gray)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(appMode == .myDevice ? Color.blue.opacity(0.3) : Color.clear)
                    .cornerRadius(8)
            }
            
            Button {
                if sharingService.friendCode == nil {
                    showFriendCodeInput = true
                } else {
                    appMode = .friendCode
                }
            } label: {
                Text("Friend's Code")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(appMode == .friendCode ? .white : .gray)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(appMode == .friendCode ? Color.blue.opacity(0.3) : Color.clear)
                    .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
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
    
    private var sharingStatus: some View {
        Group {
            if appMode == .myDevice && sharingService.isSharing {
                HStack {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.green)
                    Text("Sharing: \(sharingService.shareCode ?? "")")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        sharingService.stopSharing()
                    } label: {
                        Text("Stop")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
            } else if appMode == .friendCode {
                HStack {
                    if let friendCode = sharingService.friendCode {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.blue)
                        Text("Viewing: \(friendCode)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Button {
                        sharingService.stopViewing()
                        appMode = .myDevice
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                    if let error = sharingService.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(.leading, 10)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
            } else if appMode == .myDevice {
                HStack {
                    Spacer()
                    Button {
                        Task {
                            do {
                                try await sharingService.startSharing()
                            } catch {
                                // Error handled by sharingService
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Start Sharing")
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.3))
                        .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
            }
        }
    }

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
