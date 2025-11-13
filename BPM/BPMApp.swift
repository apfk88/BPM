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
    
    init() {
        // Set up notification observers for app termination/background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            BPMApp.endLiveActivityIfNeeded()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            BPMApp.endLiveActivityIfNeeded()
        }
        
        // Clean up any stale Live Activities on launch
        // (in case app was force-closed previously)
        // Always end on launch - the app will recreate it when sharing/viewing starts
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                HeartRateActivityController.shared.endActivity()
            }
        }
        #endif
    }

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
                BPMApp.endLiveActivityIfNeeded()
            @unknown default:
                IdleTimer.enable()
                BPMApp.endLiveActivityIfNeeded()
                break
            }
        }
    }
    
    static func endLiveActivityIfNeeded() {
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
