import Foundation
import CoreBluetooth
import Combine
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

struct RRInterval: Identifiable {
    let id = UUID()
    let value: Double // RR interval in milliseconds
    let timestamp: Date
}

struct DiscoveredPeripheral: Identifiable, Equatable {
    let peripheral: CBPeripheral
    let advertisedName: String?
    let manufacturerIdentifier: UInt16?
    let rssi: NSNumber?
    
    init(peripheral: CBPeripheral, advertisedName: String?, manufacturerIdentifier: UInt16?, rssi: NSNumber?) {
        self.peripheral = peripheral
        self.advertisedName = DiscoveredPeripheral.clean(advertisedName)
        self.manufacturerIdentifier = manufacturerIdentifier
        self.rssi = rssi
    }
    
    var id: UUID { peripheral.identifier }
    
    var displayName: String {
        if let advertisedName {
            return advertisedName
        }
        
        if let peripheralName = DiscoveredPeripheral.clean(peripheral.name) {
            return peripheralName
        }
        
        return peripheral.identifier.uuidString
    }
    
    var detailText: String? {
        if displayName != peripheral.identifier.uuidString {
            return peripheral.identifier.uuidString
        }
        
        if let rssi {
            return "RSSI \(rssi.intValue) dBm"
        }
        
        return nil
    }
    
    func merging(peripheral newPeripheral: CBPeripheral, advertisedName newName: String?, manufacturerIdentifier newIdentifier: UInt16?, rssi newRSSI: NSNumber?) -> DiscoveredPeripheral {
        DiscoveredPeripheral(
            peripheral: newPeripheral,
            advertisedName: newName ?? advertisedName,
            manufacturerIdentifier: newIdentifier ?? manufacturerIdentifier,
            rssi: newRSSI ?? rssi
        )
    }
    
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Represents a simulated heart rate device for testing in the simulator
struct SimulatorDevice: Identifiable, Equatable {
    let id = UUID()
    let name = "Simulator HR Monitor"
}

final class HeartRateBluetoothManager: NSObject, ObservableObject {
    @Published var availableDevices: [DiscoveredPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var isScanning = false
    @Published var currentHeartRate: Int?
    @Published private(set) var heartRateSamples: [HeartRateSample] = []
    @Published var debugMessages: [String] = []
    @Published var connectionStatus: String = "Not connected"
    @Published var supportsRRIntervals: Bool = false
    @Published private(set) var rrIntervals: [RRInterval] = []

    // Simulator-specific properties
    @Published var simulatorDevice: SimulatorDevice?
    @Published var isSimulatorConnected = false

    /// Returns true if there's an active data source (real device connected or simulator connected)
    var hasActiveDataSource: Bool {
        connectedDevice != nil || isSimulatorConnected
    }

    private var centralManager: CBCentralManager!
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementCharacteristicUUID = CBUUID(string: "2A37")
    private var pendingScanRequest = false
    private let centralRestoreIdentifier = "com.bpmapp.client.central"
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var shouldResumeScanningAfterBackground = false
    private var lastHeartRateSampleTime: Date?
    private var noDataTimer: Timer?
    private let noDataTimeoutInterval: TimeInterval = 20.0
    private var consecutiveZeroReadings = 0
    private let zeroReadingEndActivityThreshold = 3
    
    // Sharing integration
    private let sharingService = SharingService.shared
    private var lastUpdateTime: Date?
    private let updateThrottleInterval: TimeInterval = 1.0 // 1 second minimum (1 Hz)
    
    // Simulator test mode
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        // Runtime check as fallback
        return ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        #endif
    }
    private var fakeDataTimer: Timer?
    private var fakeHeartRateBase: Int = 75 // Starting baseline
    private var fakeHeartRateDirection: Int = 1 // 1 for increasing, -1 for decreasing
    private let fakeDataUpdateInterval: TimeInterval = 2.0 // Update every 2 seconds
    private let simulatorDeviceIdentifier = UUID() // Fixed identifier for simulator device

    // Auto-reconnect properties
    private var lastConnectedPeripheralIdentifier: UUID?
    private var isUserInitiatedDisconnect = false
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 100
    private let reconnectDelay: TimeInterval = 2.0

    override init() {
        super.init()
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: centralRestoreIdentifier
        ]
        centralManager = CBCentralManager(delegate: self, queue: nil, options: options)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        fakeDataTimer?.invalidate()
        reconnectTimer?.invalidate()
        noDataTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }

