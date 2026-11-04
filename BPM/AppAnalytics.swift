import TelemetryDeck
import SwiftUI
import os

enum AppAnalytics {
    enum Event: String, CaseIterable {
        case connectDevice = "connect_device"
        case connectFriendsCode = "connect_friends_code"
        case shareOn = "share_on"
        case shareOff = "share_off"
        case workoutStart = "workout_start"
        case workoutSave = "workout_save"
        case hrvStart = "hrv_start"
        case sharePickerOpened = "share_picker_opened"
        case shareFormatSelected = "share_format_selected"
        case shareExportRequested = "share_export_requested"
        case shareExportPresented = "share_export_presented"
        case shareExportCompleted = "share_export_completed"
        case shareExportCancelled = "share_export_cancelled"
        case shareExportFailed = "share_export_failed"
        case screenViewed = "screen_viewed"
        case featureConfiguration = "feature_configuration"
        case settingChanged = "setting_changed"
        case soundUsed = "sound_used"
        case calorieConfiguration = "calorie_configuration"
        case calorieFieldEdited = "calorie_field_edited"
        case streamStartRequested = "stream_start_requested"
        case streamStartFailed = "stream_start_failed"
        case streamViewerStarted = "stream_viewer_started"
        case streamViewerConnected = "stream_viewer_connected"
        case streamViewerStopped = "stream_viewer_stopped"
        case streamViewerFailed = "stream_viewer_failed"
        case streamBroadcastConnected = "stream_broadcast_connected"
        case hrvCompleted = "hrv_completed"
        case hrvFailed = "hrv_failed"
        case hrvCancelled = "hrv_cancelled"
        case hrvSave = "hrv_save"
        case workoutViewSelected = "workout_view_selected"
        case presetSelected = "preset_selected"
        case presetSaved = "preset_saved"
        case voiceRecordingStarted = "voice_recording_started"
        case voiceRecapRequested = "voice_recap_requested"
        case voiceRecapCompleted = "voice_recap_completed"
        case voiceRecapFailed = "voice_recap_failed"
        case voiceRecapCancelled = "voice_recap_cancelled"
        case healthAccessRequested = "health_access_requested"
    }

    enum Screen: String {
        case home, workout, settings, presets
        case workoutHistory = "workout_history"
        case workoutDetail = "workout_detail"
        case workoutEdit = "workout_edit"
        case workoutSave = "workout_save"
        case workoutChart = "workout_chart"
        case hrv, hrvHistory = "hrv_history", hrvDetail = "hrv_detail"
        case calories = "calorie_settings", calorieAccuracy = "calorie_accuracy"
        case zones = "zone_settings", zoneAlerts = "zone_alerts"
        case workoutTypes = "workout_types", devices
    }

    enum Sound: String { case bpmAlert = "bpm_alert", zoneAlert = "zone_alert", presetBell = "preset_bell", hrvCompletion = "hrv_completion" }
    enum Setting: String { case bpmAlert = "bpm_alert", zoneAlert = "zone_alert" }

    static let appID = "458D3F06-26F3-4929-ADFA-C1B7DF052D28"
    static let namespace = "com.siav"
    #if DEBUG
    private static let uploadsEnabled = ProcessInfo.processInfo.arguments.contains("-BPMEnableAnalytics")
    #else
    private static let uploadsEnabled = true
    #endif
    private static let soundUsage = AnalyticsOncePerSession<Sound>(resetsDaily: true)
    private static var lastConfiguration: [String: String]?
    private static var lastConfigurationDay: Int?

    static var configuration: TelemetryDeck.Config {
        let config = TelemetryDeck.Config(
            appID: appID,
            namespace: namespace
        )
        #if DEBUG
        // Opt in per launch when verifying ingestion; local event logging stays on.
        config.analyticsDisabled = !uploadsEnabled
        config.testMode = true
        #endif
        return config
    }

    static func configure() {
        // Avoid starting the SDK's upload timer for events cached by earlier runs.
        guard uploadsEnabled else { return }
        TelemetryDeck.initialize(config: configuration)
    }

