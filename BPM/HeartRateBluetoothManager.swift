import Foundation
import CoreBluetooth
import Combine
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

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

final class HeartRateBluetoothManager: NSObject, ObservableObject {
    @Published var availableDevices: [DiscoveredPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var isScanning = false
    @Published var currentHeartRate: Int?
    @Published private(set) var heartRateSamples: [HeartRateSample] = []

    private var centralManager: CBCentralManager!
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementCharacteristicUUID = CBUUID(string: "2A37")
    private var pendingScanRequest = false
    private let centralRestoreIdentifier = "com.bpmapp.client.central"
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var shouldResumeScanningAfterBackground = false
    
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
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }

    func startScanning() {
        // In simulator, start fake data generation instead of real Bluetooth scanning
        if isSimulator {
            guard !isScanning else { return }
            isScanning = true
            pendingScanRequest = false
            startFakeDataGeneration()
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
        
        centralManager.scanForPeripherals(withServices: [heartRateServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        // Stop fake data generation if in simulator
        if isSimulator {
            guard isScanning else { return }
            isScanning = false
            stopFakeDataGeneration()
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
        connectedDevice = device
        
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

    func disconnect() {
        if !isSimulator {
            if let device = connectedDevice {
                centralManager.cancelPeripheralConnection(device)
            }
        }
        connectedDevice = nil
        currentHeartRate = nil
        heartRateSamples.removeAll()
        startScanning()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                HeartRateActivityController.shared.endActivity()
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
            let now = Date()
            let sample = HeartRateSample(value: value, timestamp: now)
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
                    HeartRateActivityController.shared.updateActivity(bpm: value, average: avg, maximum: max, minimum: min)
                }
            }
#endif
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.addHeartRateSample(value)
            }
        }
    }
}

extension HeartRateBluetoothManager {
    var maxHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        return heartRateSamples.map { $0.value }.max()
    }

    var avgHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        let total = heartRateSamples.reduce(0) { $0 + $1.value }
        return Int((Double(total) / Double(heartRateSamples.count)).rounded())
    }

    var minHeartRateLastHour: Int? {
        guard !heartRateSamples.isEmpty else { return nil }
        return heartRateSamples.map { $0.value }.min()
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
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
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
        peripheral.delegate = self
        peripheral.discoverServices([heartRateServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedDevice?.identifier == peripheral.identifier {
            connectedDevice = nil
            currentHeartRate = nil
        }

        startScanning()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                HeartRateActivityController.shared.endActivity()
            }
        }
#endif
        if connectedDevice == nil && !sharingService.isSharing {
            endBackgroundTask()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if connectedDevice?.identifier == peripheral.identifier {
            connectedDevice = nil
        }
        startScanning()
#if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                HeartRateActivityController.shared.endActivity()
            }
        }
#endif
        if connectedDevice == nil && !sharingService.isSharing {
            endBackgroundTask()
        }
    }
}

extension HeartRateBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == heartRateServiceUUID {
            peripheral.discoverCharacteristics([heartRateMeasurementCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics where characteristic.uuid == heartRateMeasurementCharacteristicUUID {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        guard let data = characteristic.value else { return }

        let heartRate = parseHeartRate(from: data)
        DispatchQueue.main.async { [weak self] in
            guard let heartRate else { return }
            self?.addHeartRateSample(heartRate)
        }
    }

    private func parseHeartRate(from data: Data) -> Int? {
        guard !data.isEmpty else { return nil }

        let flags = data[0]
        let is16Bit = (flags & 0x01) != 0

        if is16Bit {
            guard data.count >= 3 else { return nil }
            let lower = Int(data[1])
            let upper = Int(data[2]) << 8
            return lower | upper
        } else {
            guard data.count >= 2 else { return nil }
            return Int(data[1])
        }
    }
    
    // MARK: - Simulator Test Mode
    
    private func startFakeDataGeneration() {
        // Ensure we're on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Stop any existing timer
            self.stopFakeDataGeneration()
            
            // Reset fake data state
            self.fakeHeartRateBase = 75
            self.heartRateSamples.removeAll()
            
            // Start with an initial heart rate (already on main thread)
            self.addHeartRateSample(self.fakeHeartRateBase)
            
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
        // Generate realistic heart rate variations
        // Base heart rate oscillates between 60-100 BPM
        let variation = Int.random(in: -5...5) // Random variation
        
        // Update base direction occasionally
        if Int.random(in: 0...10) < 2 {
            fakeHeartRateDirection *= -1
        }
        
        // Apply direction change
        fakeHeartRateBase += fakeHeartRateDirection * Int.random(in: 1...3)
        
        // Keep within realistic bounds
        fakeHeartRateBase = max(60, min(100, fakeHeartRateBase))
        
        // Add variation
        let heartRate = fakeHeartRateBase + variation
        let clampedHeartRate = max(55, min(105, heartRate))
        
        // addHeartRateSample must be called on main thread for @Published properties
        // Timer callbacks are already on the thread that scheduled them (main thread)
        addHeartRateSample(clampedHeartRate)
    }
    
    private func manufacturerIdentifier(from data: Data?) -> UInt16? {
        guard let data, data.count >= 2 else {
            return nil
        }
        
        return UInt16(data[1]) << 8 | UInt16(data[0])
    }
}

