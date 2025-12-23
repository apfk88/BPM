#if canImport(ActivityKit)
import ActivityKit
import os.log
import UIKit

/// Zone information for Live Activity display
struct ZoneInfo: Codable, Hashable {
    let name: String      // e.g., "Z1", "Z2", etc.
    let colorName: String // "gray", "green", "orange", "purple", "red"

    static let zone1 = ZoneInfo(name: "Z1", colorName: "gray")
    static let zone2 = ZoneInfo(name: "Z2", colorName: "green")
    static let zone3 = ZoneInfo(name: "Z3", colorName: "orange")
    static let zone4 = ZoneInfo(name: "Z4", colorName: "purple")
    static let zone5 = ZoneInfo(name: "Z5", colorName: "red")
}

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
struct HeartRateActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let bpm: Int?  // nil means disconnected/no data - display dashes
        let average: Int?
        let maximum: Int?
        let minimum: Int?
        let zone: ZoneInfo?
        let isSharing: Bool
        let isViewing: Bool
        let hasError: Bool

        init(bpm: Int?, average: Int?, maximum: Int?, minimum: Int?, zone: ZoneInfo? = nil, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
            self.bpm = bpm
            self.average = average
            self.maximum = maximum
            self.minimum = minimum
            self.zone = zone
            self.isSharing = isSharing
            self.isViewing = isViewing
            self.hasError = hasError
        }

        enum CodingKeys: String, CodingKey {
            case bpm, average, maximum, minimum, zone, isSharing, isViewing, hasError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
            average = try container.decodeIfPresent(Int.self, forKey: .average)
            maximum = try container.decodeIfPresent(Int.self, forKey: .maximum)
            minimum = try container.decodeIfPresent(Int.self, forKey: .minimum)
            zone = try container.decodeIfPresent(ZoneInfo.self, forKey: .zone)
            isSharing = try container.decodeIfPresent(Bool.self, forKey: .isSharing) ?? false
            isViewing = try container.decodeIfPresent(Bool.self, forKey: .isViewing) ?? false
            hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(bpm, forKey: .bpm)
            try container.encodeIfPresent(average, forKey: .average)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(zone, forKey: .zone)
            try container.encode(isSharing, forKey: .isSharing)
            try container.encode(isViewing, forKey: .isViewing)
            try container.encode(hasError, forKey: .hasError)
        }

        var trendDescription: String {
            guard let bpm, let average else { return "" }
            if bpm > average + 3 {
                return "Rising"
            } else if bpm < average - 3 {
                return "Falling"
            }
            return "Steady"
        }
    }

    var title: String
}

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
@MainActor
final class HeartRateActivityController {
    static let shared = HeartRateActivityController()

    private var activity: Activity<HeartRateActivityAttributes>?
    private let logger = Logger(subsystem: "com.bpmapp.client", category: "HeartRateActivity")
    private var isRequestingActivity = false
    

    private init() {
        // Clean up any lingering activities from previous sessions on launch
        Task { @MainActor in
            await endAllActivities()
        }
    }
    
    /// Restores any existing activity from a previous session
    private func restoreActivity() {
        let existingActivities = Activity<HeartRateActivityAttributes>.activities
        if let firstActivity = existingActivities.first {
            activity = firstActivity
        }
    }
    
    /// Ends all existing activities, not just the one stored in self.activity
    private func endAllActivities() async {
        let existingActivities = Activity<HeartRateActivityAttributes>.activities
        for activity in existingActivities {
            let content = ActivityContent(state: activity.content.state, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
        }
        activity = nil
        isRequestingActivity = false
    }

    func updateActivity(bpm: Int?, average: Int?, maximum: Int?, minimum: Int?, zone: ZoneInfo? = nil, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Restore activity if we don't have one stored (e.g., after app restart)
        if activity == nil {
            restoreActivity()
        }

        let state = HeartRateActivityAttributes.ContentState(
            bpm: bpm,
            average: average,
            maximum: maximum,
            minimum: minimum,
            zone: zone,
            isSharing: isSharing,
            isViewing: isViewing,
            hasError: hasError
        )

        Task { @MainActor [weak self] in
            guard let self else { return }

            let content = ActivityContent(state: state, staleDate: nil)

            if let currentActivity = activity {
                await currentActivity.update(content)
                return
            }

            if let existingActivity = Activity<HeartRateActivityAttributes>.activities.first {
                activity = existingActivity
                await existingActivity.update(content)
                return
            }

            guard !isRequestingActivity else {
                logger.debug("Activity request already in progress; skipping new request")
                return
            }

            isRequestingActivity = true
            defer { isRequestingActivity = false }

            let attributes = HeartRateActivityAttributes(title: "Current BPM")

            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                logger.error("Failed to start heart rate activity: \(error.localizedDescription)")
            }
        }
    }

    func endActivity() async {
        // End all activities, not just the one stored in self.activity
        // This ensures cleanup even after force-close scenarios
        await endAllActivities()
    }
}
#endif
