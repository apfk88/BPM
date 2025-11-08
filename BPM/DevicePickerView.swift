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
            VStack(spacing: 0) {
                Text("View a friend's BPM or select your own device below")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                
                friendCodeSection
                deviceSection
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bluetoothManager.startScanning()
            }
        }
    }
    
    private var friendCodeSection: some View {
        VStack(spacing: 16) {
            Divider()
            
            VStack(spacing: 12) {
                Text("View Friend's BPM")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
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
                    VStack(spacing: 8) {
                        HStack {
                            Text("Currently viewing:")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text(friendCode)
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        }
                        Button {
                            sharingService.stopViewing()
                        } label: {
                            Text("Disconnect")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.red)
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 16)
            
            Divider()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var deviceSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Select Your Device")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 16)
                
                deviceList
                connectionInfo
                actionButtons
                privacyPolicyLink
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
            List(bluetoothManager.availableDevices) { device in
                DeviceRow(device: device)
                    .environmentObject(bluetoothManager)
                    .environmentObject(sharingService)
            }
        }
    }

    @ViewBuilder
    private var connectionInfo: some View {
        if let connectedDevice = bluetoothManager.connectedDevice {
            // Find the matching discovered device to get the display name
            let deviceName = bluetoothManager.availableDevices.first(where: { $0.peripheral.identifier == connectedDevice.identifier })?.displayName ?? connectedDevice.name ?? "Unknown Device"
            
            VStack(spacing: 12) {
                Divider()
                VStack(spacing: 8) {
                    HStack {
                        Text("Connected to:")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text(deviceName)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                    Button {
                        bluetoothManager.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
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

