import TelemetryDeck

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
    }

    static let appID = "458D3F06-26F3-4929-ADFA-C1B7DF052D28"
    static let namespace = "com.siav"

    static var configuration: TelemetryDeck.Config {
        .init(
            appID: appID,
            namespace: namespace
        )
    }

    static func configure() {
        TelemetryDeck.initialize(config: configuration)
    }

    static func signal(_ event: Event, parameters: [String: String] = [:]) {
        TelemetryDeck.signal(event.rawValue, parameters: parameters)
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
