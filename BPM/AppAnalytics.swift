import TelemetryDeck

enum AppAnalytics {
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
}
