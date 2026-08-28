# BPM Privacy Policy

**Effective date: August 28, 2026**

BPM is a minimalist heart rate display app. We respect your privacy and are committed to protecting it. This policy explains what data we handle and why.

## Summary

- We do not collect personal information.
- Heart rate data stays on your device unless you explicitly choose to share it.
- If you enable sharing, your heart rate is sent to your own backend and retained briefly so others with your code can view it.
- We collect limited, non-personal app usage and device information through TelemetryDeck to understand app reliability and usage.

## Data We Handle

### Heart Rate (BPM), Max, and Average (last hour)

- **Source**: Your Bluetooth LE heart rate strap via CoreBluetooth.
- **On-device use**: Display and simple stats.
- **Optional sharing**: When you enable sharing, BPM/max/avg and a timestamp are sent to your backend service and associated only with a random 6-character code and a session token.

## Sharing and Retention

- **When sharing is ON**:
  - Data is transmitted over HTTPS to your backend (by default a Vercel deployment using KV/Upstash).
  - Share sessions expire automatically after 90 minutes.
- **When sharing is OFF**:
  - No heart rate data is transmitted off-device.

## Analytics

- TelemetryDeck receives app launch and session activity, app version, device type, operating system, and a non-personal device identifier for analytics.
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