    static func signal(_ event: Event, parameters: [String: String] = [:]) {
        #if DEBUG
        Logger(subsystem: "kvamme.BPM", category: "Analytics").debug("\(event.rawValue, privacy: .public) \(parameters.description, privacy: .public)")
        #endif
        guard uploadsEnabled else { return }
        TelemetryDeck.signal(event.rawValue, parameters: parameters)
    }

    static func screen(_ screen: Screen) {
        signal(.screenViewed, parameters: ["screen": screen.rawValue])
    }

    @MainActor static func setting(_ setting: Setting, enabled: Bool) {
        signal(.settingChanged, parameters: ["setting": setting.rawValue, "enabled": String(enabled)])
        recordConfiguration()
    }

    /// Once per sound category per process/day, never a stream of beat/zone transitions.
    static func soundUsed(_ sound: Sound) {
        guard soundUsage.insert(sound) else { return }
        signal(.soundUsed, parameters: ["sound": sound.rawValue])
    }

    /// Adoption snapshot includes existing users who never reopen Settings.
    /// Run on the main thread; repeated foreground transitions with no changes are silent.
    @MainActor static func recordConfiguration(defaults: UserDefaults = .standard) {
        var parameters = CalorieAnalytics.configuration(defaults: defaults)
        parameters["bpm_alert_enabled"] = String(defaults.bool(forKey: HeartRateAlertDefaultsKey.heartRateEnabled))
        parameters["zone_alert_enabled"] = String(defaults.bool(forKey: HeartRateAlertDefaultsKey.zoneEnabled))
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        guard lastConfiguration != parameters || lastConfigurationDay != day else { return }
        lastConfiguration = parameters
        lastConfigurationDay = day
        signal(.featureConfiguration, parameters: parameters)
    }
}

/// A viewing attempt can fail and then recover. Each outcome is counted at most once.
final class StreamViewingAnalytics {
    typealias Emit = (AppAnalytics.Event, [String: String]) -> Void
    private let emit: Emit
    private var connected = false
    private var reportedFailure = false
    private var stopped = false

    init(restored: Bool, emit: @escaping Emit = AppAnalytics.signal) {
        self.emit = emit
        emit(.streamViewerStarted, ["source": restored ? "restored" : "user"])
    }

    func receivedData() {
        guard !stopped, !connected else { return }
        connected = true
        emit(.streamViewerConnected, [:])
    }

    func failed() {
        guard !stopped, !reportedFailure else { return }
        reportedFailure = true
        emit(.streamViewerFailed, ["stage": connected ? "streaming" : "connecting"])
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        emit(.streamViewerStopped, ["connected": String(connected)])
    }
}

/// Shared by sound and streaming instrumentation to avoid counting repeated callbacks.
final class AnalyticsOncePerSession<Key: Hashable> {
    private let lock = NSLock()
    private var seen: Set<Key> = []
    private let resetsDaily: Bool
    private var day: Int?

    init(resetsDaily: Bool = false) { self.resetsDaily = resetsDaily }

    func insert(_ key: Key, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let currentDay = Int(now.timeIntervalSince1970 / 86_400)
        if resetsDaily, day != currentDay {
            seen.removeAll()
            day = currentDay
        }
        return seen.insert(key).inserted
    }
}

enum CalorieAnalytics {
    enum Field: String, CaseIterable {
        case weight, age, sex, height
        case restingHR = "resting_hr", maxHR = "max_hr", vo2Max = "vo2_max", rmr, bodyFat = "body_fat"

        var defaultsKey: String {
            switch self {
            case .weight: CaloriesDefaultsKey.weightKg
            case .age: CaloriesDefaultsKey.ageYears
            case .sex: CaloriesDefaultsKey.sexAtBirth
            case .height: CaloriesDefaultsKey.heightCm
            case .restingHR: CaloriesDefaultsKey.restHrBpm
            case .maxHR: CaloriesDefaultsKey.maxHrBpm
            case .vo2Max: CaloriesDefaultsKey.vo2Max
            case .rmr: CaloriesDefaultsKey.rmrKcalPerDay
            case .bodyFat: CaloriesDefaultsKey.bodyFatPercent
            }
        }
    }

