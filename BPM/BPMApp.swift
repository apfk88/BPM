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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-calorie-setup") {
            let defaults = UserDefaults.standard
            // Explicit empty values isolate the fixture from simulator-wide
            // preferences left by defaults/simctl. Removing a container value
            // can reveal those fallback values instead of creating a fresh user.
            for field in CalorieAnalytics.Field.allCases {
                defaults.set("", forKey: field.defaultsKey)
                defaults.removeObject(forKey: HealthKitImportedPreferences.localOnlyKey(for: field.defaultsKey))
            }
            for key in [CaloriesDefaultsKey.medsAffectingHr,
                        CalorieSetupDefaultsKey.promptDismissed,
                        CalorieSetupDefaultsKey.promptEligible] {
                defaults.set(false, forKey: key)
            }
            defaults.set("lb", forKey: CalorieSetupDefaultsKey.weightUnit)
            defaults.removeObject(forKey: MaxHeartRateSuggestionStore.DefaultsKey.pending)
            defaults.removeObject(forKey: MaxHeartRateSuggestionStore.DefaultsKey.dismissed)
        }
        if ProcessInfo.processInfo.arguments.contains("--calorie-setup-ui-test"),
           ProcessInfo.processInfo.arguments.contains("--max-hr-suggestion-fixture") {
            // Seed persistent UI-test state once, then relaunch without the fixture
            // flag to verify that accepting or dismissing survives a cold start.
            let defaults = UserDefaults.standard
            defaults.set("80", forKey: CaloriesDefaultsKey.weightKg)
            defaults.set("40", forKey: CaloriesDefaultsKey.ageYears)
            defaults.set("male", forKey: CaloriesDefaultsKey.sexAtBirth)
            defaults.set("195", forKey: CaloriesDefaultsKey.maxHrBpm)
            defaults.set(true, forKey: CalorieSetupDefaultsKey.promptDismissed)
            defaults.removeObject(forKey: MaxHeartRateSuggestionStore.DefaultsKey.dismissed)
            var zones = HeartRateZoneConfig(maxHeartRate: 195)
            zones.zone1Min = 90
            zones.zone1Max = 112
            HeartRateZoneStorage.shared.config = zones
            defaults.set(198, forKey: MaxHeartRateSuggestionStore.DefaultsKey.pending)
        }
        #endif
        AppAnalytics.configure()
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--calorie-setup-ui-test") {
            ICloudPreferencesSync.shared.start()
        }
        #else
        ICloudPreferencesSync.shared.start()
        #endif

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
