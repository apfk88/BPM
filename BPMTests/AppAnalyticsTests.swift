import XCTest
@testable import BPM

final class AppAnalyticsTests: XCTestCase {
    func testTelemetryDeckConfigurationValues() {
        let configuration = AppAnalytics.configuration

        XCTAssertEqual(configuration.telemetryAppID, "458D3F06-26F3-4929-ADFA-C1B7DF052D28")
        XCTAssertEqual(configuration.namespace, "com.siav")
    }

    func testEventNames() {
        XCTAssertEqual(
            Set(AppAnalytics.Event.allCases.map(\.rawValue)),
            [
                "connect_device",
                "connect_friends_code",
                "share_on",
                "share_off",
                "workout_start",
                "workout_save",
                "hrv_start"
            ]
        )
    }
}