    enum FieldState: String { case empty, filled, invalid, defaulted }

    static func state(for field: Field, defaults: UserDefaults) -> FieldState {
        let value = defaults.string(forKey: field.defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if field == .sex {
            // Sex must be explicitly selected before using the sex-specific formula.
            return value.isEmpty ? .empty : (SexAtBirth(rawValue: value) == nil ? .invalid : .filled)
        }
        guard !value.isEmpty else { return .empty }
        guard let number = Double(value), number.isFinite, number > 0 else { return .invalid }
        if [.age, .restingHR, .maxHR].contains(field), Int(value) == nil { return .invalid }
        return .filled
    }

    static func configuration(defaults: UserDefaults = .standard) -> [String: String] {
        var parameters = Dictionary(uniqueKeysWithValues: Field.allCases.map {
            ("\($0.rawValue)_state", state(for: $0, defaults: defaults).rawValue)
        })
        // Use the estimator's actual validation, including invalid optional inputs.
        // Only the resulting boolean is emitted, never profile values or medication state.
        parameters["calories_enabled"] = String(UserEnergyProfileStore.currentProfile(defaults: defaults).hasRequiredInputs)
        return parameters
    }

    static func edited(_ field: Field, defaults: UserDefaults = .standard) {
        AppAnalytics.signal(.calorieFieldEdited, parameters: [
            "field": field.rawValue, "state": state(for: field, defaults: defaults).rawValue
        ])
    }
}

private struct AnalyticsScreenModifier: ViewModifier {
    let screen: AppAnalytics.Screen
    @State private var didAppear = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !didAppear else { return }
            didAppear = true
            AppAnalytics.screen(screen)
        }
    }
}

extension View {
    /// One event per view presentation, unaffected by body redraws or child sheets.
    func analyticsScreen(_ screen: AppAnalytics.Screen) -> some View {
        modifier(AnalyticsScreenModifier(screen: screen))
    }
}

/// Only fixed labels enter analytics. Never pass share content, health values, IDs or errors.
struct ShareAnalyticsContext {
    enum Source: String, CaseIterable {
        case postSave = "post_save"
        case workoutDetail = "workout_detail"
        case workoutHistory = "workout_history"
        case hrvDetail = "hrv_detail"
        case hrvHistory = "hrv_history"
    }

    enum Format: String, CaseIterable {
        case chartCard = "chart_card"
        case statsCard = "stats_card"
        case plainText = "plain_text"
        case logs
    }

    let source: Source
    let format: Format

    var parameters: [String: String] {
        ["source": source.rawValue, "format": format.rawValue]
    }

    func signal(_ event: AppAnalytics.Event) {
        AppAnalytics.signal(event, parameters: parameters)
    }
}

/// One export attempt, including preparation failures and native sheet dismissal.
/// Completion means UIKit reported success, not confirmed delivery to a recipient.
final class ShareAnalyticsSession {
    typealias Emit = (AppAnalytics.Event, [String: String]) -> Void
    private let context: ShareAnalyticsContext
    private let emit: Emit
    private var didPresent = false
    private var didFinish = false

    init(context: ShareAnalyticsContext, emit: @escaping Emit = AppAnalytics.signal) {
        self.context = context
        self.emit = emit
        emit(.shareExportRequested, context.parameters)
    }

    func presented() {
        guard !didPresent, !didFinish else { return }
        didPresent = true
        emit(.shareExportPresented, context.parameters)
    }

    func finish(completed: Bool, failed: Bool = false) {
        guard !didFinish else { return }
        didFinish = true
        let event: AppAnalytics.Event = failed ? .shareExportFailed
            : completed ? .shareExportCompleted : .shareExportCancelled
        emit(event, context.parameters)
    }
}
