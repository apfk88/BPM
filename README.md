Editor's note: this app is 100% organic, grass-fed vibecode

**Marketing site:** [https://bpmtracker.app](https://bpmtracker.app)

## BPM

Minimalist, distraction-free heart rate display for iPad and iPhone that connects to Bluetooth LE heart rate straps (GATT Heart Rate Service 0x180D). Built with SwiftUI and CoreBluetooth.

### Repository Structure

This repository contains three main components:

- **iOS App** (`BPM/`): The SwiftUI iOS application for iPhone and iPad
- **Static Marketing Site** (`backend/public/`): Landing page and privacy policy hosted on Vercel
- **Backend API** (`backend/pages/api/`): Next.js API routes for heart rate sharing functionality

The marketing site and backend are deployed together on Vercel, with the static files served from `backend/public/` and API routes at `/api/*`.

### Features
- **Live BPM**: Large, high-contrast digits designed to be readable at a glance.
- **HRV measurement**: Guided two-minute RMSSD test powered by native RR intervals from straps like the Polar H10.
- **BLE device discovery**: Finds and connects to standard heart rate monitors.
- **Quick device picker**: Tap the antenna icon to select or switch devices.
- **On-screen stats**: Max and average over the last hour.
- **Workout-friendly**: Dark, landscape UI and idle timer disabled while active.
- **Share your heart rate**: Generate a share code and let friends view your live BPM remotely.
- **View friend's heart rate**: Enter a friend's code to see their live heart rate updates.

### Requirements
- **Xcode**: 16 or newer.
- **Devices**: Universal (iPad and iPhone). UI optimized for iPad landscape.
- **iOS**: Deployment target set to 17.0 (adjustable in project settings).
- **Hardware**: A real iPhone/iPad with Bluetooth LE (CoreBluetooth does not work in the simulator).
- **Heart rate strap**: Any BLE device that implements the Heart Rate Service (e.g., Polar H10, Wahoo TICKR, Garmin HRM, etc.). HRV measurements require a strap that streams RR intervals (Polar H10 or equivalent).

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
- App requires iOS 17.0 or later. If you need to support earlier iOS versions, lower the deployment target (Targets → BPM → General → iOS Deployment Target) to match your device, then rebuild.
- BLE requires a physical device; discovery/connection will not work in the simulator.
- App supports landscape orientation on both iPad and iPhone.

### Permissions
The app requests Bluetooth access on first launch to scan and connect to your heart rate monitor.
- `NSBluetoothAlwaysUsageDescription`

You can change permission later in iOS Settings → Privacy & Security → Bluetooth → BPM.

### Using the App

**My Device Mode:**
1. Put on and power your heart rate strap (so it starts advertising).
2. Launch the app (defaults to "My Device" mode).
3. Tap the antenna button to open the device picker and select your strap.
4. Your current BPM appears in large digits; Max and Avg (last hour) show at the bottom.
5. Optionally tap "Start Sharing" to generate a share code for friends to view your heart rate.

**Friend's Code Mode:**
1. Tap "Friend's Code" at the top of the screen.
2. Enter the 6-character share code provided by a friend.
3. View their live heart rate updates (updates every second).

**HRV Measurement:**
1. Connect a strap that streams RR intervals (Polar H10 or similar) in My Device mode.
2. From the main screen, tap the HRV button to open the measurement view.
3. Stay relaxed and still while the two-minute countdown runs (keep the app in the foreground).
4. When finished you'll hear haptic/audio feedback and see your RMSSD value along with session stats.

### Project Structure
- `BPMApp.swift`: App entry; manages app lifecycle and scanning start/stop.
- `ContentView.swift` (`HeartRateDisplayView`): Main UI, BPM digits, stats bar, and sharing controls.
- `DevicePickerView.swift`: Scanning view and connect/disconnect actions.
- `HeartRateBluetoothManager.swift`: CoreBluetooth central, device discovery, connection, and HR parsing (8-bit and 16-bit per spec).
- `HeartRateSample.swift`: In-memory samples with timestamps for last-hour stats.
- `SharingService.swift`: API client for sharing heart rate data via backend service.
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

### Sharing Setup

The app uses a backend service to share heart rate data. To enable sharing:

1. **Deploy the backend** (see `backend/README.md`):
   - The backend is a Next.js app using Vercel KV (Upstash Redis).
   - Deploy to Vercel and set up environment variables (`KV_REST_API_URL`, `KV_REST_API_TOKEN`).
   - See `backend/README.md` for detailed setup instructions.

2. **Configure the app**:
   - Set the API base URL in the app by adding a UserDefaults key `BPM_API_BASE_URL` with your Vercel deployment URL.
   - Or modify `SharingService.swift` directly to change the default base URL.

3. **Start sharing**:
   - In "My Device" mode, tap "Start Sharing" to generate a 6-character code.
   - Share this code with friends who can enter it in "Friend's Code" mode.

**Note**: Heart rate updates are sent to the backend at 1 Hz (once per second) when sharing is enabled.

### Privacy
- When sharing is disabled, no network calls are made; heart rate data stays on-device.
- When sharing is enabled, heart rate data is sent to your backend service (requires your own deployment).
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