    func startScanning() {
        // In simulator, show fake device in list instead of real Bluetooth scanning
        if isSimulator {
            guard !isScanning else { return }
            isScanning = true
            pendingScanRequest = false
            // Show a fake device that can be "connected"
            simulatorDevice = SimulatorDevice()
            return
        }

        guard centralManager != nil else { return }
        guard centralManager.state == .poweredOn else {
            pendingScanRequest = true
            return
        }
        guard !isScanning else { return }

        isScanning = true
        pendingScanRequest = false

        // Preserve connected device in the list when starting a new scan
        if let connected = connectedDevice {
            availableDevices = availableDevices.filter { $0.id == connected.identifier }
        } else {
            availableDevices = []
        }

        // Scan without service filtering to discover devices that don't advertise the Heart Rate Service UUID
        // Some heart rate monitors only expose the service after connection
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Connect to the simulator fake device
    func connectSimulator() {
        guard isSimulator, simulatorDevice != nil else { return }
        isSimulatorConnected = true
        connectionStatus = "Connected (Simulator)"
        startFakeDataGeneration()
    }

    /// Disconnect from the simulator fake device
    func disconnectSimulator() {
        guard isSimulator else { return }
        isSimulatorConnected = false
        connectionStatus = "Not connected"
        stopFakeDataGeneration()
        invalidateNoDataTimer()
        consecutiveZeroReadings = 0
        lastHeartRateSampleTime = nil
        currentHeartRate = nil
        heartRateSamples.removeAll()
        rrIntervals.removeAll()
    }

    func stopScanning() {
        // In simulator, just stop scanning (don't affect connection)
        if isSimulator {
            guard isScanning else { return }
            isScanning = false
            // Don't clear simulatorDevice - keep it visible if connected
            if !isSimulatorConnected {
                simulatorDevice = nil
            }
            return
        }

        guard centralManager != nil else { return }
        guard isScanning else { return }

        isScanning = false
        centralManager.stopScan()
    }

    func enterBackground() {
        shouldResumeScanningAfterBackground = shouldResumeScanningAfterBackground || isScanning

        if isScanning && !isSimulator {
            centralManager.stopScan()
            isScanning = false
        }

        if connectedDevice != nil || sharingService.isSharing {
            beginBackgroundTaskIfNeeded()
        } else {
            endBackgroundTask()
        }
    }

    func enterForeground() {
        endBackgroundTask()

        if shouldResumeScanningAfterBackground {
            startScanning()
            shouldResumeScanningAfterBackground = false
        }
    }

    func connect(to device: CBPeripheral) {
        stopScanning()
        cancelReconnectTimer()

        // Check device state - if already connected to another device, we can't connect
        if device.state == .connected {
            let msg = "Device is already connected to another device (e.g., your treadmill). Please disconnect it first."
            print(msg)
            addDebugMessage(msg)
            connectionStatus = "Device busy - disconnect from other device"
            return
        }

        connectionStatus = "Connecting..."
        addDebugMessage("Connecting to \(device.name ?? device.identifier.uuidString)... (current state: \(deviceStateDescription(device.state)))")
        connectedDevice = device
        lastConnectedPeripheralIdentifier = device.identifier
        isUserInitiatedDisconnect = false
        reconnectAttempts = 0

        // Ensure connected device is in the available devices list
        if !availableDevices.contains(where: { $0.id == device.identifier }) {
            let discoveredPeripheral = DiscoveredPeripheral(
                peripheral: device,
                advertisedName: device.name,
                manufacturerIdentifier: nil,
                rssi: nil
            )
            availableDevices.append(discoveredPeripheral)
        }

        centralManager.connect(device, options: nil)
    }
    
    private func deviceStateDescription(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected (to another device)"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }

    func disconnect() {
        if isSimulator {
            disconnectSimulator()
            return
        }

        isUserInitiatedDisconnect = true
        cancelReconnectTimer()
        lastConnectedPeripheralIdentifier = nil

        if let device = connectedDevice {
            centralManager.cancelPeripheralConnection(device)
        }
        invalidateNoDataTimer()
        consecutiveZeroReadings = 0
        lastHeartRateSampleTime = nil
        connectedDevice = nil
        currentHeartRate = nil
        heartRateSamples.removeAll()
        rrIntervals.removeAll()
        supportsRRIntervals = false
        startScanning()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                await HeartRateActivityController.shared.endActivity()
            }
        }
#endif
        if connectedDevice == nil && !sharingService.isSharing {
            endBackgroundTask()
        }
    }

