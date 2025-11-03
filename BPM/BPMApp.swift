//
//  BPMApp.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI
import UIKit

@main
struct BPMApp: App {
    @StateObject private var bluetoothManager = HeartRateBluetoothManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HeartRateDisplayView()
                .environmentObject(bluetoothManager)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                bluetoothManager.startScanning()
                IdleTimer.disable()
            case .inactive, .background:
                bluetoothManager.stopScanning()
                IdleTimer.enable()
            @unknown default:
                IdleTimer.enable()
                break
            }
        }
    }
}

enum IdleTimer {
    static func disable() { setDisabled(true) }
    static func enable() { setDisabled(false) }

    private static func setDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}
