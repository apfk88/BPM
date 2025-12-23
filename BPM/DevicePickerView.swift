import SwiftUI
import CoreBluetooth

struct DevicePickerView: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var friendCodeInput: String = ""
    @FocusState private var isFriendCodeFieldFocused: Bool

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
                
                if !sharingService.isViewing {
                    deviceSection
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                bluetoothManager.startScanning()
                if let existingCode = sharingService.friendCode {
                    friendCodeInput = existingCode
                }
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
                
                VStack(spacing: 12) {
                    NumericCodeInputField(
                        code: Binding(
                            get: { sharingService.friendCode ?? friendCodeInput },
                            set: { newValue in
                                if !sharingService.isViewing {
                                    friendCodeInput = newValue
                                }
                            }
                        ),
                        length: 6,
                        focusBinding: $isFriendCodeFieldFocused
                    )
                    .disabled(sharingService.isViewing)

                    if sharingService.isViewing {
                        Button {
                            sharingService.stopViewing()
                            friendCodeInput = ""
                        } label: {
                            Text("Disconnect")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(6)
                        }
                    } else {
                        Button {
                            let code = friendCodeInput
                            if code.count == 6 {
                                sharingService.startViewing(code: code)
                                isFriendCodeFieldFocused = false
                                dismiss()
                            }
                        } label: {
                            Text("Connect")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(friendCodeInput.count == 6 ? Color.blue : Color.gray)
                                .cornerRadius(8)
                        }
                        .disabled(friendCodeInput.count != 6)
                    }
                }
                .padding(.horizontal)
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
                actionButtons
                privacyPolicyLink
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        // Check if we have any devices (real or simulator)
        let hasDevices = !bluetoothManager.availableDevices.isEmpty || bluetoothManager.simulatorDevice != nil

        if bluetoothManager.isScanning && !hasDevices {
            VStack(spacing: 20) {
                ProgressView()
                Text("Scanning for heart rate monitors…")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasDevices {
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
            List {
                // Show simulator device if available
                if let simDevice = bluetoothManager.simulatorDevice {
                    SimulatorDeviceRow(device: simDevice)
                        .environmentObject(bluetoothManager)
                        .environmentObject(sharingService)
                }
                // Show real devices
                ForEach(bluetoothManager.availableDevices) { device in
                    DeviceRow(device: device)
                        .environmentObject(bluetoothManager)
                        .environmentObject(sharingService)
                }
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

            if bluetoothManager.connectedDevice != nil || bluetoothManager.isSimulatorConnected {
                Button("Disconnect") {
                    bluetoothManager.disconnect()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
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

private extension DevicePickerView {
    func formattedCode(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}

private struct NumericCodeInputField: View {
    @Binding var code: String
    let length: Int
    var focusBinding: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach(0..<length, id: \.self) { index in
                    let character = character(at: index)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(focusBinding.wrappedValue ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: focusBinding.wrappedValue ? 2 : 1)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .frame(width: 44, height: 56)

                        Text(character)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundColor(character.isEmpty ? Color.secondary : Color.primary)
                    }
                }
            }

            TextField("Friend code", text: Binding(
                get: { code },
                set: { newValue in
                    let digits = newValue.filter { $0.isNumber }
                    if digits.count > length {
                        code = String(digits.prefix(length))
                    } else {
                        code = digits
                    }
                }
            ))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused(focusBinding)
            .frame(width: 0, height: 0)
            .opacity(0.01)
            .labelsHidden()
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            focusBinding.wrappedValue = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Friend code")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Enter a 6-digit code")
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let stringIndex = code.index(code.startIndex, offsetBy: index)
        return String(code[stringIndex])
    }

    private var accessibilityValue: String {
        if code.isEmpty {
            return "No digits entered"
        }
        return code.map(String.init).joined(separator: " ")
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    }
}

