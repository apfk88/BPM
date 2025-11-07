import SwiftUI
import CoreBluetooth

struct DevicePickerView: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var friendCodeInput: String = ""

    var body: some View {
        NavigationView {
            VStack {
                friendCodeSection
                deviceList
                connectionInfo
                actionButtons
                privacyPolicyLink
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bluetoothManager.startScanning()
            }
        }
    }
    
    private var friendCodeSection: some View {
        VStack(spacing: 12) {
            Divider()
            Text("View Friend's Heart Rate")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(spacing: 12) {
                TextField("Enter 6-character code", text: $friendCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity)
                
                Button {
                    let code = friendCodeInput.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty && code.count == 6 {
                        sharingService.startViewing(code: code)
                        friendCodeInput = ""
                        dismiss()
                    }
                } label: {
                    Text("Connect")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(friendCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 ? Color.blue : Color.gray)
                        .cornerRadius(8)
                }
                .disabled(friendCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).count != 6)
            }
            .padding(.horizontal)
            
            if let friendCode = sharingService.friendCode {
                HStack {
                    Text("Currently viewing: \(friendCode)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Disconnect") {
                        sharingService.stopViewing()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .padding(.horizontal)
            }
            
            Divider()
        }
        .padding(.vertical, 8)
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
            List(bluetoothManager.availableDevices) { device in
                DeviceRow(device: device)
                    .environmentObject(bluetoothManager)
                    .environmentObject(sharingService)
            }
        }
    }

    @ViewBuilder
    private var connectionInfo: some View {
        if bluetoothManager.connectedDevice != nil {
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Text("Connected")
                        .foregroundColor(.secondary)
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
    
    private var privacyPolicyLink: some View {
        Button {
            if let url = URL(string: "https://apfk88.github.io/BPM/") {
                openURL(url)
            }
        } label: {
            Text("Privacy Policy")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    let device: DiscoveredPeripheral

    private var isConnected: Bool {
        bluetoothManager.connectedDevice?.identifier == device.peripheral.identifier
    }

    var body: some View {
        Button {
            if isConnected {
                bluetoothManager.disconnect()
            } else {
                sharingService.stopViewing()
                bluetoothManager.connect(to: device.peripheral)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let detail = device.detailText {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
    }
}

