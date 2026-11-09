# BPM Privacy Policy

**Effective date: November 4, 2026**

BPM is a minimalist heart rate display app. We respect your privacy and are committed to protecting it. This policy explains what data we handle and why.

## Summary

- We do not collect personal information.
- Heart rate data stays on your device unless you explicitly choose to share it.
- If you enable sharing, live heart rate and workout data are sent to the sharing backend so people with your code can view the session and request Work and Rest sets.
- We collect limited, non-personal app usage and device information through TelemetryDeck to understand app reliability and usage.

## Data We Handle

### Heart Rate (BPM), Max, and Average (last hour)

- **Source**: Your Bluetooth LE heart rate strap via CoreBluetooth.
- **On-device use**: Display and simple stats.
- **Optional sharing**: Live BPM and summaries, workout timers, set durations, heart-rate charts, time in zones, estimated total calories, and workout state are associated with a random 6-digit code and a private broadcaster token. Work/Rest requests include a random request ID and the current workout revision so duplicate or outdated requests can be rejected. Workout titles, notes, and profile inputs are not included in live sharing.

## Sharing and Retention

- **When sharing is ON**:
  - Data is transmitted over HTTPS to your backend (by default a Vercel deployment using KV/Upstash).
  - Share sessions expire automatically after 90 minutes.
  - Anyone with the code can view the shared session and request Work and Rest sets. Only the broadcaster can start, pause, end, reset, or save the workout.
  - Workout snapshots and control records expire with the session and are removed when sharing is stopped successfully on the backend.
- **When sharing is OFF**:
  - No heart rate data is transmitted off-device.

## Analytics

- TelemetryDeck receives app launch and session activity, feature and screen usage, settings choices, app version, device type, operating system, and a non-personal device identifier for analytics. Feature usage includes sharing outcomes, streaming, sounds, HRV measurement outcomes, history visits, presets, and AI voice actions. For calorie settings, analytics record which fields were edited and whether fields are filled, empty, invalid, or using a default, never the values entered. Reliability events include fixed failure categories and recognized heart-rate sensor brands/models, protocol capabilities, and connection outcomes. Raw Bluetooth names, sensor identifiers, serial numbers, and heart-rate or beat-interval values are not included.
- Analytics never include heart rate data, workout details, share codes, or other health information.
- Analytics data is not linked to your identity and is not used for advertising or cross-app tracking.

## Identifiers and Tracking

- We do not use advertising identifiers or track users across apps or websites.
- The share code and token are random and not linked to your identity.
- Standard web server/host logs (e.g., IP address) may be recorded by your hosting provider (e.g., Vercel) for security/operations.

## Device Permissions

- **Bluetooth**: Used to discover and connect to your heart rate strap.

## Security

- Data in transit uses HTTPS.
- The backend stores minimal, ephemeral data required to provide sharing functionality.

## Your Choices

- Do not enable sharing if you don't want any data transmitted.
- You can stop sharing at any time in the app.

## Contact

For questions or requests about this privacy policy, please contact: vibecodeinc@proton.me