    @objc private func handleApplicationDidEnterBackground() {
        enterBackground()
    }

    @objc private func handleApplicationWillEnterForeground() {
        enterForeground()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskIdentifier == .invalid else { return }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "com.bpmapp.client.bluetooth") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    private func addHeartRateSample(_ value: Int) {
        // Ensure @Published properties are updated on main thread
        if Thread.isMainThread {
            if value <= 0 {
                handleZeroHeartRateReading()
                return
            }

            consecutiveZeroReadings = 0
            let now = Date()
            lastHeartRateSampleTime = now
            scheduleNoDataTimeout()
            let sample = HeartRateSample(value: value, timestamp: now, workoutTime: nil)
            heartRateSamples.append(sample)

            let cutoff = now.addingTimeInterval(-3600)
            heartRateSamples.removeAll { $0.timestamp < cutoff }

            currentHeartRate = value

            // Update sharing service (throttled to 1 Hz)
            let max = maxHeartRateLastHour
            let avg = avgHeartRateLastHour
            let min = minHeartRateLastHour

            if let lastUpdate = lastUpdateTime {
                let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                if timeSinceLastUpdate >= updateThrottleInterval {
                    sharingService.updateHeartRate(value, max: max, avg: avg, min: min)
                    lastUpdateTime = now
                }
            } else {
                sharingService.updateHeartRate(value, max: max, avg: avg, min: min)
                lastUpdateTime = now
            }

#if canImport(ActivityKit)
            if #available(iOS 16.1, *) {
                Task { @MainActor in
                    let zone = HeartRateZoneStorage.shared.currentZone(for: value)
                    HeartRateActivityController.shared.updateActivity(
                        bpm: value,
                        average: avg,
                        maximum: max,
                        minimum: min,
                        zone: zone?.zoneInfo,
                        isSharing: sharingService.isSharing,
                        isViewing: sharingService.isViewing
                    )
                }
            }
#endif
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.addHeartRateSample(value)
            }
        }
    }

    private func handleZeroHeartRateReading() {
        consecutiveZeroReadings += 1
        currentHeartRate = nil
        sharingService.updateHeartRate(nil, max: nil, avg: nil, min: nil)

#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                if consecutiveZeroReadings >= zeroReadingEndActivityThreshold {
                    await HeartRateActivityController.shared.endActivity()
                } else {
                    HeartRateActivityController.shared.updateActivity(
                        bpm: nil,
                        average: nil,
                        maximum: nil,
                        minimum: nil,
                        zone: nil,
                        isSharing: sharingService.isSharing,
                        isViewing: sharingService.isViewing
                    )
                }
            }
        }
#endif
    }

    private func scheduleNoDataTimeout() {
        invalidateNoDataTimer()
        noDataTimer = Timer.scheduledTimer(withTimeInterval: noDataTimeoutInterval, repeats: false) { [weak self] _ in
            self?.handleNoDataTimeout()
        }
    }

    private func invalidateNoDataTimer() {
        noDataTimer?.invalidate()
        noDataTimer = nil
    }

    private func handleNoDataTimeout() {
        guard let lastSample = lastHeartRateSampleTime else { return }
        guard Date().timeIntervalSince(lastSample) >= noDataTimeoutInterval else { return }

        if let device = connectedDevice {
            centralManager.cancelPeripheralConnection(device)
        } else if isSimulatorConnected {
            disconnectSimulator()
        }

        invalidateNoDataTimer()
        consecutiveZeroReadings = 0
        lastHeartRateSampleTime = nil
        connectedDevice = nil
        currentHeartRate = nil
        heartRateSamples.removeAll()
        rrIntervals.removeAll()
        supportsRRIntervals = false
        connectionStatus = "Disconnected - No data"
        sharingService.updateHeartRate(nil, max: nil, avg: nil, min: nil)

#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                await HeartRateActivityController.shared.endActivity()
            }
        }
#endif

        startScanning()
    }
}

