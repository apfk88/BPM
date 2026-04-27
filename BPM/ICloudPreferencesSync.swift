import Foundation

enum ICloudSyncedPreferences {
    static let keys: [String] = [
        HeartRateZoneDefaultsKey.config,
        HeartRateAlertDefaultsKey.heartRateEnabled,
        HeartRateAlertDefaultsKey.heartRateThreshold,
        HeartRateAlertDefaultsKey.zoneEnabled,
        HeartRateAlertDefaultsKey.zoneSelections,
        HealthKitWorkoutTypeDefaultsKey.quickSelection,
        CaloriesDefaultsKey.weightKg,
        CaloriesDefaultsKey.ageYears,
        CaloriesDefaultsKey.sexAtBirth,
        CaloriesDefaultsKey.heightCm,
        CaloriesDefaultsKey.restHrBpm,
        CaloriesDefaultsKey.maxHrBpm,
        CaloriesDefaultsKey.vo2Max,
        CaloriesDefaultsKey.rmrKcalPerDay,
        CaloriesDefaultsKey.bodyFatPercent,
        WorkoutDefaultsKey.retentionDays,
        HRVDefaultsKey.retentionDays,
        TimerPresetDefaultsKey.presets,
        TimerPresetDefaultsKey.seeded,
        ViewDefaultsKey.timerMode
    ]
}

final class ICloudPreferencesSync {
    static let shared = ICloudPreferencesSync()

    private static let cloudValuePrefix = "BPM_ICloudPrefs_Value_"
    private static let cloudUpdatedAtPrefix = "BPM_ICloudPrefs_UpdatedAt_"
    private static let cloudDeletedPrefix = "BPM_ICloudPrefs_Deleted_"
    private static let localUpdatedAtPrefix = "BPM_ICloudPrefs_LocalUpdatedAt_"
    private static let localDeletedPrefix = "BPM_ICloudPrefs_LocalDeleted_"

    private let keys: [String]
    private let userDefaults: UserDefaults
    private let iCloudStore: NSUbiquitousKeyValueStore
    private var snapshots: [String: SyncedPreferenceValue?] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var iCloudObserver: NSObjectProtocol?
    private var isApplyingRemote = false
    private var isWritingLocalMetadata = false
    private var isStarted = false

