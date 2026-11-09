import Foundation
import XCTest
@testable import BPM

final class HRVStartReadinessTests: XCTestCase {
    func testDisconnectedMonitorOffersConnectionInsteadOfAFailedMeasurement() {
        let readiness = local(connected: false)
        XCTAssertEqual(readiness.reason, .monitorDisconnected)
        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.shouldConnectMonitor)
        XCTAssertEqual(readiness.message, "Connect a heart rate monitor to measure HRV.")
    }

    func testReadinessExplainsContactAndDataPrerequisites() {
        XCTAssertEqual(local(contact: false).reason, .sensorContactLost)
        XCTAssertEqual(local(freshHeartRate: false).reason, .waitingForHeartRate)
        XCTAssertEqual(local(supportsRR: false).reason, .waitingForRR)
        XCTAssertEqual(local(lastBeat: nil).reason, .waitingForRR)
        XCTAssertEqual(local(lastBeat: 94.9).reason, .staleRR)
        XCTAssertTrue(local(lastBeat: 95).isReady)
        XCTAssertTrue(local().isReady)
        XCTAssertFalse(local().shouldConnectMonitor)
    }

    func testLocalReadinessUsesFiniteMonotonicFreshnessNotStoredCapabilityAlone() {
        for lastBeat in [TimeInterval.nan, .infinity, 101, 0] {
            XCTAssertEqual(local(lastBeat: lastBeat).reason, .staleRR)
        }
        for clock in [TimeInterval.nan, .infinity] {
            XCTAssertEqual(HRVStartReadiness.local(isConnected: true, hasSensorContact: true,
                                                 hasFreshHeartRate: true, supportsRR: true,
                                                 latestRRTicks: 100, nowTicks: clock).reason, .staleRR)
        }
    }

    func testSharedReadinessRequiresFreshSourceClockAndRawBeats() {
        XCTAssertTrue(HRVStartReadiness.shared(supportsRR: true, latestRRTicks: 1000,
                                              acquisitionTicks: 1001).isReady)
        let blocked: [HRVStartReadiness] = [
            .shared(supportsRR: false, latestRRTicks: 1000, acquisitionTicks: 1001),
            .shared(supportsRR: true, latestRRTicks: nil, acquisitionTicks: 1001),
            .shared(supportsRR: true, latestRRTicks: 1000, acquisitionTicks: nil),
            .shared(supportsRR: true, latestRRTicks: 1000, acquisitionTicks: 1006)
        ]
        for readiness in blocked {
            XCTAssertEqual(readiness.reason, .sharedDataUnavailable)
            XCTAssertFalse(readiness.isReady)
            XCTAssertFalse(readiness.shouldConnectMonitor)
        }
    }

    func testSharedMonitorReadinessNeverOffersALocalConnectionAction() {
        for reason in HRVStartReadiness.Reason.allCases {
            let readiness = HRVStartReadiness(source: .shared, reason: reason)
            XCTAssertFalse(readiness.shouldConnectMonitor)
            if reason != .ready && reason != .sharedDataUnavailable {
                XCTAssertTrue(readiness.message.contains("shared monitor"))
            }
        }
    }

    func testTelemetryIsBoundedPerStateReasonAndSourceForEachVisit() {
        var visit = HRVReadinessAnalytics()
        let ready = local()
        let blocked = local(supportsRR: false)
        XCTAssertEqual(visit.observation(blocked),
                       ["state": "blocked", "reason": "waiting_for_rr", "source": "local"])
        XCTAssertNil(visit.observation(blocked))
        XCTAssertEqual(visit.observation(ready), ["state": "ready", "reason": "ready", "source": "local"])
        XCTAssertNil(visit.observation(blocked))
        XCTAssertNil(visit.observation(ready))
        let shared = HRVStartReadiness.shared(supportsRR: true, latestRRTicks: 1000, acquisitionTicks: 1001)
        XCTAssertEqual(visit.observation(shared), ["state": "ready", "reason": "ready", "source": "shared"])
        var nextVisit = HRVReadinessAnalytics()
        XCTAssertNotNil(nextVisit.observation(blocked))
    }

    @MainActor
    func testReadinessRaceAfterInstructionsRemainsAStartFailure() {
        var events: [AppAnalytics.Event] = []
        var payloads: [[String: String]] = []
        let model = HRVMeasurementViewModel(playCompletionSound: {}, emitAnalytics: {
            events.append($0); payloads.append($1)
        })
        model.startReadiness = { self.local(lastBeat: 90) }
        model.startMeasurement()
        model.reset()
        model.stopLiveHeartRateUpdates()
        XCTAssertEqual(events, [.hrvFailed])
        XCTAssertEqual(payloads, [["reason": "sensor_unavailable", "detail": "stale_rr",
                                  "stage": "start", "source": "local"]])
    }

    private func local(connected: Bool = true, contact: Bool = true, freshHeartRate: Bool = true,
                       supportsRR: Bool = true, lastBeat: TimeInterval? = 100) -> HRVStartReadiness {
        .local(isConnected: connected, hasSensorContact: contact, hasFreshHeartRate: freshHeartRate,
               supportsRR: supportsRR, latestRRTicks: lastBeat, nowTicks: 100)
    }
}
