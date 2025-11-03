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

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadDeviceNames()
    }
    
    func getDeviceName(for identifier: UUID) -> String? {
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
        if let device = connectedDevice {
            centralManager.cancelPeripheralConnection(device)
        }
        connectedDevice = nil
        currentHeartRate = nil
        heartRateSamples.removeAll()
        startScanning()
    }

    private func addHeartRateSample(_ value: Int) {
        let now = Date()
        let sample = HeartRateSample(value: value, timestamp: now)
        heartRateSamples.append(sample)

        let cutoff = now.addingTimeInterval(-3600)
        heartRateSamples.removeAll { $0.timestamp < cutoff }

        currentHeartRate = value
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
}

