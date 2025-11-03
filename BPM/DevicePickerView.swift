import SwiftUI
import CoreBluetooth

struct DevicePickerView: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack {
                deviceList
                connectionInfo
                actionButtons
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bluetoothManager.startScanning()
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if bluetoothManager.isScanning && bluetoothManager.availableDevices.isEmpty {
            VStack(spacing: 20) {
                ProgressView()
                Text("Scanning for heart rate monitors…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if bluetoothManager.availableDevices.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)
                Text("No devices found")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Make sure your chest strap is powered on and nearby.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(bluetoothManager.availableDevices, id: \.identifier) { device in
                DeviceRow(device: device)
                    .environmentObject(bluetoothManager)
            }
        }
    }

    @ViewBuilder
    private var connectionInfo: some View {
        if let connectedDevice = bluetoothManager.connectedDevice {
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Text("Connected:")
                        .foregroundColor(.secondary)
                    Text(connectedDevice.name ?? "Unknown Device")
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Disconnect") {
                        bluetoothManager.disconnect()
                    }
                    .foregroundColor(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Rescan") {
                bluetoothManager.stopScanning()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    bluetoothManager.startScanning()
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @Environment(\.dismiss) private var dismiss
    let device: CBPeripheral
    @State private var deviceName: String = ""

    private var isConnected: Bool {
        bluetoothManager.connectedDevice?.identifier == device.identifier
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isConnected {
                    bluetoothManager.disconnect()
                } else {
                    bluetoothManager.connect(to: device)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name ?? "Unknown Device")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(device.identifier.uuidString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isConnected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    }
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            
            TextField("Name", text: $deviceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onAppear {
                    deviceName = bluetoothManager.getDeviceName(for: device.identifier) ?? ""
                }
                .onChange(of: deviceName) {
                    let limited = String(deviceName.prefix(10))
                    if limited != deviceName {
                        deviceName = limited
                    }
                    bluetoothManager.setDeviceName(limited, for: device.identifier)
                }
        }
    }
}

