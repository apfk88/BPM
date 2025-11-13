#if canImport(ActivityKit)
import ActivityKit
import os.log
import UIKit

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
struct HeartRateActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let bpm: Int
        let average: Int?
        let maximum: Int?
        let minimum: Int?
        let isSharing: Bool
        let isViewing: Bool
        let hasError: Bool

        init(bpm: Int, average: Int?, maximum: Int?, minimum: Int?, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
            self.bpm = bpm
            self.average = average
            self.maximum = maximum
            self.minimum = minimum
            self.isSharing = isSharing
            self.isViewing = isViewing
            self.hasError = hasError
        }
        
        enum CodingKeys: String, CodingKey {
            case bpm, average, maximum, minimum, isSharing, isViewing, hasError
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bpm = try container.decode(Int.self, forKey: .bpm)
            average = try container.decodeIfPresent(Int.self, forKey: .average)
            maximum = try container.decodeIfPresent(Int.self, forKey: .maximum)
            minimum = try container.decodeIfPresent(Int.self, forKey: .minimum)
            isSharing = try container.decodeIfPresent(Bool.self, forKey: .isSharing) ?? false
            isViewing = try container.decodeIfPresent(Bool.self, forKey: .isViewing) ?? false
            hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bpm, forKey: .bpm)
            try container.encodeIfPresent(average, forKey: .average)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encode(isSharing, forKey: .isSharing)
            try container.encode(isViewing, forKey: .isViewing)
            try container.encode(hasError, forKey: .hasError)
        }

        var trendDescription: String {
            guard let average else { return "" }
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
    }

    func updateActivity(bpm: Int, average: Int?, maximum: Int?, minimum: Int?, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
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
            isSharing: isSharing,
            isViewing: isViewing,
            hasError: hasError
        )

        Task { [weak self] in
            guard let self else { return }

            if let currentActivity = activity {
                // Update existing activity (works in background)
                let content = ActivityContent(state: state, staleDate: nil)
                await currentActivity.update(content)
            } else {
                // Try to create new activity
                // Note: ActivityKit requires foreground to create activities in main app
                // Extensions can create activities, so this will work there
                // In main app background, this will fail gracefully with an error we catch below
                
                let attributes = HeartRateActivityAttributes(title: "Current BPM")
                let content = ActivityContent(state: state, staleDate: nil)
                do {
                    activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                } catch {
                    logger.error("Failed to start heart rate activity: \(error.localizedDescription)")
                }
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
