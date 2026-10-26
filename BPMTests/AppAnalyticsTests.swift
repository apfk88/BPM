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
                "hrv_start",
                "share_picker_opened",
                "share_format_selected",
                "share_export_requested",
                "share_export_presented",
                "share_export_completed",
                "share_export_cancelled",
                "share_export_failed"
            ]
        )
    }

    func testCompletedExportDoesNotAlsoCountDismissalAsCancellation() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .workoutDetail, format: .chartCard)) { event, parameters in
            events.append(event)
            XCTAssertEqual(parameters, ["source": "workout_detail", "format": "chart_card"])
        }
        session.presented()
        session.presented()
        session.finish(completed: true)
        session.finish(completed: false)
        XCTAssertEqual(events, [.shareExportRequested, .shareExportPresented, .shareExportCompleted])
    }

    func testCancellationAndFailureAreSeparateTerminalOutcomes() {
        for failed in [false, true] {
            var events: [AppAnalytics.Event] = []
            let session = ShareAnalyticsSession(context: .init(source: .postSave, format: .plainText)) { event, _ in
                events.append(event)
            }
            session.presented()
            session.finish(completed: false, failed: failed)
            session.finish(completed: false)
            XCTAssertEqual(events, [.shareExportRequested, .shareExportPresented,
                                    failed ? .shareExportFailed : .shareExportCancelled])
        }
    }

    func testPreparationFailureDoesNotCountAsPresentedOrCancelled() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .hrvHistory, format: .logs)) { event, _ in
            events.append(event)
        }
        session.finish(completed: false, failed: true)
        session.presented()
        session.finish(completed: false)
        XCTAssertEqual(events, [.shareExportRequested, .shareExportFailed])
    }

    func testNativeErrorTakesPrecedenceOverCompletedFlag() {
        var events: [AppAnalytics.Event] = []
        let session = ShareAnalyticsSession(context: .init(source: .hrvDetail, format: .logs)) { event, _ in
            events.append(event)
        }
        session.finish(completed: true, failed: true)
        XCTAssertEqual(events.last, .shareExportFailed)
    }

    func testEveryContextContainsOnlyFixedSourceAndFormatLabels() {
        for source in ShareAnalyticsContext.Source.allCases {
            for format in ShareAnalyticsContext.Format.allCases {
                XCTAssertEqual(ShareAnalyticsContext(source: source, format: format).parameters,
                               ["source": source.rawValue, "format": format.rawValue])
            }
        }
    }
}
