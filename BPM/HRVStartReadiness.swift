import Foundation

/// A readiness check, not a diagnosis of the monitor or the person's health.
struct HRVStartReadiness: Equatable, Hashable {
    enum Source: String { case local, shared }
    enum Reason: String, CaseIterable, Codable {
        case ready
        case monitorDisconnected = "monitor_disconnected"
        case sensorContactLost = "sensor_contact_lost"
        case waitingForHeartRate = "waiting_for_heart_rate"
        case waitingForRR = "waiting_for_rr"
        case staleRR = "stale_rr"
        case sharedDataUnavailable = "shared_data_unavailable"
    }

    let source: Source
    let reason: Reason
    var isReady: Bool { reason == .ready }
    var shouldConnectMonitor: Bool { source == .local && reason == .monitorDisconnected }

    var message: String {
        if source == .shared {
            switch reason {
            case .monitorDisconnected: return "Waiting for the shared monitor to connect."
            case .sensorContactLost: return "Check the shared monitor's skin contact."
            case .waitingForHeartRate: return "Waiting for heart-rate data from the shared monitor."
            case .waitingForRR: return "Waiting for beat intervals from the shared monitor."
            case .staleRR: return "Beat data stopped. Check the shared monitor's connection and contact."
            case .ready, .sharedDataUnavailable: break
            }
        }
        switch reason {
        case .ready: return "Ready to measure HRV."
        case .monitorDisconnected: return "Connect a heart rate monitor to measure HRV."
        case .sensorContactLost: return "Check the strap's skin contact."
        case .waitingForHeartRate: return "Waiting for heart-rate data from your monitor."
        case .waitingForRR: return "Waiting for beat intervals. Your monitor must support RR data."
        case .staleRR: return "Beat data stopped. Check your strap's connection and contact."
        case .sharedDataUnavailable: return "Waiting for shared beat intervals. Keep the monitor connected and sharing open."
        }
    }

    var parameters: [String: String] {
        ["state": isReady ? "ready" : "blocked", "reason": reason.rawValue, "source": source.rawValue]
    }

    static func local(isConnected: Bool, hasSensorContact: Bool, hasFreshHeartRate: Bool,
                      supportsRR: Bool, latestRRTicks: TimeInterval?, nowTicks: TimeInterval) -> Self {
        let reason: Reason
        if !isConnected {
            reason = .monitorDisconnected
        } else if !hasSensorContact {
            reason = .sensorContactLost
        } else if !hasFreshHeartRate {
            reason = .waitingForHeartRate
        } else if !supportsRR || latestRRTicks == nil {
            reason = .waitingForRR
        } else if !hasFreshBeats(latestRRTicks: latestRRTicks, nowTicks: nowTicks) {
            reason = .staleRR
        } else {
            reason = .ready
        }
        return Self(source: .local, reason: reason)
    }

    static func shared(supportsRR: Bool, latestRRTicks: TimeInterval?, acquisitionTicks: TimeInterval?) -> Self {
        let ready = supportsRR && acquisitionTicks.map {
            hasFreshBeats(latestRRTicks: latestRRTicks, nowTicks: $0)
        } == true
        return Self(source: .shared, reason: ready ? .ready : .sharedDataUnavailable)
    }

    private static func hasFreshBeats(latestRRTicks: TimeInterval?, nowTicks: TimeInterval) -> Bool {
        guard let latestRRTicks, latestRRTicks.isFinite, nowTicks.isFinite else { return false }
        return (0...5).contains(nowTicks - latestRRTicks)
    }
}

/// The view owns one instance per presentation. Redraws, child sheets, and a
/// source flapping between the same states cannot produce a stream of events.
struct HRVReadinessAnalytics {
    private var observed: Set<HRVStartReadiness> = []

    mutating func observation(_ readiness: HRVStartReadiness) -> [String: String]? {
        guard observed.insert(readiness).inserted else { return nil }
        return readiness.parameters
    }
}
