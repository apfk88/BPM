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

    static func signal(_ event: Event) {
        TelemetryDeck.signal(event.rawValue)
    }
}
