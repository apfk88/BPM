//
//  BPMApp.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI
import UIKit
import os.log

@main
struct BPMApp: App {
    @StateObject private var bluetoothManager = HeartRateBluetoothManager()
    @Environment(\.scenePhase) private var scenePhase
    private static let logger = Logger(subsystem: "com.bpmapp.client", category: "BPMApp")
    
    init() {
        // Set up notification observers for app termination/background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            BPMApp.endLiveActivity()
        }
        
        // Clean up any stale Live Activities on launch
        // Note: Force-closed apps cannot reliably clean up Live Activities due to iOS process termination.
        // Activities will be cleaned up on next app launch if no active session exists.
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task.detached(priority: .high) {
                // Small delay to let SharingService restore state first
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                // Only clean up if no active session (to avoid race with state restoration)
                let isSharing = await MainActor.run { SharingService.shared.isSharing }
                let isViewing = await MainActor.run { SharingService.shared.isViewing }
                if !isSharing && !isViewing {
                    await HeartRateActivityController.shared.endActivity()
                }
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
            @unknown default:
                IdleTimer.enable()
                break
            }
        }
    }
    
    private static func endLiveActivity() {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // End Live Activity on app termination
            // Note: Force-closed apps may not complete this cleanup due to iOS process termination
            Task.detached(priority: .high) {
                await HeartRateActivityController.shared.endActivity()
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
