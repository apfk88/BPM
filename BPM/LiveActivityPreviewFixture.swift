#if DEBUG && canImport(ActivityKit)
import ActivityKit
import SwiftUI
import UIKit

/// Explicit opt-in fixture. It changes only transient ActivityKit state.
@MainActor
struct LiveActivityPreviewScene: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @State private var activityCount = 0
    @State private var activityDetails = ""
    @State private var lastAction = "Ready"
    @State private var isViewing = false
    @State private var isUpdating = false

    private let controller = HeartRateActivityController.shared

    var body: some View {
        NavigationStack {
            List {
                Section("System state") {
                    Text("Activities: \(activityCount)")
                        .accessibilityIdentifier("live-activity-count")
                    Text(lastAction)
                        .accessibilityIdentifier("live-activity-action")
                    if !activityDetails.isEmpty {
                        Text(activityDetails)
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("live-activity-details")
                    }
                }

                Section("Heart rate") {
                    action("Local 220") {
                        controller.endViewing()
                        isViewing = false
                        controller.updateActivity(
                            bpm: 220, average: 145, maximum: 220, minimum: 88,
                            zone: .zone5, heartRateExpiresAt: Date().addingTimeInterval(300)
                        )
                    }
                    action("Friend 188") {
                        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
                        controller.endLocalHeartRate()
                        isViewing = true
                        controller.updateActivity(
                            bpm: 188, average: 145, maximum: 188, minimum: 88,
                            zone: .zone4, isViewing: true,
                            heartRateExpiresAt: Date().addingTimeInterval(300)
                        )
                    }
                    action("No reading") {
                        controller.updateActivity(
                            bpm: nil, average: nil, maximum: nil, minimum: nil,
                            isViewing: isViewing
                        )
                    }
                    action("Stop viewing") {
                        controller.endViewing()
                        isViewing = false
                    }
                }

                Section("Workout") {
                    action("Timer only") {
                        controller.endLocalHeartRate()
                        controller.endViewing()
                        isViewing = false
                        controller.updateTimer(
                            elapsedSeconds: 3661, isRunning: true,
                            referenceDate: Date().addingTimeInterval(-3661)
                        )
                    }
                    action("End workout") {
                        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
                    }
                }

                Section("Layout and cleanup") {
                    action("Changing readings") {
                        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Live Activity layout check")
                        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
                        controller.endViewing()
                        controller.updateTimer(elapsedSeconds: nil, isRunning: false)
                        isViewing = false
                        // Repeated values exercise refreshes that change only the stats;
                        // crossing 100 exercises the two-to-three-digit layout boundary.
                        for (index, bpm) in [71, 71, 72, 78, 88, 98, 99, 100, 101, 111, 188, 220].enumerated() {
                            controller.updateActivity(
                                bpm: bpm, average: 100 + index, maximum: 220, minimum: 71,
                                heartRateExpiresAt: Date().addingTimeInterval(300)
                            )
                            await controller.waitForPendingUpdates()
                            try? await Task.sleep(for: .seconds(2))
                        }
                    }
                    action("Second activity") {
                        await controller.waitForPendingUpdates()
                        let state = HeartRateActivityAttributes.ContentState(
                            bpm: 99, average: nil, maximum: nil, minimum: nil
                        )
                        do {
                            _ = try Activity.request(
                                attributes: HeartRateActivityAttributes(title: "Comparison"),
                                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(300)),
                                pushType: nil
                            )
                        } catch {
                            lastAction = "Second activity failed: \(error.localizedDescription)"
                        }
                    }
                    action("Refresh count") { }
                    action("End all") {
                        isViewing = false
                        await controller.endActivity()
                    }
                }
            }
            .navigationTitle("Live Activity check")
            .disabled(isUpdating)
            .task {
                isUpdating = true
                // The manager also observes UIKit lifecycle notifications directly.
                // Prevent foregrounding the fixture from replacing its readings.
                NotificationCenter.default.removeObserver(
                    bluetoothManager, name: UIApplication.willEnterForegroundNotification, object: nil
                )
                NotificationCenter.default.removeObserver(
                    bluetoothManager, name: UIApplication.didEnterBackgroundNotification, object: nil
                )
                await controller.endActivity()
                await refreshSystemState()
                isUpdating = false
            }
        }
    }

    private func action(_ title: String, perform: @escaping @MainActor () async -> Void) -> some View {
        Button {
            isUpdating = true
            lastAction = title
            Task { @MainActor in
                await perform()
                await refreshSystemState()
                isUpdating = false
            }
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private func refreshSystemState() async {
        await controller.waitForPendingUpdates()
        let activities = Activity<HeartRateActivityAttributes>.activities
        activityCount = activities.count
        activityDetails = activities.map { activity in
            let state = activity.content.state
            let bpm = state.bpm.map(String.init) ?? "none"
            let timer = state.elapsedSeconds.map(String.init) ?? "none"
            return "\(activity.attributes.title): BPM \(bpm), timer \(timer), viewing \(state.isViewing)"
        }.sorted().joined(separator: "\n")
    }
}
#endif
