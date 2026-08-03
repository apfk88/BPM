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

enum HeartRateActivityLifecycle {
    static let missingHeartRateDismissalInterval: TimeInterval = 10 * 60

    static func canStartActivity(bpm: Int?, hasError: Bool) -> Bool {
        (bpm ?? 0) > 0 || hasError
    }

    static func missingHeartRateStart(
        current: Date?,
        bpm: Int?,
        hasError: Bool,
        now: Date
    ) -> Date? {
        canStartActivity(bpm: bpm, hasError: hasError) ? nil : current ?? now
    }

    static func shouldDismiss(
        missingHeartRateSince: Date?,
        now: Date,
        interval: TimeInterval = missingHeartRateDismissalInterval
    ) -> Bool {
        guard let missingHeartRateSince else { return false }
        return now.timeIntervalSince(missingHeartRateSince) >= interval
    }
}

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
struct HeartRateActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let bpm: Int?  // nil means disconnected/no data - display dashes
        let average: Int?
        let maximum: Int?
        let minimum: Int?
        let elapsedSeconds: Int?
        let zone: ZoneInfo?
        let isSharing: Bool
        let isViewing: Bool
        let hasError: Bool

        init(bpm: Int?, average: Int?, maximum: Int?, minimum: Int?, elapsedSeconds: Int? = nil, zone: ZoneInfo? = nil, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
            self.bpm = bpm
            self.average = average
            self.maximum = maximum
            self.minimum = minimum
            self.elapsedSeconds = elapsedSeconds
            self.zone = zone
            self.isSharing = isSharing
            self.isViewing = isViewing
            self.hasError = hasError
        }

        enum CodingKeys: String, CodingKey {
            case bpm, average, maximum, minimum, elapsedSeconds, zone, isSharing, isViewing, hasError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
            average = try container.decodeIfPresent(Int.self, forKey: .average)
            maximum = try container.decodeIfPresent(Int.self, forKey: .maximum)
            minimum = try container.decodeIfPresent(Int.self, forKey: .minimum)
            elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
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
            try container.encodeIfPresent(elapsedSeconds, forKey: .elapsedSeconds)
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
    private var lastBpm: Int?
    private var lastAverage: Int?
    private var lastMaximum: Int?
    private var lastMinimum: Int?
    private var lastZone: ZoneInfo?
    private var lastIsSharing: Bool = false
    private var lastIsViewing: Bool = false
    private var lastHasError: Bool = false
    private var lastElapsedSeconds: Int?
    private var isEndingActivity = false
    private var missingHeartRateSince: Date?
    private var missingHeartRateTimer: Timer?
    

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
        lastBpm = bpm
        lastAverage = average
        lastMaximum = maximum
        lastMinimum = minimum
        lastZone = zone
        lastIsSharing = isSharing
        lastIsViewing = isViewing
        lastHasError = hasError
        applyUpdate()
    }

    func updateTimer(elapsedSeconds: Int?, isRunning: Bool) {
        lastElapsedSeconds = isRunning ? elapsedSeconds : nil
        applyUpdate()
    }

    private func applyUpdate() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !isEndingActivity else { return }

        let canStartActivity = HeartRateActivityLifecycle.canStartActivity(
            bpm: lastBpm,
            hasError: lastHasError
        )
        missingHeartRateSince = HeartRateActivityLifecycle.missingHeartRateStart(
            current: missingHeartRateSince,
            bpm: lastBpm,
            hasError: lastHasError,
            now: Date()
        )

        if canStartActivity {
            invalidateMissingHeartRateTimer()
        }

        // Restore activity if we don't have one stored (e.g., after app restart)
        if activity == nil {
            restoreActivity()
        }

        if !canStartActivity {
            guard activity != nil else { return }

            if HeartRateActivityLifecycle.shouldDismiss(
                missingHeartRateSince: missingHeartRateSince,
                now: Date()
            ) {
                endActivityIfNeeded()
                return
            }

            scheduleMissingHeartRateDismissal()
        }

        let state = HeartRateActivityAttributes.ContentState(
            bpm: lastBpm,
            average: lastAverage,
            maximum: lastMaximum,
            minimum: lastMinimum,
            elapsedSeconds: lastElapsedSeconds,
            zone: lastZone,
            isSharing: lastIsSharing,
            isViewing: lastIsViewing,
            hasError: lastHasError
        )

        Task { @MainActor [weak self] in
            guard let self else { return }

            let staleDate = missingHeartRateSince?.addingTimeInterval(
                HeartRateActivityLifecycle.missingHeartRateDismissalInterval
            )
            let content = ActivityContent(state: state, staleDate: staleDate)

            if let currentActivity = activity {
                await currentActivity.update(content)
                return
            }

            if let existingActivity = Activity<HeartRateActivityAttributes>.activities.first {
                activity = existingActivity
                await existingActivity.update(content)
                return
            }

            guard canStartActivity else { return }

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

    private func scheduleMissingHeartRateDismissal() {
        guard missingHeartRateTimer == nil, let missingHeartRateSince else { return }

        let dismissalDate = missingHeartRateSince.addingTimeInterval(
            HeartRateActivityLifecycle.missingHeartRateDismissalInterval
        )
        let interval = max(0, dismissalDate.timeIntervalSinceNow)
        guard interval > 0 else {
            endActivityIfNeeded()
            return
        }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleMissingHeartRateDismissalTimer()
            }
        }
        missingHeartRateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleMissingHeartRateDismissalTimer() {
        missingHeartRateTimer = nil

        if HeartRateActivityLifecycle.shouldDismiss(
            missingHeartRateSince: missingHeartRateSince,
            now: Date()
        ) {
            endActivityIfNeeded()
        } else {
            scheduleMissingHeartRateDismissal()
        }
    }

    private func invalidateMissingHeartRateTimer() {
        missingHeartRateTimer?.invalidate()
        missingHeartRateTimer = nil
    }

    private func endActivityIfNeeded() {
        guard !isEndingActivity else { return }
        guard activity != nil || !Activity<HeartRateActivityAttributes>.activities.isEmpty else { return }

        invalidateMissingHeartRateTimer()
        isEndingActivity = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await endAllActivities()
            isEndingActivity = false

            if HeartRateActivityLifecycle.canStartActivity(bpm: lastBpm, hasError: lastHasError) {
                applyUpdate()
            }
        }
    }

    private func resetCachedState() {
        lastBpm = nil
        lastAverage = nil
        lastMaximum = nil
        lastMinimum = nil
        lastZone = nil
        lastIsSharing = false
        lastIsViewing = false
        lastHasError = false
        lastElapsedSeconds = nil
        missingHeartRateSince = nil
        invalidateMissingHeartRateTimer()
    }

    func endActivity() async {
        // End all activities, not just the one stored in self.activity
        // This ensures cleanup even after force-close scenarios
        resetCachedState()
        isEndingActivity = true
        await endAllActivities()
        isEndingActivity = false
    }
}
#endif
