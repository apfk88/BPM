import Foundation
import Testing
@testable import BPM

struct ICloudPreferencesSyncTests {
    @Test @MainActor func healthAutofillValuesAreNeverUploadedToPreferencesCloud() {
        let suite = "health-local-only-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CaloriesDefaultsKey.weightKg
        let cloud = InMemoryICloudKeyValueStore()
        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: cloud)
        sync.start()
        let snapshot = CalorieHealthAutofillSnapshot(entries: [
            CalorieHealthAutofillEntry(field: .weight, value: "74", sampleDate: Date())
        ])

        #expect(snapshot.fillMissingValues(in: defaults) == [.weight])
        sync.syncLocalChanges()
        sync.syncNow()

        #expect(defaults.string(forKey: key) == "74")
        #expect(cloud.object(forKey: ICloudPreferencesSync.cloudValueKey(for: key)) == nil)
        #expect(cloud.object(forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key)) == nil)
    }

    @Test func remotePreferencesCannotReplaceHealthImportedValues() {
        let suite = "health-local-only-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = CaloriesDefaultsKey.weightKg
        defaults.set(true, forKey: HealthKitImportedPreferences.localOnlyKey(for: key))
        defaults.set("74", forKey: key)
        let cloud = InMemoryICloudKeyValueStore()
        cloud.set("90", forKey: ICloudPreferencesSync.cloudValueKey(for: key))
        cloud.set(Date().timeIntervalSince1970 + 60, forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key))
        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: cloud)

        sync.syncNow()
        defaults.set("75", forKey: key)
        sync.syncLocalChanges()

        #expect(defaults.string(forKey: key) == "75")
        #expect(cloud.string(forKey: ICloudPreferencesSync.cloudValueKey(for: key)) == "90")
    }

    @Test func firstLaunchWithoutLocalOrRemoteDoesNotPublishDeletion() {
        let key = "BPM_Test_Prefs_\(UUID().uuidString)"
        let defaults = makeDefaults()
        let iCloudStore = InMemoryICloudKeyValueStore()
        resetCloudValue(key, store: iCloudStore)

        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: iCloudStore)
        sync.syncNow()

        #expect(iCloudStore.object(forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key)) == nil)
        #expect(iCloudStore.object(forKey: ICloudPreferencesSync.cloudValueKey(for: key)) == nil)
    }

    @Test func remoteValueHydratesEmptyDefaults() {
        let key = "BPM_Test_Prefs_\(UUID().uuidString)"
        let defaults = makeDefaults()
        let iCloudStore = InMemoryICloudKeyValueStore()
        resetCloudValue(key, store: iCloudStore)

        iCloudStore.set("remote", forKey: ICloudPreferencesSync.cloudValueKey(for: key))
        iCloudStore.set(Date().timeIntervalSince1970, forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key))
        iCloudStore.set(false, forKey: ICloudPreferencesSync.cloudDeletedKey(for: key))
        iCloudStore.synchronize()

        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: iCloudStore)
        sync.syncNow()

        #expect(defaults.string(forKey: key) == "remote")
    }

    @Test func localValueSeedsRemoteWhenRemoteIsMissing() {
        let key = "BPM_Test_Prefs_\(UUID().uuidString)"
        let defaults = makeDefaults()
        let iCloudStore = InMemoryICloudKeyValueStore()
        resetCloudValue(key, store: iCloudStore)
        defaults.set("local", forKey: key)

        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: iCloudStore)
        sync.syncNow()

        #expect(iCloudStore.string(forKey: ICloudPreferencesSync.cloudValueKey(for: key)) == "local")
        #expect(iCloudStore.bool(forKey: ICloudPreferencesSync.cloudDeletedKey(for: key)) == false)
    }

    @Test func localDeletionWritesRemoteTombstoneAfterInitialSnapshot() {
        let key = "BPM_Test_Prefs_\(UUID().uuidString)"
        let defaults = makeDefaults()
        let iCloudStore = InMemoryICloudKeyValueStore()
        resetCloudValue(key, store: iCloudStore)
        defaults.set("local", forKey: key)

        let sync = ICloudPreferencesSync(keys: [key], userDefaults: defaults, iCloudStore: iCloudStore)
        sync.syncNow()
        defaults.removeObject(forKey: key)
        sync.syncLocalChanges()

        #expect(iCloudStore.object(forKey: ICloudPreferencesSync.cloudValueKey(for: key)) == nil)
        #expect(iCloudStore.bool(forKey: ICloudPreferencesSync.cloudDeletedKey(for: key)))
        #expect(iCloudStore.object(forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key)) != nil)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "icloud-preferences-\(UUID().uuidString)")!
    }

    private func resetCloudValue(_ key: String, store: ICloudKeyValueStore) {
        store.removeObject(forKey: ICloudPreferencesSync.cloudValueKey(for: key))
        store.removeObject(forKey: ICloudPreferencesSync.cloudUpdatedAtKey(for: key))
        store.removeObject(forKey: ICloudPreferencesSync.cloudDeletedKey(for: key))
        store.synchronize()
    }
}
