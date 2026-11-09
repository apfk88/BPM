import Foundation
import Combine

/// Collects a sustained local workout high without interrupting the workout.
@MainActor
final class MaxHeartRateSuggestionStore: ObservableObject {
    static let shared = MaxHeartRateSuggestionStore()

    enum DefaultsKey {
        static let pending = "BPM_MaxHR_PendingSuggestion"
        static let dismissed = "BPM_MaxHR_DismissedSuggestion"
    }

    @Published private(set) var pendingMaxHeartRate: Int?

    private let defaults: UserDefaults
    private let zoneStorage: HeartRateZoneStorage
    private var defaultsObserver: NSObjectProtocol?
    private var confirmationSamples: [HeartRateSample] = []
    private var confirmationThreshold: Int?
    private let minimumConfirmationDuration: TimeInterval = 4
    private let maximumSampleGap: TimeInterval = 3

    /// Uses only explicitly configured maxima. Setup reminders handle a missing profile.
    var configuredMaxHeartRate: Int? {
        [calorieMaxHeartRate, zoneStorage.config?.maxHeartRate]
            .compactMap { $0 }
            .filter { (30...250).contains($0) }
            .max()
    }

    init(defaults: UserDefaults = .standard, zoneStorage: HeartRateZoneStorage = .shared) {
        self.defaults = defaults
        self.zoneStorage = zoneStorage
        let saved = defaults.integer(forKey: DefaultsKey.pending)
        pendingMaxHeartRate = (30...250).contains(saved) ? saved : nil
        reconcileWithSettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileWithSettings()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Call from the live local HRM stream, including when its workout is off-screen.
    /// Simulated readings, paused workouts, contact loss and isolated spikes never qualify.
    func record(_ sample: HeartRateSample, isLocalWorkoutActive: Bool, isSimulated: Bool) {
        reconcileWithSettings()
        guard isLocalWorkoutActive, !isSimulated,
              sample.sensorContactStatus != .notDetected,
              sample.invalidatedAt == nil,
              sample.timestamp.timeIntervalSinceReferenceDate.isFinite,
              (30...250).contains(sample.value),
              let configuredMaxHeartRate else {
            resetConfirmation()
            return
        }

        let threshold = max(configuredMaxHeartRate, defaults.integer(forKey: DefaultsKey.dismissed))
        guard sample.value > threshold else {
            resetConfirmation()
            return
        }
        if confirmationThreshold != threshold {
            resetConfirmation()
            confirmationThreshold = threshold
        }
        if let previous = confirmationSamples.last {
            let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { return }
            if gap > maximumSampleGap { confirmationSamples.removeAll() }
        }
        confirmationSamples.append(sample)
        // Keep the boundary sample needed to prove four continuous seconds.
        while confirmationSamples.count > 1,
              sample.timestamp.timeIntervalSince(confirmationSamples[1].timestamp) >= minimumConfirmationDuration {
            confirmationSamples.removeFirst()
        }
        guard confirmationSamples.count >= 3,
              let first = confirmationSamples.first,
              sample.timestamp.timeIntervalSince(first.timestamp) >= minimumConfirmationDuration,
              let sustainedMax = confirmationSamples.map(\.value).min(),
              sustainedMax > (pendingMaxHeartRate ?? 0) else { return }
        setPending(sustainedMax)
    }

    func resetConfirmation() {
        confirmationSamples.removeAll()
        confirmationThreshold = nil
    }

    /// Called after an explicit Yes in Settings. Custom zone boundaries stay exactly as entered.
    func accept() {
        reconcileWithSettings()
        guard let value = pendingMaxHeartRate else { return }
        // An already higher manual value must never be lowered by an older suggestion.
        if value > (calorieMaxHeartRate ?? 0) {
            // A sensor-derived value remains on this device, including in synced preference blobs.
            defaults.set(true, forKey: HealthKitImportedPreferences.localOnlyKey(for: CaloriesDefaultsKey.maxHrBpm))
            defaults.set(String(value), forKey: CaloriesDefaultsKey.maxHrBpm)
        }
        var config = zoneStorage.effectiveConfig
        if zoneStorage.config == nil || value > config.maxHeartRate {
            defaults.set(true, forKey: HealthKitImportedPreferences.localOnlyKey(for: HeartRateZoneDefaultsKey.config))
            config.maxHeartRate = value
            zoneStorage.config = config
        }
        setPending(nil)
        resetConfirmation()
    }

    /// No means do not ask again for this reading, including after another launch.
    func dismiss() {
        guard let value = pendingMaxHeartRate else { return }
        defaults.set(max(value, defaults.integer(forKey: DefaultsKey.dismissed)), forKey: DefaultsKey.dismissed)
        setPending(nil)
        resetConfirmation()
    }

    func reconcileWithSettings() {
        guard let pendingMaxHeartRate else { return }
        guard let configuredMaxHeartRate,
              pendingMaxHeartRate > configuredMaxHeartRate,
              pendingMaxHeartRate > defaults.integer(forKey: DefaultsKey.dismissed) else {
            setPending(nil)
            resetConfirmation()
            return
        }
    }

    private var calorieMaxHeartRate: Int? {
        guard let value = defaults.string(forKey: CaloriesDefaultsKey.maxHrBpm).flatMap(Int.init),
              (30...250).contains(value) else { return nil }
        return value
    }

    private func setPending(_ value: Int?) {
        guard pendingMaxHeartRate != value else { return }
        pendingMaxHeartRate = value
        if let value {
            defaults.set(value, forKey: DefaultsKey.pending)
        } else {
            defaults.removeObject(forKey: DefaultsKey.pending)
        }
    }
}
