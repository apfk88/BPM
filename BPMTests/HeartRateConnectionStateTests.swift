import Foundation
import Testing
@testable import BPM

struct HeartRateConnectionStateTests {
    @Test func connectionDoesNotReconnectBeforeFirstSample() {
        let deviceID = UUID()
        let start = Date()
        var state = HeartRateConnectionState()

        state.startConnecting(to: deviceID)
        state.didConnect(to: deviceID)
        state.didEnableNotifications()

        #expect(state.selectedDeviceID == deviceID)
        #expect(state.lastHeartRateSampleTime == nil)
        #expect(state.hasReceivedDataSinceConnect == false)
        #expect(state.shouldAttemptNoDataReconnect(now: start.addingTimeInterval(60), interval: 10) == false)
    }

    @Test func staleDataReconnectOnlyAfterSamplesStop() {
        let deviceID = UUID()
        let start = Date()
        var state = HeartRateConnectionState()

        state.startConnecting(to: deviceID)
        state.didConnect(to: deviceID)
        state.didEnableNotifications()
        state.didReceiveHeartRate(128, at: start)

        #expect(state.connectionStatus == "Connected - Receiving data")
        #expect(state.currentHeartRate == 128)
        #expect(state.shouldAttemptNoDataReconnect(now: start.addingTimeInterval(9), interval: 10) == false)
        #expect(state.shouldAttemptNoDataReconnect(now: start.addingTimeInterval(10), interval: 10) == true)
    }

    @Test func intentionalDisconnectClearsStateAndDoesNotReconnect() {
        let deviceID = UUID()
        let start = Date()
        var state = HeartRateConnectionState()

        state.startConnecting(to: deviceID)
        state.didConnect(to: deviceID)
        state.didReceiveHeartRate(140, at: start)
        state.disconnectIntentionally()
        let action = state.didDisconnect(deviceID: deviceID, errorDescription: nil)

        #expect(action == .scan)
        #expect(state.selectedDeviceID == nil)
        #expect(state.lastConnectedDeviceID == nil)
        #expect(state.currentHeartRate == nil)
        #expect(state.isUserInitiatedDisconnect)
        #expect(state.connectionStatus == "Not connected")
    }

    @Test func errantDisconnectSchedulesReconnectForLastDevice() {
        let deviceID = UUID()
        let start = Date()
        var state = HeartRateConnectionState()

        state.startConnecting(to: deviceID)
        state.didConnect(to: deviceID)
        state.didReceiveHeartRate(137, at: start)
        let action = state.didDisconnect(deviceID: deviceID, errorDescription: "The connection timed out.")

        #expect(action == .scheduleReconnect(deviceID))
        #expect(state.selectedDeviceID == nil)
        #expect(state.currentHeartRate == nil)
        #expect(state.connectionStatus == "Disconnected - Reconnecting...")
        #expect(state.lastConnectedDeviceID == deviceID)
    }

    @Test func failedAutoReconnectRetriesButManualFailureReturnsToScan() {
        let deviceID = UUID()
        var reconnectingState = HeartRateConnectionState()
        reconnectingState.startConnecting(to: deviceID)
        reconnectingState.didConnect(to: deviceID)
        #expect(reconnectingState.didDisconnect(deviceID: deviceID, errorDescription: "Dropped") == .scheduleReconnect(deviceID))

        let reconnectAction = reconnectingState.didFailToConnect(
            deviceID: deviceID,
            errorDescription: "Connection timed out."
        )

        #expect(reconnectAction == .scheduleReconnect(deviceID))
        #expect(reconnectingState.connectionStatus == "Connection failed - Retrying...")

        var manualState = HeartRateConnectionState()
        manualState.startConnecting(to: deviceID)
        let manualAction = manualState.didFailToConnect(deviceID: deviceID, errorDescription: "Peripheral is busy.")

        #expect(manualAction == .scanLater)
        #expect(manualState.connectionStatus == "Connection failed - device may be in use")
        #expect(manualState.connectionMessage == "Device is connected to another device (like your treadmill). Please disconnect it from the other device first.")
    }

    @Test func reconnectAttemptsStopAtLimit() {
        var state = HeartRateConnectionState()

        let firstAttempt = state.startReconnectAttempt(maxAttempts: 2)
        #expect(firstAttempt)
        #expect(state.connectionStatus == "Reconnecting (1/2)...")

        let secondAttempt = state.startReconnectAttempt(maxAttempts: 2)
        #expect(secondAttempt)
        #expect(state.connectionStatus == "Reconnecting (2/2)...")

        let thirdAttempt = state.startReconnectAttempt(maxAttempts: 2)
        #expect(thirdAttempt == false)
        #expect(state.connectionStatus == "Disconnected - Reconnect failed")
    }
}
