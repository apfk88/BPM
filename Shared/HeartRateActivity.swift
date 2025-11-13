#if canImport(ActivityKit)
import ActivityKit
import os.log

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
struct HeartRateActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let bpm: Int
        let average: Int?
        let maximum: Int?
        let minimum: Int?

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

    private init() {}

    func updateActivity(bpm: Int, average: Int?, maximum: Int?, minimum: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = HeartRateActivityAttributes.ContentState(
            bpm: bpm,
            average: average,
            maximum: maximum,
            minimum: minimum
        )

        Task { [weak self] in
            guard let self else { return }

            if let currentActivity = activity {
                await currentActivity.update(using: state)
            } else {
                let attributes = HeartRateActivityAttributes(title: "Current BPM")
                do {
                    activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
                } catch {
                    logger.error("Failed to start heart rate activity: %{public}@", error.localizedDescription)
                }
            }
        }
    }

    func endActivity() {
        guard let activity else { return }

        Task { [weak self] in
            await activity.end(dismissalPolicy: .immediate)
            self?.activity = nil
        }
    }
}
#endif
