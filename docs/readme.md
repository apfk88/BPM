# BPM Privacy Policy

**Effective date: November 6, 2025**

BPM is a minimalist heart rate display app. We respect your privacy and are committed to protecting it. This policy explains what data we handle and why.

## Summary

- We do not collect personal information.
- Heart rate data stays on your device unless you explicitly choose to share it.
- If you enable sharing, your heart rate is sent to your own backend and retained briefly so others with your code can view it.

## Data We Handle

### Heart Rate (BPM), Max, and Average (last hour)

- **Source**: Your Bluetooth LE heart rate strap via CoreBluetooth.
- **On-device use**: Display and simple stats.
- **Optional sharing**: When you enable sharing, BPM/max/avg and a timestamp are sent to your backend service and associated only with a random 6-character code and a session token.

## Sharing and Retention

- **When sharing is ON**:
  - Data is transmitted over HTTPS to your backend (by default a Vercel deployment using KV/Upstash).
  - The backend stores the latest values for up to 24 hours to allow real-time viewing by someone who knows your code.
- **When sharing is OFF**:
  - No heart rate data is transmitted off-device.
  - The app does not upload analytics.

## Identifiers and Tracking

- We do not use advertising identifiers and do not track users.
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

For questions or requests about this privacy policy, please contact: support@yourdomain.com

_(Note: Replace support@yourdomain.com with your actual support email address before publishing)_

