//
//  ContentView.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI

struct HeartRateDisplayView: View {
    @EnvironmentObject var bluetoothManager: HeartRateBluetoothManager
    @State private var showDevicePicker = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    heartRateDisplay(height: geometry.size.height)
                    statsBar
                }
            }
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView()
                .environmentObject(bluetoothManager)
        }
        .onAppear {
            bluetoothManager.startScanning()
            IdleTimer.disable()
        }
        .onDisappear {
            bluetoothManager.stopScanning()
            IdleTimer.enable()
        }
    }

    @ViewBuilder
    private func heartRateDisplay(height: CGFloat) -> some View {
        let fontSize = height * 0.88
        Group {
            if let heartRate = bluetoothManager.currentHeartRate {
                Text("\(heartRate)")
            } else {
                Text("---")
            }
        }
        .font(.system(size: fontSize, weight: .bold, design: .rounded))
        .foregroundColor(bluetoothManager.currentHeartRate == nil ? .gray : .white)
        .minimumScaleFactor(0.1)
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statsBar: some View {
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