extension HeartRateBluetoothManager {
    var maxHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        return heartRateSamples.map { $0.value }.max()
    }

    var avgHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        let nonZeroSamples = heartRateSamples.filter { $0.value > 0 }
        guard !nonZeroSamples.isEmpty else { return nil }
        let total = nonZeroSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(nonZeroSamples.count)).rounded())
    }

    var minHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        return heartRateSamples.map { $0.value }.filter { $0 > 0 }.min()
    }

    func timeInZonesLastHour(config: HeartRateZoneConfig) -> [ZoneTimeData] {
        var zoneDurations: [HeartRateZone: TimeInterval] = [:]

        for zone in HeartRateZone.allCases {
            zoneDurations[zone] = 0
        }

        // Match timer sampling behavior: treat each sample as ~1 second.
        let sampleInterval: TimeInterval = 1.0

        for sample in heartRateSamples {
            if let zone = HeartRateZone.zone(for: sample.value, config: config) {
                zoneDurations[zone, default: 0] += sampleInterval
            }
        }

        return HeartRateZone.allCases.map { zone in
            ZoneTimeData(zone: zone, duration: zoneDurations[zone] ?? 0)
        }
    }
}

extension HeartRateBluetoothManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in restoredPeripherals {
                peripheral.delegate = self

                if connectedDevice == nil || connectedDevice?.identifier == peripheral.identifier {
                    connectedDevice = peripheral

                    if !availableDevices.contains(where: { $0.id == peripheral.identifier }) {
                        let discoveredPeripheral = DiscoveredPeripheral(
                            peripheral: peripheral,
                            advertisedName: peripheral.name,
                            manufacturerIdentifier: nil,
                            rssi: nil
                        )
                        availableDevices.append(discoveredPeripheral)
                    }
                }
            }
        }

        if let _ = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            shouldResumeScanningAfterBackground = true
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if pendingScanRequest {
                startScanning()
            }
        case .unauthorized, .unsupported, .poweredOff, .resetting, .unknown:
            stopScanning()
        @unknown default:
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Filter to only show devices that advertise the Heart Rate Service UUID
        // or devices that might be heart rate monitors (based on name patterns)
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let hasHeartRateService = advertisedServices?.contains(heartRateServiceUUID) ?? false
        
        // Also check for common heart rate monitor name patterns
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name
        let name = localName ?? peripheralName ?? ""
        let nameLower = name.lowercased()
        let isLikelyHeartRateMonitor = hasHeartRateService || 
            nameLower.contains("heart") || 
            nameLower.contains("hr") || 
            nameLower.contains("bpm") ||
            nameLower.contains("polar") ||
            nameLower.contains("garmin") ||
            nameLower.contains("wahoo") ||
            nameLower.contains("suunto") ||
            nameLower.contains("coach")
        
        // Only add devices that are likely heart rate monitors
        guard isLikelyHeartRateMonitor else { return }
        
        let manufacturerIdentifier = manufacturerIdentifier(from: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        
        if let index = availableDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            availableDevices[index] = availableDevices[index]
                .merging(
                    peripheral: peripheral,
                    advertisedName: localName,
                    manufacturerIdentifier: manufacturerIdentifier,
                    rssi: RSSI
                )
        } else {
            let discoveredPeripheral = DiscoveredPeripheral(
                peripheral: peripheral,
                advertisedName: localName,
                manufacturerIdentifier: manufacturerIdentifier,
                rssi: RSSI
            )
            availableDevices.append(discoveredPeripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Reset reconnect state on successful connection
        reconnectAttempts = 0
        cancelReconnectTimer()
        isUserInitiatedDisconnect = false

        let msg = "Connected to \(peripheral.name ?? peripheral.identifier.uuidString)"
        print(msg)
        addDebugMessage(msg)
        connectionStatus = "Connected - Discovering services..."
        peripheral.delegate = self
        // Discover all services first, then we'll check for heart rate service
        // Some devices don't advertise the service but expose it after connection
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasConnectedDevice = connectedDevice?.identifier == peripheral.identifier
        let willAttemptReconnect = !isUserInitiatedDisconnect && lastConnectedPeripheralIdentifier == peripheral.identifier

        if wasConnectedDevice {
            invalidateNoDataTimer()
            consecutiveZeroReadings = 0
            lastHeartRateSampleTime = nil
            let msg = error != nil ? "Disconnected: \(error!.localizedDescription)" : "Disconnected"
            print(msg)
            addDebugMessage(msg)
            connectedDevice = nil
            currentHeartRate = nil

            // Clear heart rate for sharing viewers (show dashes)
            sharingService.updateHeartRate(nil, max: nil, avg: nil, min: nil)

            // Update Live Activity to show disconnected state
#if canImport(ActivityKit)
            if #available(iOS 16.1, *) {
                Task { @MainActor in
                    HeartRateActivityController.shared.updateActivity(
                        bpm: nil,
                        average: nil,
                        maximum: nil,
                        minimum: nil,
                        zone: nil,
                        isSharing: sharingService.isSharing,
                        isViewing: sharingService.isViewing
                    )
                }
            }
#endif

            // Attempt auto-reconnect if this wasn't a user-initiated disconnect
            if willAttemptReconnect {
                connectionStatus = "Disconnected - Reconnecting..."
                scheduleReconnect(to: peripheral)
                return
            }

            connectionStatus = "Disconnected"
        }

        startScanning()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                await HeartRateActivityController.shared.endActivity()
            }
        }
