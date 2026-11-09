# BPM 2.2 TestFlight

App `6754830191`, bundle `kvamme.BPM`.

## Unreleased local follow-up, November 6

- Opening or returning to BPM now shows the active local or shared workout, including paused sessions and cooldowns. Shared sessions wait for a fresh snapshot, retain their selected page on a warm return, and start on the table after a cold launch. Idle sessions remain on Home at launch.
- HRV history rows emphasize the result, with compact date/time and quieter heart-rate details. Connect is a full-width prominent button with a disabled state until the code has six digits. Both layouts were checked at normal and maximum accessibility text size.
- These changes are local and are not included in the released build 23 archive.
- Verification: build passed, and 11 distinct UI checks passed across final runs. The two local reopening tests passed in `build/active-workout-routing-final.xcresult`; the two shared reopening/stale-data tests passed in `build/active-workout-routing-freshness.xcresult`. Seven shared navigation/control regressions passed in the initial `build/active-workout-routing.xcresult` run. Initial test assertions were corrected for the existing workout Settings button and the five-second freshness window. The previously documented SwiftUI publication warning remains.

## Released build: 2.2 (23)

Prepared November 5, 2026. Released November 6. **Testing in the internal Dev group.**

- Successful friend connections dismiss Device. Shared workout entry starts on the table page; ongoing viewer navigation stays independent. Cold launches still open Home.
- Host/viewer controls use the same sizes in both orientations. The full-width preset row has a trailing X, available before the workout starts regardless of who loaded the preset. Viewer timers use whole seconds.
- HRV starts on the owner's device from either side. Viewers mirror its countdown, result, and errors, without a separate calculation, Save action, or “Shared HRV” heading. Remote cancellation waits for confirmation; leaving the screen can keep measurement running.
- Fixed the simulated monitor's incomplete beat coverage. A full 120-second simulator measurement passed and published its result. The real-monitor quality checks are unchanged.
- Signed archive: `build/BPM-2.2-23.xcarchive`. Both targets are 2.2 (23); code signing, matching dSYMs, production API URL, Universal Links entitlement, and source hashes were verified. Evidence is in `build/release-testflight-23/`.
- Backend released to https://bpmtracker.app on November 6: `dpl_JDsCQCikYRopF99wwBCg2khJKyHd`, production `READY`. All 29 backend tests passed; 20 API checks passed on both the staged production build and live domain. An existing synthetic legacy session survived promotion and accepted another heartbeat. All synthetic sessions were deleted and verified unavailable.
- The user approved production deployment and TestFlight upload on November 6, conditional on compatibility. Production source was compared against the previous deployment: only shared HRV runtime support changed. The prior website, privacy page, workout-recap behavior, and Universal Link configuration were preserved. The post-deployment error scan found zero error logs. Release manifests and verification logs are in `build/shared-hrv-validation/`.
- App verification: 66 focused unit tests and 20 distinct UI tests passed across final runs, including the full 120-second HRV integration. Final portrait and landscape screenshots were reviewed for both host and viewer; matching control sizes and the trailing preset-clear action were verified. See [sharing validation](../../live-workout-sharing.md).
- Upload succeeded November 6 after the user refreshed Xcode’s Apple Account sign-in. Apple processing completed, and the Dev group’s Builds table verified **2.2 (23): Testing**, expiring in 90 days. Build ID: `11e88d9a-50e9-40a3-aba2-5a998636c23c`. [Open build in App Store Connect](https://appstoreconnect.apple.com/apps/6754830191/testflight/ios/11e88d9a-50e9-40a3-aba2-5a998636c23c). Upload log: `build/release-testflight-23/upload-final.log`.

## Build 22 history

Uploaded November 5, 2026 at 2:35 PM PST. **Testing in the internal Dev group.**

- Compact calorie settings below frequent settings, visible optional fields, concise explanation, Apple Health review/autofill, first-use setup reminders, and the updated support email.
- Cold launches open Home while restoring the workout. Sustained new local max HR produces a Settings badge and explicit update choice; custom zone boundaries are preserved.
- Includes the zone-storage recursion crash fix. Adds HRV readiness gating, categorized recoverable failures, and recognized sensor model/capability telemetry. See [reliability monitoring](../../reliability-monitoring.md) for the live analytics review and saved dashboard.
- Validation updated after local review: 371 unit tests and 25 distinct UI tests passed across final runs. Debug simulator and unsigned device-target Release builds passed. Settings and calorie screens were visually checked. See [local follow-up review](../../reliability-monitoring.md#local-follow-up-review-november-5-2026) for result bundles, fixes, and remaining runtime warnings. Physical HRM validation remains outstanding.
- Final UI adjustments use “Calories” in workout/shared stats, history, and text summaries, and add space below the HRV top controls. All 20 focused share/rotation tests passed after these changes; portrait and landscape screenshots were reviewed.
- The earlier cache/signing restriction was resolved with approved execution using macOS signing access. Signed archive: `build/BPM-2.2-22.xcarchive`. Both targets are 2.2 (22), both dSYMs match their binaries, the signature is valid, the production API URL is correct, and the Universal Links entitlement is present.
- App source/resource hashes match `build/release-testflight-22/source-manifest.json`. Validation, screenshots, and archive/upload logs are in `build/release-testflight-22/`.
- Upload finished successfully at 2:35:44 PM PST with symbols enabled. Apple processing completed; the internal Dev group's Builds table confirms **Testing**, expiring in 90 days. Build ID: `42b5e969-2b66-4940-8d4e-218c00a18fea`. [Open build in App Store Connect](https://appstoreconnect.apple.com/teams/69a6de7d-8909-47e3-e053-5b8c7c11a4d1/apps/6754830191/testflight/ios/42b5e969-2b66-4940-8d4e-218c00a18fea).

## Building the current working tree

From the repository root, run:

```sh
./scripts/testflight.sh
```

The script reads the current version/build from the project, verifies matching
target versions, archives the current working tree using Xcode's signed-in
account, checks the app and extension dSYMs, and uploads with symbols enabled.
It does not increment the build number or submit for public App Review. Use an
unused build number and finish the release checks in
[reliability monitoring](../../reliability-monitoring.md) first.

Archives are written to `build/BPM-<version>-<build>.xcarchive`; export options and
archive/upload logs are in `build/release-testflight-<build>/`. The environment
must allow Xcode's package-cache and signing access. A successful upload still
requires checking Apple processing and TestFlight availability separately.

## Build 20 history

- Includes live workout trainer controls, shared unsavable HRV, the consolidated Device menu, green sharing indicators, invitation links, connection lifecycle fixes, and the zone-settings recursion fix.
- Validation before archive: 72 focused unit tests and 10 UI tests passed across final runs; 25 backend tests passed; staged/live API checks and running-app trainer flows passed. Physical-device validation remains outstanding.
- Signed archive: `build/BPM-2.2-20.xcarchive`. App and Live Activity extension both verified as 2.2 (20); app API base URL verified as `https://bpmtracker.app`.
- Source hashes: ignored `build/release-testflight-20/source-manifest.json`.
- Upload succeeded November 4 at 9:16 AM PST. Log: `/private/tmp/BPM-2.2-20-Upload.log`.
- Initial 2.1.1 archive upload was rejected because that approved version's train is closed. The accepted upload uses 2.2, retaining build 20.
- Existing internal Dev group has automatic distribution for Xcode builds. Apple processing completed; build `8b5adcb9-1e1e-4fd6-ab6c-6c4c67bee8c3` was verified **Testing**, expiring in 90 days, in the existing Dev group with one tester.
- This request does not submit the app for public App Review.

## Universal Links update: 2.2 (21)

Prepared November 4, 2026.

- HTTPS share invites open BPM directly and connect automatically. Existing local workouts still require confirmation before being cleared. Invalid/expired-code errors remain visible in Device. The `bpm://` fallback also joins automatically.
- Added Associated Domains entitlement for `applinks:bpmtracker.app`; signed archive verified with application identifier `5HW85B6746.kvamme.BPM` and that entitlement.
- Published invite-only AASA configuration at `https://bpmtracker.app/.well-known/apple-app-site-association`. Verified HTTPS 200, JSON MIME, no redirect, and identical configuration from Apple's associated-domain CDN. Deployment: `dpl_1ZBwMSSqk2B6GZ4cX5xvqCLYS7pL`.
- Five lifecycle unit tests and three UI regressions passed across final runs, including real OS HTTPS routing, cold-launch URL delivery, automatic monitor disconnection, active-workout confirmation/Cancel, and manual invalid-code retry. See `docs/live-workout-sharing.md` for result bundles.
- Signed archive: `build/BPM-2.2-21.xcarchive`; app and activity extension use 2.2 (21). Source hashes: ignored `build/release-testflight-21/source-manifest.json`.
- Upload succeeded November 4 at 10:48 AM PST. Log: `/private/tmp/BPM-2.2-21-Upload.log`. Apple processing completed. Build `dac7070f-2a6b-4ddd-b476-30c71db24394` was verified **Testing**, expiring in 90 days, in the existing internal Dev group with one tester.
