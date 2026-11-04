import SwiftUI
import CoreBluetooth
import UIKit

struct DevicePickerView: View {
    @EnvironmentObject private var bluetoothManager: HeartRateBluetoothManager
    @EnvironmentObject private var sharingService: SharingService
    @Environment(\.dismiss) private var dismiss
    var localWorkoutNeedsConfirmation = false
    var onJoinFriend: ((String) -> Void)? = nil
    @State private var pendingFriendCode: String?
    @State private var showJoinConfirmation = false
    @State private var friendCodeInput = ""
    @State private var isFriendSectionExpanded = false
    @State private var shareNeedsMonitor = false
    @State private var copiedShareCode: String?
    @FocusState private var isFriendCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Heart Rate Monitors") {
                    deviceList
                }
                Section("Sharing") {
                    sharingControls
                    if !sharingService.isSharing && !sharingService.isStartingSharing {
                        DisclosureGroup(isExpanded: $isFriendSectionExpanded) {
                            friendCodeControls
                        } label: {
                            Label(sharingService.isViewing ? "Viewing Friend's BPM" : "View a Friend's BPM", systemImage: "person.2")
                                .foregroundStyle(sharingService.isViewing ? Color.green : Color.primary)
                        }
                    }
                    if let status = sharingStatus {
                        Text(status.message)
                            .font(.footnote)
                            .foregroundStyle(status.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("deviceSharingStatus")
                    }
                }
                if bluetoothManager.connectedDevice != nil || bluetoothManager.isSimulatorConnected {
                    Section {
                        Button("Disconnect Monitor") {
                            bluetoothManager.disconnect()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Select Device")
            .analyticsScreen(.devices)
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
                consumePendingJoinCode()
            }
            .onChange(of: sharingService.pendingJoinCode) { _, _ in
                consumePendingJoinCode()
            }
            .alert("End Current Workout?", isPresented: $showJoinConfirmation) {
                Button("Cancel", role: .cancel) { pendingFriendCode = nil }
                Button("End Workout and Connect", role: .destructive) {
                    if let code = pendingFriendCode { joinFriend(code) }
                    pendingFriendCode = nil
                }
            } message: {
                Text("Connecting to your friend ends and clears your current workout.")
            }
            .onChange(of: bluetoothManager.hasActiveDataSource) { _, connected in
                if connected { shareNeedsMonitor = false }
            }
            .onChange(of: sharingService.shareCode) { _, _ in
                copiedShareCode = nil
                shareNeedsMonitor = false
            }
            .onChange(of: sharingService.isViewing) { _, isViewing in
                shareNeedsMonitor = false
                if isViewing {
                    isFriendSectionExpanded = true
                    friendCodeInput = sharingService.friendCode ?? ""
                }
            }
        }
        .tint(.white)
    }

    @ViewBuilder
    private var sharingControls: some View {
        if sharingService.isSharing {
            if let code = sharingService.shareCode {
                HStack(spacing: 12) {
                    Text("Share Code")
                    Spacer(minLength: 8)
                    Text(formattedCode(code))
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("liveHeartRateShareCode")
                    Button {
                        UIPasteboard.general.string = code
                        copiedShareCode = code
                    } label: {
                        Image(systemName: copiedShareCode == code ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedShareCode == code ? "Copied" : "Copy share code")
                    .accessibilityIdentifier("copyLiveHeartRateShareCode")
                }
            }
            if let url = sharingService.shareURL {
                ShareLink(item: url, subject: Text("Live BPM"), message: Text("Join my live BPM workout.")) {
                    Label("Share Invite", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareLiveHeartRateInvite")
            }
            Button("Stop Sharing") {
                sharingService.stopSharing()
            }
            .accessibilityIdentifier("stopLiveHeartRateSharing")
        } else if !sharingService.isViewing {
            Button(action: startSharing) {
                HStack {
                    Label("Start Sharing", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if sharingService.isStartingSharing {
                        ProgressView()
                    }
                }
            }
            .disabled(sharingService.isStartingSharing)
            .accessibilityValue(sharingService.isStartingSharing ? "Starting" : "Off")
            .accessibilityIdentifier("startLiveHeartRateSharing")
        }
    }

    private var sharingStatus: (message: String, color: Color)? {
        if shareNeedsMonitor && !bluetoothManager.hasActiveDataSource && !sharingService.isViewing {
            return ("Connect a heart rate monitor to share.", .secondary)
        }
        if let message = sharingService.errorMessage {
            return (message, .secondary)
        }
        if sharingService.isSharing, let message = sharingService.workoutSharingError {
            return (message, .secondary)
        }
        return nil
    }

    private func startSharing() {
        guard !sharingService.isSharing, !sharingService.isStartingSharing, !sharingService.isViewing else { return }
        if sharingService.errorContext == .sharing {
            sharingService.errorMessage = nil
            sharingService.errorContext = nil
        }
        guard bluetoothManager.hasActiveDataSource else {
            shareNeedsMonitor = true
            return
        }
        shareNeedsMonitor = false
        Task { @MainActor in
            do {
                try await sharingService.startSharing()
            } catch {
                // The service publishes a single error in this section.
            }
        }
    }

    private func formattedCode(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
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
            .accessibilityIdentifier("friendShareCode")
            .onChange(of: friendCodeInput) { _, newValue in
                friendCodeInput = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }

        if sharingService.isViewing {
            Button("Disconnect Friend") {
                sharingService.stopViewing()
                friendCodeInput = ""
            }
            .accessibilityIdentifier("disconnectFriendShareCode")
        } else {
            Button("Connect") {
                guard friendCodeInput.count == 6 else { return }
                guard sharingService.canStartViewing(code: friendCodeInput) else { return }
                isFriendCodeFieldFocused = false
                if localWorkoutNeedsConfirmation {
                    pendingFriendCode = friendCodeInput
                    showJoinConfirmation = true
                } else {
                    joinFriend(friendCodeInput)
                }
            }
            .disabled(friendCodeInput.count != 6)
            .accessibilityIdentifier("connectFriendShareCode")
        }
    }

    private func joinFriend(_ code: String) {
        guard sharingService.canStartViewing(code: code) else { return }
        AppAnalytics.signal(.connectFriendsCode)
        if let onJoinFriend {
            onJoinFriend(code)
        } else {
            sharingService.startViewing(code: code, disconnectMonitor: bluetoothManager.disconnect)
        }
    }

    private func consumePendingJoinCode() {
        guard let code = sharingService.pendingJoinCode else { return }
        friendCodeInput = code
        isFriendSectionExpanded = true
        sharingService.pendingJoinCode = nil
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
                        .foregroundColor(.secondary)
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
