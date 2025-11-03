Editor's note: this app is 100% organic, grass-fed vibecode

## BPM

Minimalist, distraction-free heart rate display for iPad and iPhone (iPad-first design) that connects to Bluetooth LE heart rate straps (GATT Heart Rate Service 0x180D). Built with SwiftUI and CoreBluetooth.

### Features
- **Live BPM**: Large, high-contrast digits designed to be readable at a glance.
- **BLE device discovery**: Finds and connects to standard heart rate monitors.
- **Quick device picker**: Tap the antenna icon to select or switch devices.
- **On-screen stats**: Max and average over the last hour.
- **Workout-friendly**: Dark, landscape UI and idle timer disabled while active.

### Requirements
- **Xcode**: 16 or newer.
- **Devices**: Universal (iPad and iPhone). UI optimized for iPad landscape.
- **iOS**: Deployment target currently set to 18.5 (adjustable in project settings).
- **Hardware**: A real iPhone/iPad with Bluetooth LE (CoreBluetooth does not work in the simulator).
- **Heart rate strap**: Any BLE device that implements the Heart Rate Service (e.g., Polar H10, Wahoo TICKR, Garmin HRM, etc.).

### Getting Started
1. Clone the repo:
   ```bash
   git clone https://github.com/<your-org-or-user>/BPM.git
   cd BPM
   ```
2. Open the project in Xcode:
   - Open `BPM.xcodeproj`.
   - Select your signing team if prompted (Targets → BPM → Signing & Capabilities).
3. Connect a real device and select it as the run destination.
4. Build & Run (Cmd+R).

Notes:
- If your device is on iOS earlier than 18.5, lower the deployment target (Targets → BPM → General → iOS Deployment Target) to match your device, then rebuild.
- BLE requires a physical device; discovery/connection will not work in the simulator.
- App supports landscape orientation on both iPad and iPhone.

### Permissions
The app requests Bluetooth access on first launch to scan and connect to your heart rate monitor.
- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`

You can change permission later in iOS Settings → Privacy & Security → Bluetooth → BPM.

### Using the App
1. Put on and power your heart rate strap (so it starts advertising).
2. Launch the app.
3. Tap the antenna button to open the device picker and select your strap.
4. Your current BPM appears in large digits; Max and Avg (last hour) show at the bottom.

### Project Structure
- `BPMApp.swift`: App entry; manages app lifecycle and scanning start/stop.
- `ContentView.swift` (`HeartRateDisplayView`): Main UI, BPM digits and stats bar.
- `DevicePickerView.swift`: Scanning view and connect/disconnect actions.
- `HeartRateBluetoothManager.swift`: CoreBluetooth central, device discovery, connection, and HR parsing (8-bit and 16-bit per spec).
- `HeartRateSample.swift`: In-memory samples with timestamps for last-hour stats.
- `Info.plist`: Bluetooth usage descriptions and supported orientations (landscape).

### Testing
- Unit and UI test targets are included.
- In Xcode: Product → Test (or Cmd+U).

### Troubleshooting
- **No devices found**:
  - Ensure the strap is on your body (many devices only advertise when worn).
  - Move closer; BLE range is limited.
  - Toggle Bluetooth off/on, then rescan via the button.
  - Make sure the strap isn’t connected to another app/device.
- **Permission denied**: Go to iOS Settings → Privacy & Security → Bluetooth and allow access.
- **Build fails due to iOS version**: Lower the iOS Deployment Target in the target settings to match your device.

### Privacy
- No network calls; heart rate data stays on-device.
- Samples are held in-memory and trimmed to the last hour.

### Roadmap (ideas)
- Optional persistence of sessions and trends.
- HealthKit export/import.
- Complications/widgets and lock screen live activity.
- Background scanning and reconnect heuristics.

### Contributing
Issues and pull requests are welcome. For non-trivial changes, please open an issue first to discuss what you’d like to change.

### Acknowledgements
- Bluetooth SIG GATT Heart Rate Service Specification (UUID 0x180D / 0x2A37).