    init(
        keys: [String] = ICloudSyncedPreferences.keys,
        userDefaults: UserDefaults = .standard,
        iCloudStore: NSUbiquitousKeyValueStore = .default
    ) {
        self.keys = keys
        self.userDefaults = userDefaults
        self.iCloudStore = iCloudStore
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let iCloudObserver {
            NotificationCenter.default.removeObserver(iCloudObserver)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        syncNow()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncLocalChanges()
        }
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] _ in
            self?.syncNow()
        }
    }

    func syncNow() {
        iCloudStore.synchronize()
        for key in keys {
            syncKey(key)
        }
        captureSnapshots()
    }

    func syncLocalChanges() {
        guard !isApplyingRemote, !isWritingLocalMetadata else { return }
        for key in keys {
            let current = SyncedPreferenceValue(object: userDefaults.object(forKey: key))
            let previous = snapshots[key] ?? nil
            guard current != previous else { continue }

            let timestamp = Date()
            snapshots[key] = current
            if let current {
                pushValue(current, forKey: key, at: timestamp)
            } else if previous != nil {
                pushDeletion(forKey: key, at: timestamp)
            }
        }
    }

    private func syncKey(_ key: String) {
        let localValue = SyncedPreferenceValue(object: userDefaults.object(forKey: key))
        let localUpdatedAt = userDefaults.object(forKey: Self.localUpdatedAtKey(for: key)) as? TimeInterval
        let remoteUpdatedAt = iCloudStore.object(forKey: Self.cloudUpdatedAtKey(for: key)) as? TimeInterval

        if let remoteUpdatedAt {
            if remoteUpdatedAt > (localUpdatedAt ?? .leastNonzeroMagnitude) {
                applyRemoteValue(forKey: key, updatedAt: remoteUpdatedAt)
            } else if let localValue, let localUpdatedAt, localUpdatedAt > remoteUpdatedAt {
                pushValue(localValue, forKey: key, at: Date(timeIntervalSince1970: localUpdatedAt))
            } else if localValue == nil,
                      userDefaults.bool(forKey: Self.localDeletedKey(for: key)),
                      let localUpdatedAt,
                      localUpdatedAt > remoteUpdatedAt {
                pushDeletion(forKey: key, at: Date(timeIntervalSince1970: localUpdatedAt))
            }
        } else if let localValue {
            pushValue(localValue, forKey: key, at: Date())
        }
    }

    private func applyRemoteValue(forKey key: String, updatedAt: TimeInterval) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        let isDeleted = iCloudStore.bool(forKey: Self.cloudDeletedKey(for: key))
        if isDeleted {
            userDefaults.removeObject(forKey: key)
            userDefaults.set(true, forKey: Self.localDeletedKey(for: key))
        } else if let remoteObject = iCloudStore.object(forKey: Self.cloudValueKey(for: key)) {
            userDefaults.set(remoteObject, forKey: key)
            userDefaults.set(false, forKey: Self.localDeletedKey(for: key))
        } else {
            return
        }

        userDefaults.set(updatedAt, forKey: Self.localUpdatedAtKey(for: key))
    }

    private func pushValue(_ value: SyncedPreferenceValue, forKey key: String, at date: Date) {
        iCloudStore.set(value.objectValue, forKey: Self.cloudValueKey(for: key))
        markSynced(key: key, date: date, isDeleted: false)
    }

    private func pushDeletion(forKey key: String, at date: Date) {
        iCloudStore.removeObject(forKey: Self.cloudValueKey(for: key))
        markSynced(key: key, date: date, isDeleted: true)
    }

    private func markSynced(key: String, date: Date, isDeleted: Bool) {
        let timestamp = date.timeIntervalSince1970
        iCloudStore.set(timestamp, forKey: Self.cloudUpdatedAtKey(for: key))
        iCloudStore.set(isDeleted, forKey: Self.cloudDeletedKey(for: key))
        iCloudStore.synchronize()
        isWritingLocalMetadata = true
        userDefaults.set(timestamp, forKey: Self.localUpdatedAtKey(for: key))
        userDefaults.set(isDeleted, forKey: Self.localDeletedKey(for: key))
        isWritingLocalMetadata = false
    }

    private func captureSnapshots() {
        for key in keys {
            snapshots[key] = SyncedPreferenceValue(object: userDefaults.object(forKey: key))
        }
    }

    static func cloudValueKey(for key: String) -> String {
        cloudValuePrefix + key
    }

    static func cloudUpdatedAtKey(for key: String) -> String {
        cloudUpdatedAtPrefix + key
    }

    static func cloudDeletedKey(for key: String) -> String {
        cloudDeletedPrefix + key
    }

    static func localUpdatedAtKey(for key: String) -> String {
        localUpdatedAtPrefix + key
    }

    static func localDeletedKey(for key: String) -> String {
        localDeletedPrefix + key
    }
}

enum SyncedPreferenceValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
    case data(Data)

    init?(object: Any?) {
        switch object {
        case let value as String:
            self = .string(value)
        case let value as Int:
            self = .int(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Double:
            self = .double(value)
        case let value as Data:
            self = .data(value)
        case let value as NSNumber:
            let type = String(cString: value.objCType)
            if type == "c" || type == "B" {
                self = .bool(value.boolValue)
            } else if floor(value.doubleValue) == value.doubleValue {
                self = .int(value.intValue)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as NSData:
            self = .data(value as Data)
        default:
            return nil
        }
    }

    var objectValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .bool(value):
            return value
        case let .double(value):
            return value
        case let .data(value):
            return value
        }
    }
}
