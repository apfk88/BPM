# BPM 2.0.12 (13)

## Changes

- Adopt native Liquid Glass controls and modern navigation, with compatible controls on older iOS versions.
- Improve large text, VoiceOver labels, touch targets, and friend-code entry.
- Fix narrow-screen HRV clipping and let expanded workout charts adapt to portrait and landscape.
- Return Home after saving a workout, with save confirmation and HealthKit sync status preserved.
- Remove the deprecated full-screen requirement so iPad layouts can adapt to available space.

## Validation

- 88 unit tests passed, including measurement, HRV, timing, and saved-workout coverage.
- All three UI tests passed on iPhone and iPad with iOS 27: workout rotation, accessibility text and navigation, and save/cancel with adaptive charts.
- Release compilation passed. Signed archive and upload are verified separately during release.
- Bluetooth UI flows used simulated heart-rate data; physical Bluetooth hardware was not retested.

## Release notes

Updated controls and navigation for the latest iOS design. Improved large-text support, device setup, and chart rotation. Fixed HRV layout clipping and return to Home after saving a workout.
