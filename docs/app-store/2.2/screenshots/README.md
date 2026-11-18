# BPM 2.2 screenshots

Captured November 9, 2026 from the current SwiftUI app. Images are native simulator captures exported as RGB PNGs, with no retouched controls, composed UI, or generated imagery. Their fully opaque alpha channels were removed losslessly for App Store acceptance; every RGB pixel was preserved. No real user health data is included.

## Capture source

- Base commit: `9e37a67`, plus the current unreleased working-tree sharing changes.
- Capture app: Debug version `2.2`, build `23`, compiled before the release build-number increment to `24`. The release app source was unchanged by screenshot work.
- iPhone: iPhone 18 Pro Max, iOS 27.0, **1320 × 2868** portrait.
- iPad: iPad Pro 13-inch (M5), iPadOS 27.0, **2064 × 2752** portrait.
- Standard text size and dark appearance. Calorie-profile fixture completed so no setup-warning badge appears. Status bar set to 9:41 and 100% battery where the app displays it.
- Simulator UI was inspected after navigation. Full-resolution files were exported with `xcrun simctl io <device> screenshot`; the MCP screenshot helper's reduced JPEG output was not used as release artwork.

## Recommended iPhone App Store order

| Order | File | Screen |
| --- | --- | --- |
| 1 | `iphone-6.9/01-live-bpm.png` | Live BPM, zone, session statistics and active-workout indicator |
| 2 | `iphone-6.9/07-workout-stats.png` | Workout statistics grid, interval controls and calories |
| 3 | `iphone-6.9/03-shared-workout.png` | Shared workout with remote trainer controls and viewer badge |
| 4 | `iphone-6.9/08-hrv-result.png` | Completed shared HRV result in large type |
| 5 | `iphone-6.9/05-share-card.png` | Workout chart-card sharing drawer |
| 6 | `iphone-6.9/06-presets.png` | Norwegian 4x4 and HIIT interval presets |

Additional captures: `02-workout-table.png` shows local work/rest rows; `04-hrv.png` shows a saved HRV session and its export controls.

App Store Connect accepted this six-image order for version 2.2 (24). The presets image was uploaded as an RGB JPEG at the same resolution after its initial upload stalled; the upload file is retained at `build/release-appstore-24/06-presets.jpg`. The five other iPhone images and all five iPad images were uploaded as the listed PNGs. Smaller display sizes inherit these assets.

## iPad inventory

| Order | File | Screen |
| --- | --- | --- |
| 1 | `ipad-13/01-live-bpm.png` | Live heart rate and session statistics |
| 2 | `ipad-13/03-workout-stats.png` | Workout statistics grid |
| 3 | `ipad-13/02-workout-table.png` | Work/rest table |
| 4 | `ipad-13/04-workout-chart.png` | Paused workout chart and time in zones, captured without a live simulator tail |
| 5 | `ipad-13/05-hrv-result.png` | Large shared HRV result, 46 ms |

All five iPad images were visually inspected. The same synthetic workout/profile and shared-HRV fixtures were used; no real user data was present.

## Marketing mapping

| Website selector | Source |
| --- | --- |
| Live | `iphone-6.9/01-live-bpm.png` |
| Workout | `iphone-6.9/07-workout-stats.png` |
| HRV | `iphone-6.9/08-hrv-result.png` |
| Stream | `iphone-6.9/03-shared-workout.png` |
| Share | `iphone-6.9/05-share-card.png` |
| Presets | `iphone-6.9/06-presets.png` |

## Fixture provenance

Live heart rate uses the app's built-in simulator monitor. The populated local workout is a synthetic 24-minute session loaded through the existing persisted-session format, then resumed and operated through the app. Its calories use a synthetic completed profile. Shared-workout screenshots use a local synthetic broadcaster implementing the same snapshot schema as the existing UI tests, with no production sharing session created.

A full two-minute HRV measurement completed in the simulator with a 46 ms RMSSD result, average 58 BPM, minimum 40, and maximum 70. The session was saved through the app for `04-hrv.png`. `08-hrv-result.png` displays those same values through a local shared-HRV fixture so the large result screen can be captured cleanly. These values demonstrate the interface, not physical-sensor accuracy or a real person's physiology.

The chart-card screenshot uses the existing `--workout-share-ui-test` preview fixture: Morning intervals, 42 minutes, average 135 BPM and maximum 167 BPM. Presets are the app's shipped defaults.

## Verification boundary

Every iPhone image was opened and visually checked for clipping, stale overlays, and setup warnings. Screenshot generation verifies rendered UI; physical Bluetooth accuracy and background-device behavior are separate release checks. Asset files alone do not establish that App Store Connect accepted them or that the marketing deployment is live; those states are recorded in the release report.

Format requirements checked against [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/). The final PNG inventory and SHA-256 checksums are recorded in the release verification manifest.
