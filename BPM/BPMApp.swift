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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                bluetoothManager.enterForeground()
                bluetoothManager.startScanning()
                IdleTimer.disable()
            case .inactive:
                IdleTimer.enable()
            case .background:
                bluetoothManager.enterBackground()
                IdleTimer.enable()
                // End live activity when app goes to background/terminates
                endLiveActivityIfNeeded()
            @unknown default:
                IdleTimer.enable()
                endLiveActivityIfNeeded()
                break
            }
        }
    }
    
    private func endLiveActivityIfNeeded() {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // End live activity if sharing or viewing is active
            // This ensures cleanup when app is closed/terminated
            if SharingService.shared.isSharing || SharingService.shared.isViewing {
                Task { @MainActor in
                    HeartRateActivityController.shared.endActivity()
                }
            }
        }
        #endif
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
