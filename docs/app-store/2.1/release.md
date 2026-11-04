# BPM 2.1 (18)

Prepared October 28, 2026 for App Store Connect app `6754830191`, bundle `kvamme.BPM`.

## Release scope

- Redesigned workout history and details with the same surfaces, typography, chart, and prominent statistics as share cards.
- White-default share cards with red, orange, yellow, green, blue, indigo, and violet accents. The scrolling selector is in the full card editor.
- Bundled threshold, spoken-zone, work/rest, and HRV-completion sounds with shared playback and event routing.
- Refined Live Activities, workout-save confirmation, and AI voice disclosure.
- Expanded fixed-label feature analytics for configuration, sounds, sharing, streaming, HRV, and navigation.

The release uses the current working tree, including the existing changes from parallel BPM work. No Git commit or push was requested. Production source hashes are recorded in ignored `build/release-2.1/source-manifest.json`.

## Validation and distribution

- Backend: eight tests passed; production build passed.
- Full iOS suite: 182 passed, one share-gallery failure. The failure reproduced when XCTest interpreted the slider's time-formatted accessibility value as a percentage. That test now drags the end thumb directly and passed its complete chart/stats/text/JSON export flow on rerun. No production changes were required; all 183 distinct tests are covered with no unresolved failures.
- Full result: `/Users/kvamme/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/result-bundles/test_sim_2026-10-28T17-35-22-944Z_pid9328_36cf6e0b.xcresult`. Passing rerun: `/Users/kvamme/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/result-bundles/test_sim_2026-10-28T17-45-42-804Z_pid9328_c0b2fb81.xcresult`.
- Signed Release archive succeeded: `build/BPM-2.1-18.xcarchive`. Verified app and activity extension as 2.1 (18), production API URL, all ten sound assets, and the privacy manifest. Production hashes still match the release snapshot.
- Upload succeeded October 28 at 10:48 AM PDT; log `/tmp/BPM-2.1-18-Upload.log`. Apple processing completed; build ID `5ef7dfd4-d955-484f-939b-40fb4a50b038` is Ready to Submit.
- App Store version 2.1 (18): submitted October 28 at 10:54 AM PDT and verified **Waiting for Review**. Existing automatic release after approval is retained. Submission ID: `c0a28774-a45d-4c19-b4be-b9c717ac99d7`.
- Review page: https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/c0a28774-a45d-4c19-b4be-b9c717ac99d7
- TestFlight: verified **Testing**, expiring in 90 days, in the existing internal Dev group with one tester. What to Test notes were saved. External distribution was not changed.
- TestFlight group: https://appstoreconnect.apple.com/teams/69a6de7d-8909-47e3-e053-5b8c7c11a4d1/apps/6754830191/testflight/groups/47981ab6-6b68-4b0e-bf8e-1b1e05f76344/builds
- Proof screenshots: ignored `build/release-2.1/app-review-waiting.png` and `build/release-2.1/testflight-testing.png`. Exact test summaries: `build/release-2.1/validation-summary.json`.
- Validation covers Simulator and backend checks. Physical BLE, locked-phone audio, and microphone routing were not retested by this release action.

After archiving, a parallel task added opt-in analytics uploads for Debug builds. Its Release path remains enabled with the same behavior. The archived `AppAnalytics.swift` was recovered and matched to the release hash, then compared with that later edit; the archived source is retained in ignored `build/release-2.1/AppAnalytics-archived.swift`. No production file was changed by the slider-test correction.

## What's New

• Redesigned workout history with clearer charts, statistics, zones, and sets.
• Customize workout share cards with white or a full rainbow of accent colors.
• New heart-rate tones, spoken zone alerts, interval bells, and an HRV completion sound.
• Refined Live Activities and a smoother workout-save flow.
• Clearer AI voice controls and privacy explanations.

## App Review Notes

BPM 2.1 (18) redesigns saved workout history and share-card editing, adds bundled sound cues, and refines Live Activities and the workout-save flow. No sign-in is required.

This app requires a physical Bluetooth Low Energy heart-rate monitor supporting the standard GATT Heart Rate Service (UUID 0x180D). Wear or activate the monitor, grant Bluetooth permission, tap the heart icon, and select the device. Without a connected monitor, BPM displays "---". RR intervals from a compatible monitor, such as Polar H10, are required for HRV.

To review workout history and sharing: start and end a workout, choose a workout type, enter a title or description, and save. A save confirmation returns to the main screen. Open Workout History, tap a saved workout, and use the share button. Chart and Stats card editors offer a temporary title, time range, and scrolling accent-color selector. These card edits do not overwrite saved workout details. Plain Text and Logs use the native share sheet; Logs attaches a JSON file. Save Image requests add-only photo-library permission. Tap the history chart to expand, zoom, and inspect it.

Audio cues are bundled on device. In Settings, enable BPM Alert and choose a threshold for ascending/descending cues, or enable Zone Alert and select zones for spoken zone announcements. Workout Presets have a Play Sound toggle for work/rest/cooldown and completion bells. A successful two-minute HRV measurement also plays a completion sound. UIBackgroundModes retains audio for these intermittent workout cues and bluetooth-central for monitor communication. These are intermittent alerts, not continuous music. AI voice recording stops when the app enters the background. No physical-device background-audio video is attached.

AI voice is optional. In Save Workout, tap AI voice, grant microphone permission, record up to 60 seconds, and tap Send. The first-use "Send recording?" prompt names OpenAI and explains that the recording, including any spoken health details, is sent for AI transcription and workout notes. "Allow & Send" permits the upload; Cancel keeps it local. Review and correct the generated title and description before saving. Manual entry works without AI permission. Reset AI voice permission in Settings to test consent again.

Only the recording is sent to BPM's backend and OpenAI. Measured heart rate, HealthKit records, and workout history are not attached. Model-improvement sharing is disabled. Audio is processed transiently; transcript/result safety logs may be retained for up to 30 days, with legal or safety exceptions. The app links to https://bpmtracker.app/privacy.html#ai-voice before upload.

HRV is RMSSD in milliseconds. Remain still for the full two-minute recording. Invalid, disconnected, or incomplete recordings are rejected. BPM does not diagnose or treat medical conditions. Existing privacy disclosures and review contact details are retained.
