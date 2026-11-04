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
        AppAnalytics.configure()
        ICloudPreferencesSync.shared.start()

        // Set up notification observers for app termination/background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            BPMApp.endLiveActivity()
        }
        
        // The controller serializes launch cleanup with sensor/timer restoration.
        // A delayed global end here could erase a newly restored workout.
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            HeartRateActivityController.shared.refreshActivity()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--live-activity-ui-test") {
                    LiveActivityPreviewScene()
                } else if ProcessInfo.processInfo.arguments.contains("--workout-share-ui-test") {
                    WorkoutSharePreviewScene()
                } else {
                    HeartRateDisplayView()
                }
                #else
                HeartRateDisplayView()
                #endif
            }
            .environmentObject(bluetoothManager)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            #if DEBUG
            // Keep fixture readings isolated from the real Bluetooth lifecycle.
            if ProcessInfo.processInfo.arguments.contains("--live-activity-ui-test") { return }
            #endif
            switch newPhase {
            case .active:
                AppAnalytics.recordConfiguration()
                #if canImport(ActivityKit)
                if #available(iOS 16.1, *) {
                    HeartRateActivityController.shared.refreshActivity()
                }
                #endif
                bluetoothManager.enterForeground()
                bluetoothManager.startScanning()
                IdleTimer.disable()
            case .inactive:
                // Do not re-enable during transient inactive states (e.g. Control Center),
                // otherwise auto-lock can re-engage mid-session before we return to active.
                break
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
