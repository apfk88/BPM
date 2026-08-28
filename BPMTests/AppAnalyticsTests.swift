import XCTest
@testable import BPM

final class AppAnalyticsTests: XCTestCase {
    func testTelemetryDeckConfigurationValues() {
        let configuration = AppAnalytics.configuration

        XCTAssertEqual(configuration.telemetryAppID, "458D3F06-26F3-4929-ADFA-C1B7DF052D28")
        XCTAssertEqual(configuration.namespace, "com.siav")
    }
}
