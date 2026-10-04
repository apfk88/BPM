import SwiftUI
import CoreBluetooth

struct DevicePickerView: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    @State private var friendCodeInput = ""
    @State private var isFriendSectionExpanded = false
    @FocusState private var isFriendCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Heart Rate Monitors") {
                    deviceList
                }
                Section {
                    DisclosureGroup(isExpanded: $isFriendSectionExpanded) {
                        friendCodeControls
                    } label: {
                        Label(sharingService.isViewing ? "Viewing Friend's BPM" : "View a Friend's BPM", systemImage: "person.2")
                    }
                } footer: {
                    Text("Connect a Bluetooth heart rate monitor or enter a friend's 6-digit share code.")
                }
                if bluetoothManager.connectedDevice != nil || bluetoothManager.isSimulatorConnected {
                    Section {
                        Button("Disconnect Monitor", role: .destructive) {
                            bluetoothManager.disconnect()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        bluetoothManager.stopScanning()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            bluetoothManager.startScanning()
                        }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                bluetoothManager.startScanning()
                isFriendSectionExpanded = sharingService.isViewing
                friendCodeInput = sharingService.friendCode ?? ""
            }
        }
    }

    @ViewBuilder
    private var friendCodeControls: some View {
        TextField("6-digit code", text: $friendCodeInput)
            .font(.title3.monospaced())
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($isFriendCodeFieldFocused)
            .disabled(sharingService.isViewing)
            .accessibilityLabel("Friend code")
            .onChange(of: friendCodeInput) { _, newValue in
                friendCodeInput = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }

        if sharingService.isViewing {
            Button("Disconnect Friend", role: .destructive) {
                sharingService.stopViewing()
                friendCodeInput = ""
            }
        } else {
            Button("Connect") {
                guard friendCodeInput.count == 6 else { return }
                AppAnalytics.signal(.connectFriendsCode)
                sharingService.startViewing(code: friendCodeInput)
                isFriendCodeFieldFocused = false
                dismiss()
            }
            .disabled(friendCodeInput.count != 6)
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        let hasDevices = !bluetoothManager.availableDevices.isEmpty || bluetoothManager.simulatorDevice != nil
        if let simDevice = bluetoothManager.simulatorDevice {
            SimulatorDeviceRow(device: simDevice)
        }
        ForEach(bluetoothManager.availableDevices) { device in
            DeviceRow(device: device)
        }
        if !hasDevices {
            if bluetoothManager.isScanning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning for heart rate monitors…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView(
                    "No Monitors Found",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(bluetoothManager.connectionMessage ?? "Make sure your chest strap is powered on and nearby, then rescan.")
                )
            }
        }
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
                AppAnalytics.signal(.connectDevice)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isConnected ? "Connected" : "Not connected")
    }
}

/// Row for displaying the simulator fake device
private struct SimulatorDeviceRow: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    let device: SimulatorDevice

    var body: some View {
        Button {
            if bluetoothManager.isSimulatorConnected {
                bluetoothManager.disconnectSimulator()
            } else {
                AppAnalytics.signal(.connectDevice)
                sharingService.stopViewing()
                bluetoothManager.connectSimulator()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("Simulated Device")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                if bluetoothManager.isSimulatorConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(bluetoothManager.isSimulatorConnected ? "Connected" : "Not connected")
    }
}
