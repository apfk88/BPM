import Foundation

enum HeartRateConnectionAction: Equatable {
    case none
    case scan
    case scanLater
    case scheduleReconnect(UUID)
}

struct HeartRateConnectionState: Equatable {
    private(set) var selectedDeviceID: UUID?
    private(set) var lastConnectedDeviceID: UUID?
    private(set) var currentHeartRate: Int?
    private(set) var connectionStatus = "Not connected"
    private(set) var connectionMessage: String?
    private(set) var hasReceivedDataSinceConnect = false
    private(set) var isUserInitiatedDisconnect = false
    private(set) var lastHeartRateSampleTime: Date?
    private(set) var reconnectAttempts = 0

    mutating func startConnecting(to deviceID: UUID) {
        selectedDeviceID = deviceID
        currentHeartRate = nil
        connectionStatus = "Connecting..."
        connectionMessage = nil
        hasReceivedDataSinceConnect = false
        isUserInitiatedDisconnect = false
        lastHeartRateSampleTime = nil
        reconnectAttempts = 0
    }

    mutating func didConnect(to deviceID: UUID) {
        selectedDeviceID = deviceID
        lastConnectedDeviceID = deviceID
        connectionStatus = "Connected - Discovering services..."
        connectionMessage = nil
        hasReceivedDataSinceConnect = false
        isUserInitiatedDisconnect = false
        lastHeartRateSampleTime = nil
    }

    mutating func didEnableNotifications() {
        connectionStatus = "Connected - Waiting for data"
        connectionMessage = nil
        hasReceivedDataSinceConnect = false
        lastHeartRateSampleTime = nil
    }

    mutating func didReceiveHeartRate(_ heartRate: Int, at timestamp: Date) {
        guard heartRate > 0 else {
            currentHeartRate = nil
            return
        }

        currentHeartRate = heartRate
        connectionStatus = "Connected - Receiving data"
        connectionMessage = nil
        hasReceivedDataSinceConnect = true
        lastHeartRateSampleTime = timestamp
    }

    func shouldAttemptNoDataReconnect(now: Date, interval: TimeInterval) -> Bool {
        Self.shouldAttemptNoDataReconnect(
            hasReceivedDataSinceConnect: hasReceivedDataSinceConnect,
            lastSample: lastHeartRateSampleTime,
            now: now,
            interval: interval
        )
    }

    mutating func disconnectIntentionally() {
        isUserInitiatedDisconnect = true
        selectedDeviceID = nil
        lastConnectedDeviceID = nil
        currentHeartRate = nil
        connectionStatus = "Not connected"
        connectionMessage = nil
        hasReceivedDataSinceConnect = false
        lastHeartRateSampleTime = nil
        reconnectAttempts = 0
    }

    mutating func didDisconnect(deviceID: UUID, errorDescription: String?) -> HeartRateConnectionAction {
        let wasSelectedDevice = selectedDeviceID == deviceID
        let shouldReconnect = Self.shouldAutoReconnectAfterDisconnect(
            isUserInitiatedDisconnect: isUserInitiatedDisconnect,
            lastConnectedDeviceID: lastConnectedDeviceID,
            disconnectedDeviceID: deviceID
        )

        guard wasSelectedDevice else {
            return .scan
        }

        selectedDeviceID = nil
        currentHeartRate = nil
        connectionMessage = nil
        hasReceivedDataSinceConnect = false
        lastHeartRateSampleTime = nil

        if shouldReconnect {
            connectionStatus = "Disconnected - Reconnecting..."
            return .scheduleReconnect(deviceID)
        }

        connectionStatus = "Disconnected"
        return .scan
    }

    mutating func didFailToConnect(deviceID: UUID, errorDescription: String?) -> HeartRateConnectionAction {
        connectionMessage = Self.connectionFailureMessage(errorDescription: errorDescription)

        if selectedDeviceID == deviceID {
            selectedDeviceID = nil
        }

        if Self.shouldAutoReconnectAfterDisconnect(
            isUserInitiatedDisconnect: isUserInitiatedDisconnect,
            lastConnectedDeviceID: lastConnectedDeviceID,
            disconnectedDeviceID: deviceID
        ) {
            connectionStatus = "Connection failed - Retrying..."
            return .scheduleReconnect(deviceID)
        }

        connectionStatus = "Connection failed - device may be in use"
        return .scanLater
    }

    mutating func startReconnectAttempt(maxAttempts: Int) -> Bool {
        guard reconnectAttempts < maxAttempts else {
            connectionStatus = "Disconnected - Reconnect failed"
            lastConnectedDeviceID = nil
            reconnectAttempts = 0
            return false
        }

        reconnectAttempts += 1
        connectionStatus = "Reconnecting (\(reconnectAttempts)/\(maxAttempts))..."
        connectionMessage = "Trying to reconnect..."
        return true
    }

    static func shouldAttemptNoDataReconnect(
        hasReceivedDataSinceConnect: Bool,
        lastSample: Date?,
        now: Date,
        interval: TimeInterval
    ) -> Bool {
        guard hasReceivedDataSinceConnect, let lastSample else { return false }
        return now.timeIntervalSince(lastSample) >= interval
    }

    static func shouldAutoReconnectAfterDisconnect(
        isUserInitiatedDisconnect: Bool,
        lastConnectedDeviceID: UUID?,
        disconnectedDeviceID: UUID
    ) -> Bool {
        !isUserInitiatedDisconnect && lastConnectedDeviceID == disconnectedDeviceID
    }

    static func connectionFailureMessage(errorDescription: String?) -> String {
        guard let errorDescription else {
            return "Failed to connect: Unknown error. Device may be connected to another device."
        }

        let lowercased = errorDescription.lowercased()
        if lowercased.contains("busy") || lowercased.contains("already") || lowercased.contains("in use") {
            return "Device is connected to another device (like your treadmill). Please disconnect it from the other device first."
        }

        return "Failed to connect: \(errorDescription)"
    }
}
