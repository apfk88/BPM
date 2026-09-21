# BPM 2.0.11 (12)

## Changes

- Fix overlapping heart rate and elapsed time on the Lock Screen and an oversized Dynamic Island during workouts.
- Give the system-rendered timer an explicit width, with room for hours and consistent alignment when paused. Keep background counting and preset/cooldown end dates intact.
- Include the existing landscape layouts and measurement reliability work from the working tree. The measurement changes were already included in App Store version 2.0.10 (11), but had not been committed.

## Cause

Version 2.0.10 replaced a static duration label with `Text(timerInterval:countsDown:)`. In widgets this text is horizontally flexible. Without a width, it expanded the compact island and gave the fixed-size statistics row an invalid ideal layout. Apple documents this behavior and recommends an explicit frame: [timer text documentation](https://developer.apple.com/documentation/swiftui/text/init(timerinterval:pausetime:countsdown:showshours:)).

## Validation

- Confirmed App Store Connect serves 2.0.10 (11), released September 15, 2026.
- Reproduced the original oversized island and overlapping Lock Screen layout on iPhone 17 Pro Simulator, iOS 26.4.1.
- Verified the corrected Lock Screen with a three-digit BPM, zone, and running timer over an hour; verified the compact island through the normal simulated-device workout flow.
- 89 tests passed: 88 unit tests and the landscape workout UI test, with no failures or skipped tests.
- Signed Release archive succeeded; app and Live Activity extension both report 2.0.11 (12), and code-signature verification passed.
- Simulator verification covers rendering and app behavior. Physical Bluetooth delivery was not tested in this change.

## Release notes

Fixed overlapping heart rate and workout time in Live Activities on the Lock Screen, and corrected the Dynamic Island layout. Improved landscape layouts for workouts and HRV.
