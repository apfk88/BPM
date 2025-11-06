import Foundation
import CoreBluetooth
import Combine

final class HeartRateBluetoothManager: NSObject, ObservableObject {
    @Published var availableDevices: [CBPeripheral] = []
    @Published var connectedDevice: CBPeripheral?
    @Published var isScanning = false
    @Published var currentHeartRate: Int?
    @Published private(set) var heartRateSamples: [HeartRateSample] = []

    private var centralManager: CBCentralManager!
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementCharacteristicUUID = CBUUID(string: "2A37")
    private var pendingScanRequest = false
    
    // Device names storage
    private var deviceNames: [String: String] = [:]
    private let deviceNamesKey = "HeartRateDeviceNames"
    
    // Sharing integration
    private let sharingService = SharingService.shared
    private var lastUpdateTime: Date?
    private let updateThrottleInterval: TimeInterval = 0.5 // 0.5 second minimum (2 Hz)
    
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
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadDeviceNames()
    }
    
    deinit {
        fakeDataTimer?.invalidate()
    }
    
    func getDeviceName(for identifier: UUID) -> String? {
        // In simulator, return a default test device name if not set
        if isSimulator && identifier == simulatorDeviceIdentifier {
            return deviceNames[identifier.uuidString] ?? "Simulator Test Device"
        }
        return deviceNames[identifier.uuidString]
    }
    
    func setDeviceName(_ name: String, for identifier: UUID) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            deviceNames.removeValue(forKey: identifier.uuidString)
        } else {
            deviceNames[identifier.uuidString] = trimmedName
        }
        saveDeviceNames()
        objectWillChange.send()
    }
    
    private func loadDeviceNames() {
        if let data = UserDefaults.standard.dictionary(forKey: deviceNamesKey) as? [String: String] {
            deviceNames = data
        }
    }
    
    private func saveDeviceNames() {
        UserDefaults.standard.set(deviceNames, forKey: deviceNamesKey)
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
        availableDevices = []
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

    func connect(to device: CBPeripheral) {
        stopScanning()
        connectedDevice = device
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
            
            // Update sharing service (throttled to 2 Hz)
            if let lastUpdate = lastUpdateTime {
                let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                if timeSinceLastUpdate >= updateThrottleInterval {
                    sharingService.updateHeartRate(value, max: maxHeartRateLastHour, avg: avgHeartRateLastHour)
                    lastUpdateTime = now
                }
            } else {
                sharingService.updateHeartRate(value, max: maxHeartRateLastHour, avg: avgHeartRateLastHour)
                lastUpdateTime = now
            }
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
}

extension HeartRateBluetoothManager: CBCentralManagerDelegate {
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
        if !availableDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            availableDevices.append(peripheral)
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
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if connectedDevice?.identifier == peripheral.identifier {
            connectedDevice = nil
        }
        startScanning()
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
}