#endif
        if connectedDevice == nil && !sharingService.isSharing {
            endBackgroundTask()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        var msg: String
        if let error = error {
            let errorDesc = error.localizedDescription
            // Check for common connection errors
            if errorDesc.contains("busy") || errorDesc.contains("already") || errorDesc.contains("in use") {
                msg = "Device is connected to another device (like your treadmill). Please disconnect it from the other device first."
            } else {
                msg = "Failed to connect: \(errorDesc)"
            }
        } else {
            msg = "Failed to connect: Unknown error. Device may be connected to another device."
        }

        print(msg)
        addDebugMessage(msg)

        if connectedDevice?.identifier == peripheral.identifier {
            connectedDevice = nil
        }

        // If we were trying to auto-reconnect, schedule another attempt
        if !isUserInitiatedDisconnect && lastConnectedPeripheralIdentifier == peripheral.identifier {
            connectionStatus = "Connection failed - Retrying..."
            scheduleReconnect(to: peripheral)
            return
        }

        connectionStatus = "Connection failed - device may be in use"

        // Retry scanning after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startScanning()
        }
    }
}

extension HeartRateBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            let msg = "Error discovering services: \(error?.localizedDescription ?? "unknown")"
            print(msg)
            addDebugMessage(msg)
            return
        }
        guard let services = peripheral.services else {
            let msg = "No services found on peripheral"
            print(msg)
            addDebugMessage(msg)
            return
        }

        // Look for the Heart Rate Service
        let heartRateService = services.first { $0.uuid == heartRateServiceUUID }
        
        if let heartRateService = heartRateService {
            let msg = "Found Heart Rate Service, discovering characteristics..."
            print(msg)
            addDebugMessage(msg)
            peripheral.discoverCharacteristics([heartRateMeasurementCharacteristicUUID], for: heartRateService)
        } else {
            let msg = "Heart Rate Service not found. Available services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))"
            print(msg)
            addDebugMessage(msg)
            // If we don't find the heart rate service, disconnect since this isn't a heart rate monitor
            if connectedDevice?.identifier == peripheral.identifier {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            let msg = "Error discovering characteristics: \(error?.localizedDescription ?? "unknown")"
            print(msg)
            addDebugMessage(msg)
            return
        }
        guard let characteristics = service.characteristics else {
            let msg = "No characteristics found for service"
            print(msg)
            addDebugMessage(msg)
            return
        }

        let heartRateCharacteristic = characteristics.first { $0.uuid == heartRateMeasurementCharacteristicUUID }
        
        if let heartRateCharacteristic = heartRateCharacteristic {
            let msg = "Found Heart Rate Measurement Characteristic, enabling notifications..."
            print(msg)
            addDebugMessage(msg)
            peripheral.setNotifyValue(true, for: heartRateCharacteristic)
        } else {
            let msg = "Heart Rate Measurement Characteristic not found. Available: \(characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))"
            print(msg)
            addDebugMessage(msg)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let msg = "Error reading characteristic value: \(error.localizedDescription)"
            print(msg)
            addDebugMessage(msg)
            return
        }
        guard let data = characteristic.value else {
            let msg = "No data received from characteristic"
            print(msg)
            addDebugMessage(msg)
            return
        }

        let parsedData = parseHeartRateData(from: data)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            guard let heartRate = parsedData.heartRate else {
                let msg = "Failed to parse heart rate from data: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))"
                print(msg)
                self.addDebugMessage(msg)
                return
            }
            
            // Update RR interval support status
            if parsedData.hasRRIntervals {
                if !self.supportsRRIntervals {
                    self.supportsRRIntervals = true
                    let msg = "Device supports RR intervals"
                    print(msg)
                    self.addDebugMessage(msg)
                }
                
                // Add RR intervals
                let now = Date()
                for rrValue in parsedData.rrIntervals {
                    let interval = RRInterval(value: rrValue, timestamp: now)
                    self.rrIntervals.append(interval)
                }
                
                // Keep only last hour of RR intervals
                let cutoff = now.addingTimeInterval(-3600)
                self.rrIntervals.removeAll { $0.timestamp < cutoff }
            } else {
                // If we previously detected RR intervals but now they're missing, keep the support flag
                // (some packets may not include RR intervals even if device supports them)
            }
            
            let msg = "Received heart rate: \(heartRate) BPM" + (parsedData.hasRRIntervals ? " (with \(parsedData.rrIntervals.count) RR intervals)" : "")
            print(msg)
            self.addDebugMessage(msg)
            self.connectionStatus = "Connected - Receiving data"
            self.addHeartRateSample(heartRate)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let msg = "Error updating notification state: \(error.localizedDescription)"
            print(msg)
            addDebugMessage(msg)
        } else {
            let msg = "Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid.uuidString)"
            print(msg)
            addDebugMessage(msg)
            if characteristic.isNotifying {
                connectionStatus = "Connected - Waiting for data"
                lastHeartRateSampleTime = Date()
                scheduleNoDataTimeout()
            }
        }
    }
    
    private func addDebugMessage(_ message: String) {
        #if DEBUG
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugMessages.append("[\(timestamp)] \(message)")
            // Keep only last 10 messages
            if self.debugMessages.count > 10 {
                self.debugMessages.removeFirst()
            }
        }
        #else
        // In production, still log to console but don't store in UI
        print(message)
        #endif
    }

    private struct ParsedHeartRateData {
        let heartRate: Int?
        let hasRRIntervals: Bool
        let rrIntervals: [Double] // RR intervals in milliseconds
    }
    
    private func parseHeartRateData(from data: Data) -> ParsedHeartRateData {
        guard !data.isEmpty else {
            return ParsedHeartRateData(heartRate: nil, hasRRIntervals: false, rrIntervals: [])
        }

        let flags = data[0]
        let is16Bit = (flags & 0x01) != 0
        let hasRRIntervals = (flags & 0x10) != 0 // Bit 4 indicates RR intervals present
        
        // Parse heart rate
        var heartRate: Int?
        var offset: Int
        
        if is16Bit {
            guard data.count >= 3 else {
                return ParsedHeartRateData(heartRate: nil, hasRRIntervals: false, rrIntervals: [])
            }
            let lower = Int(data[1])
            let upper = Int(data[2]) << 8
            heartRate = lower | upper
            offset = 3
        } else {
            guard data.count >= 2 else {
                return ParsedHeartRateData(heartRate: nil, hasRRIntervals: false, rrIntervals: [])
            }
            heartRate = Int(data[1])
            offset = 2
        }
        
        // Parse RR intervals if present
        var rrIntervals: [Double] = []
        if hasRRIntervals {
            // RR intervals are stored as 2-byte values in 1/1024 second units
            // Multiple RR intervals can be present
            while offset + 2 <= data.count {
                let rrValue = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                // Convert from 1/1024 seconds to milliseconds
                let rrMs = (Double(rrValue) / 1024.0) * 1000.0
                rrIntervals.append(rrMs)
                offset += 2
            }
        }
        
        return ParsedHeartRateData(heartRate: heartRate, hasRRIntervals: hasRRIntervals, rrIntervals: rrIntervals)
    }
    
    private func parseHeartRate(from data: Data) -> Int? {
        return parseHeartRateData(from: data).heartRate
    }
    
    // MARK: - Auto-Reconnect

    private func scheduleReconnect(to peripheral: CBPeripheral) {
        guard reconnectAttempts < maxReconnectAttempts else {
            let msg = "Max reconnect attempts (\(maxReconnectAttempts)) reached. Please reconnect manually."
            print(msg)
            addDebugMessage(msg)
            connectionStatus = "Disconnected - Reconnect failed"
            lastConnectedPeripheralIdentifier = nil
            reconnectAttempts = 0
            startScanning()
            return
        }

        reconnectAttempts += 1
        let msg = "Scheduling reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(reconnectDelay)s..."
        print(msg)
        addDebugMessage(msg)

        // Keep the background task alive during reconnection attempts
        beginBackgroundTaskIfNeeded()

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            self?.attemptReconnect(to: peripheral)
        }
    }

    private func attemptReconnect(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn else {
            let msg = "Bluetooth not ready, will retry when powered on"
            print(msg)
            addDebugMessage(msg)
            pendingScanRequest = true
            return
        }

        guard lastConnectedPeripheralIdentifier == peripheral.identifier else {
            let msg = "Reconnect cancelled - different device selected"
            print(msg)
            addDebugMessage(msg)
            return
        }

        let msg = "Attempting to reconnect (attempt \(reconnectAttempts)/\(maxReconnectAttempts))..."
        print(msg)
        addDebugMessage(msg)
        connectionStatus = "Reconnecting (\(reconnectAttempts)/\(maxReconnectAttempts))..."

        // Store reference and attempt connection
        connectedDevice = peripheral
        centralManager.connect(peripheral, options: nil)
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: - Simulator Test Mode

    private func startFakeDataGeneration() {
        // Ensure we're on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Stop any existing timer
            self.stopFakeDataGeneration()
            
            // Reset fake data state
            self.fakeHeartRateBase = 100
            self.heartRateSamples.removeAll()
            self.rrIntervals.removeAll()
            self.supportsRRIntervals = true // Simulator supports RR intervals for testing
            
            // Start with an initial heart rate (already on main thread)
            self.addHeartRateSample(self.fakeHeartRateBase)
            self.generateFakeRRIntervals(for: self.fakeHeartRateBase)
            
            // Create timer on main thread
            self.fakeDataTimer = Timer.scheduledTimer(withTimeInterval: self.fakeDataUpdateInterval, repeats: true) { [weak self] timer in
                self?.generateFakeHeartRate()
            }
            
            // Add timer to common run loop modes so it continues during UI interactions
            RunLoop.current.add(self.fakeDataTimer!, forMode: .common)
        }
    }
    
    private func stopFakeDataGeneration() {
        // Timer invalidation is thread-safe, but ensure it happens on main thread
        if Thread.isMainThread {
            fakeDataTimer?.invalidate()
            fakeDataTimer = nil
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.fakeDataTimer?.invalidate()
                self?.fakeDataTimer = nil
            }
        }
    }
    
    private func generateFakeHeartRate() {
        // Generate predictable simulator data: start at 100, then +/- 5% each tick
        let changeFactor = Bool.random() ? 1.05 : 0.95
        let nextHeartRate = Int((Double(fakeHeartRateBase) * changeFactor).rounded())
        let clampedHeartRate = max(40, min(220, nextHeartRate))
        fakeHeartRateBase = clampedHeartRate
        
        // addHeartRateSample must be called on main thread for @Published properties
        // Timer callbacks are already on the thread that scheduled them (main thread)
        addHeartRateSample(clampedHeartRate)
        
        // Generate fake RR intervals for testing
        generateFakeRRIntervals(for: clampedHeartRate)
    }
    
    private func generateFakeRRIntervals(for heartRate: Int) {
        // Generate 1-3 RR intervals per update to simulate realistic data
        // RR interval = 60000 / BPM (in milliseconds)
        let baseRR = 60000.0 / Double(heartRate)
        let numIntervals = Int.random(in: 1...3)
        let now = Date()
        
        for _ in 0..<numIntervals {
            // Add some realistic variation (±5% of base RR interval)
            let variation = Double.random(in: -0.05...0.05)
            let rrValue = baseRR * (1.0 + variation)
            let interval = RRInterval(value: rrValue, timestamp: now)
            rrIntervals.append(interval)
        }
        
        // Keep only last hour of RR intervals
        let cutoff = now.addingTimeInterval(-3600)
        rrIntervals.removeAll { $0.timestamp < cutoff }
    }
    
    private func manufacturerIdentifier(from data: Data?) -> UInt16? {
        guard let data, data.count >= 2 else {
            return nil
        }
        
        return UInt16(data[1]) << 8 | UInt16(data[0])
    }
}
