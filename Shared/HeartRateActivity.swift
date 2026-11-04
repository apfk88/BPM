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
    static func shouldShowActivity(bpm: Int?, hasActiveTimer: Bool) -> Bool {
        (bpm ?? 0) > 0 || hasActiveTimer
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
        var timerReferenceDate: Date? = nil
        var timerEndDate: Date? = nil
        let zone: ZoneInfo?
        let isSharing: Bool
        let isViewing: Bool
        let hasError: Bool

        init(bpm: Int?, average: Int?, maximum: Int?, minimum: Int?, elapsedSeconds: Int? = nil, timerReferenceDate: Date? = nil, timerEndDate: Date? = nil, zone: ZoneInfo? = nil, isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false) {
            self.bpm = bpm
            self.average = average
            self.maximum = maximum
            self.minimum = minimum
            self.elapsedSeconds = elapsedSeconds
            self.timerReferenceDate = timerReferenceDate
            self.timerEndDate = timerEndDate
            self.zone = zone
            self.isSharing = isSharing
            self.isViewing = isViewing
            self.hasError = hasError
        }

        enum CodingKeys: String, CodingKey {
            case bpm, average, maximum, minimum, elapsedSeconds, timerReferenceDate, timerEndDate, zone, isSharing, isViewing, hasError
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
            average = try container.decodeIfPresent(Int.self, forKey: .average)
            maximum = try container.decodeIfPresent(Int.self, forKey: .maximum)
            minimum = try container.decodeIfPresent(Int.self, forKey: .minimum)
            elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
            timerReferenceDate = try container.decodeIfPresent(Date.self, forKey: .timerReferenceDate)
            timerEndDate = try container.decodeIfPresent(Date.self, forKey: .timerEndDate)
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
            try container.encodeIfPresent(timerReferenceDate, forKey: .timerReferenceDate)
            try container.encodeIfPresent(timerEndDate, forKey: .timerEndDate)
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

/// Keep ActivityKit effects behind one serial reconciler so a queued reading cannot
/// recreate an activity after a disconnect, or erase a newly started workout.
@available(iOS 16.1, iOSApplicationExtension 16.1, *)
@MainActor
protocol HeartRateActivityClient: AnyObject {
    var areActivitiesEnabled: Bool { get }
    var activityState: ActivityState? { get }
    func endAllActivities() async
    func update(_ content: ActivityContent<HeartRateActivityAttributes.ContentState>) async
    func start(_ content: ActivityContent<HeartRateActivityAttributes.ContentState>) throws
}

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
@MainActor
private final class SystemHeartRateActivityClient: HeartRateActivityClient {
    private var activity: Activity<HeartRateActivityAttributes>?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activityState: ActivityState? { activity?.activityState }

    func endAllActivities() async {
        // Include our handle even if a dismissed activity has left the system list.
        var existing = Activity<HeartRateActivityAttributes>.activities
        if let activity, !existing.contains(where: { $0.id == activity.id }) {
            existing.append(activity)
        }
        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    func update(_ content: ActivityContent<HeartRateActivityAttributes.ContentState>) async {
        await activity?.update(content)
    }

    func start(_ content: ActivityContent<HeartRateActivityAttributes.ContentState>) throws {
        activity = try Activity.request(
            attributes: HeartRateActivityAttributes(title: "Current BPM"),
            content: content,
            pushType: nil
        )
    }
}

@available(iOS 16.1, iOSApplicationExtension 16.1, *)
@MainActor
final class HeartRateActivityController {
    static let shared = HeartRateActivityController(client: SystemHeartRateActivityClient())

    private typealias State = HeartRateActivityAttributes.ContentState
    private enum Source: Hashable { case localHeartRate, localWorkout, viewing }
    private let client: any HeartRateActivityClient
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.bpmapp.client", category: "HeartRateActivity")
    private var localState = State(bpm: nil, average: nil, maximum: nil, minimum: nil)
    private var viewingState: State?
    private var localHeartRateExpiresAt: Date?
    private var viewingHeartRateExpiresAt: Date?
    private var viewingTimerExpiresAt: Date?
    private var isSharing = false
    private var elapsedSeconds: Int?
    private var timerReferenceDate: Date?
    private var timerEndDate: Date?
    private var activeSource: Source?
    private var dismissedSources: Set<Source> = []
    private var needsCleanup = true
    private var revision = 0
    private var reconciliation: Task<Void, Never>?
    private var expiryTimer: Timer?

    init(client: any HeartRateActivityClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
        refreshActivity()
    }

    func updateActivity(bpm: Int?, average: Int?, maximum: Int?, minimum: Int?, zone: ZoneInfo? = nil,
                        isSharing: Bool = false, isViewing: Bool = false, hasError: Bool = false,
                        elapsedSeconds: Int? = nil, timerReferenceDate: Date? = nil, timerEndDate: Date? = nil,
                        heartRateExpiresAt: Date? = nil, timerExpiresAt: Date? = nil) {
        let validBpm = bpm.flatMap { $0 > 0 ? $0 : nil }
        let state = State(bpm: validBpm, average: average, maximum: maximum, minimum: minimum,
                          elapsedSeconds: elapsedSeconds, timerReferenceDate: timerReferenceDate,
                          timerEndDate: timerEndDate, zone: zone, isSharing: isSharing,
                          isViewing: isViewing, hasError: hasError)
        let expiry = validBpm == nil ? nil : heartRateExpiresAt ?? now().addingTimeInterval(3)
        if isViewing {
            viewingState = state
            viewingHeartRateExpiresAt = expiry
            viewingTimerExpiresAt = timerExpiresAt
        } else {
            localState = state
            if validBpm == nil {
                dismissedSources.remove(.localHeartRate)
                if activeSource == .localHeartRate { activeSource = nil }
            }
            localHeartRateExpiresAt = expiry
            self.isSharing = isSharing
        }
        refreshActivity()
    }

    /// Broadcasting alone never keeps a Live Activity alive.
    func updateSharingState(isSharing: Bool) {
        self.isSharing = isSharing
        refreshActivity()
    }

    /// isRunning includes a paused, resumable workout, as supplied by TimerViewModel.
    func updateTimer(elapsedSeconds: Int?, isRunning: Bool, referenceDate: Date? = nil, endDate: Date? = nil) {
        if !isRunning {
            dismissedSources.remove(.localWorkout)
            if activeSource == .localWorkout { activeSource = nil }
        }
        self.elapsedSeconds = isRunning ? elapsedSeconds : nil
        timerReferenceDate = isRunning ? referenceDate : nil
        timerEndDate = isRunning ? endDate : nil
        refreshActivity()
    }

    func endLocalHeartRate() {
        localState = State(bpm: nil, average: nil, maximum: nil, minimum: nil)
        localHeartRateExpiresAt = nil
        dismissedSources.remove(.localHeartRate)
        if activeSource == .localHeartRate { activeSource = nil }
        refreshActivity()
    }

    func endViewing() {
        viewingState = nil
        viewingHeartRateExpiresAt = nil
        viewingTimerExpiresAt = nil
        dismissedSources.remove(.viewing)
        if activeSource == .viewing { activeSource = nil }
        refreshActivity()
    }

    func endActivity() async {
        localState = State(bpm: nil, average: nil, maximum: nil, minimum: nil)
        viewingState = nil
        localHeartRateExpiresAt = nil
        viewingHeartRateExpiresAt = nil
        viewingTimerExpiresAt = nil
        elapsedSeconds = nil
        timerReferenceDate = nil
        timerEndDate = nil
        isSharing = false
        dismissedSources.removeAll()
        needsCleanup = true
        refreshActivity()
        await waitForPendingUpdates()
    }

    func refreshActivity() {
        revision += 1
        scheduleExpiry()
        guard reconciliation == nil else { return }
        reconciliation = Task { @MainActor [weak self] in
            await self?.reconcile()
        }
    }

    func waitForPendingUpdates() async {
        await reconciliation?.value
    }

    private func desiredActivity() -> (source: Source, content: ActivityContent<State>)? {
        let date = now()
        let viewing = elapsedSeconds == nil ? viewingState : nil
        let base = viewing ?? localState
        let heartRateExpiry = viewing == nil ? localHeartRateExpiresAt : viewingHeartRateExpiresAt
        let bpm = heartRateExpiry.map { $0 > date } == true ? base.bpm : nil
        let sharedTimerIsFresh = viewingTimerExpiresAt.map { $0 > date } ?? true
        let elapsed = viewing == nil ? elapsedSeconds : (sharedTimerIsFresh ? base.elapsedSeconds : nil)
        guard HeartRateActivityLifecycle.shouldShowActivity(bpm: bpm, hasActiveTimer: elapsed != nil) else {
            return nil
        }
        let source: Source = viewing != nil ? .viewing : (elapsed != nil ? .localWorkout : .localHeartRate)
        let state = State(bpm: bpm, average: bpm == nil ? nil : base.average,
                          maximum: bpm == nil ? nil : base.maximum, minimum: bpm == nil ? nil : base.minimum,
                          elapsedSeconds: elapsed,
                          timerReferenceDate: viewing == nil ? timerReferenceDate : base.timerReferenceDate,
                          timerEndDate: viewing == nil ? timerEndDate : base.timerEndDate,
                          zone: bpm == nil ? nil : base.zone, isSharing: viewing == nil && isSharing,
                          isViewing: viewing != nil, hasError: elapsed == nil && base.hasError)
        // An active timer remains useful without heart rate. A stale reading must
        // never turn its timer-only view into an error or disconnected placeholder.
        let staleDate = bpm != nil ? heartRateExpiry : (viewing != nil ? viewingTimerExpiresAt : nil)
        return (source, ActivityContent(state: state, staleDate: staleDate))
    }

    private func reconcile() async {
        while true {
            if needsCleanup {
                needsCleanup = false
                await client.endAllActivities()
                activeSource = nil
                // Read the latest sources after awaiting launch/termination cleanup.
                continue
            }
            let appliedRevision = revision
            let desired = desiredActivity()

            if client.activityState == .dismissed || client.activityState == .ended {
                // Honor the system/Lock Screen dismissal until that session ends.
                if let activeSource { dismissedSources.insert(activeSource) }
                activeSource = nil
                await client.endAllActivities()
                continue
            }
            if let desired, client.areActivitiesEnabled, !dismissedSources.contains(desired.source) {
                if client.activityState != nil {
                    activeSource = desired.source
                    await client.update(desired.content)
                } else {
                    do {
                        try client.start(desired.content)
                        activeSource = desired.source
                    } catch {
                        logger.error("Failed to start heart rate activity: \(error.localizedDescription)")
                    }
                }
            } else if client.activityState != nil {
                await client.endAllActivities()
                activeSource = nil
            }

            if revision == appliedRevision {
                reconciliation = nil
                return
            }
        }
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let date = now()
        let deadlines = [localHeartRateExpiresAt, viewingHeartRateExpiresAt, viewingTimerExpiresAt]
        guard let next = deadlines.compactMap({ $0 }).filter({ $0 > date }).min() else { return }
        let timer = Timer(timeInterval: next.timeIntervalSince(date), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshActivity() }
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif
