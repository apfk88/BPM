# BPM 2.0.13 (16)

Prepared October 26, 2026 for App Store Connect app 6754830191, bundle `kvamme.BPM`.

## Review follow-up, October 26

- Apple rejected build 16 at 3:15 PM PDT under Guideline 2.5.4 because `UIBackgroundModes` declares `audio` and the reviewer could not locate a feature requiring persistent background audio.
- The audio declaration dates to the February 4 background-alerts change (`1143624`). Current code plays heart-rate/zone tones and interval bells; AI recording stops on background entry. Removing audio without physical-device checks could affect background alerts.
- Apple explicitly offered to approve the bug-fix update now and allow this issue to be addressed in the next update, without resubmitting.
- With the user's explicit approval, sent this reply at 4:29 PM PDT: “This update includes workout recovery, timer, and layout fixes. Please proceed with approval under the bug-fix option described in your message. We will address the background-audio issue in our next update.”
- Verified the posted reply in Messages (2). Status still **Rejected / Unresolved Issues**, awaiting Apple's decision. No new binary or resubmission was made.
- Before the next update, resolve the background-audio requirement. Apple's alternatives are physical-device video evidence of qualifying background audio, or removal of the audio mode. Validate locked-phone heart-rate and interval alerts before changing it.
- Proof: ignored `build/privacy-release-proof/build-16-bugfix-request-sent.jpg`.

## Build 16 sharing analytics

Build 16 adds TelemetryDeck instrumentation for workout and HRV sharing. It covers picker opens, format selection, export requests, sheet presentation, completion, cancellation, and failure. Events contain fixed source/format labels only. See [sharing analytics](../../sharing-analytics.md) for the event contract and completion semantics. Existing live-sharing signals and SDK privacy behavior are unchanged.

- Archive and upload succeeded; bundled version is 2.0.13 (16).
- Archive: `build/BPM-2.0.13-16.xcarchive`; upload log: `/private/tmp/BPM-Release16-Upload.log`.
- The broader test run passed 142 tests, with zero failures/skips: `/private/tmp/BPM-Release16-Tests.xcresult`.
- After the final native-sheet teardown refinement, all eight focused tests passed: seven analytics tests and the native chart/stats/text/JSON export UI test. Result: `/private/tmp/BPM-Release16-FinalShareTests.xcresult`. Source hashes match the archived build.
- Apple processing completed. Build ID: `096b4424-d243-4449-b500-bdbfce883a1f`. Build 16 replaced build 15 in the saved version, verified after reload.
- Code and analytics documentation were committed and pushed as `55cc4e5`.
- Submitted October 26, 2026 at 1:41 PM PDT. App Store Connect confirmed **Waiting for Review** for **2.0.13 (16)**. Existing automatic release after approval is retained.
- Submission ID: `73866250-6c2e-4964-af23-11ce16a4d123`. Review page: https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/73866250-6c2e-4964-af23-11ce16a4d123
- Internal Dev group has build 16 in **Testing** status, with one existing tester. What to Test notes were saved. External TestFlight distribution was explicitly declined and not changed.
- Proof: ignored `build/privacy-release-proof/build-16-waiting-review.jpg` and `build/privacy-release-proof/build-16-testflight.jpg`.
- TelemetryDeck Test Mode received build-16 picker, selection, requested, presented, and completed events. Inspected a completed stats-card export: `format=stats_card`, `source=workout_detail`, version 2.0.13, build 16, simulator/debug/test mode. Production ingestion awaits real use. Proof: ignored `build/privacy-release-proof/build-16-telemetry-test-event.jpg`.

## Earlier build 15 state

Build 15 supersedes the previously uploaded build 14 and includes all current workout recovery, share-card, chart, layout, and AI voice changes. The user authorized committing/pushing all changes and submitting this new build for review on October 26, 2026.

- Version 2.0.13 already exists in App Store Connect; release notes and reviewer instructions updated for the full change set.
- Paid Apps Agreement is now Active with an effective date of October 26, 2026, verified in App Store Connect. No agreement was accepted by the agent.
- Membership expiry remains November 3, 2026 GMT; automatic renewal has not been verified.
- Build 15 archived and uploaded successfully; Apple completed processing. Build ID: `ee2838f6-fd9f-4b0f-b5d0-b68095cd667b`.
- Build 15 replaced build 14 in the saved version draft. Existing automatic release after approval is retained.
- All 140 iOS tests passed with zero failures/skips, including seven affected UI tests; all eight backend tests and production build passed.
- Source hashes were checked against the validated/archived snapshot before commit. Secrets and generated build artifacts remain ignored.
- All 53 changed files were committed and pushed to `origin/master` as `e74f10b354dbea6fb2faa8925dc5914616b5c012`.
- App Store Connect required new Social Media and Social Media Disabled for Users Under 13 age-rating answers. Both are No: BPM has no social feed and does not implement the Declared Age Range API. Existing Health or Wellness Topics = Yes and other existing content responses were preserved; calculated rating remains 9+ with regional exceptions.
- Submitted October 26, 2026 at 12:59 PM PDT. App Store Connect confirmed **Waiting for Review** for **2.0.13 (15)**.
- Submission ID: `1593f402-d8d8-4950-a23c-5b32ec301984`.
- Review page: https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/1593f402-d8d8-4950-a23c-5b32ec301984
- Screenshot: ignored `build/privacy-release-proof/build-15-waiting-review.jpg`.

## Privacy configuration

OpenAI API input/output sharing was disabled and verified after reload. Feedback and evaluation sharing were also disabled. The existing BPM project and key remain in use; normal API charges apply.

The app asks for explicit permission before the first AI upload. Cancel retains the recording locally. Settings resets this device-local consent; it is excluded from iCloud preference synchronization. The microphone purpose string states 60 seconds.

App Store Connect published Health, Fitness, and Other User Content for App Functionality, linked to identity, with no tracking. Freeform transcript content can identify a person and is not de-identified before processing. Existing Device ID and Product Interaction analytics disclosures remain unchanged. The app privacy manifest includes the three new types, in addition to the bundled analytics SDK manifest.

Raw audio is processed transiently and is not declared as collected Audio Data because the configured transcription endpoint documents no retained application state or abuse-monitoring content. Transcript and generated text may be retained in Responses abuse logs for up to 30 days, with legal or safety exceptions. `store: false` does not disable those logs. Reassess the labels if the provider, endpoint, retention, or training configuration changes.

The updated policy is live at https://bpmtracker.app/privacy.html, verified HTTP 200 and byte-identical to the local source. Deployment: `dpl_4v2GF94xH7NFW63CnbtnjcB7pEto`. User Privacy Choices URL is saved for the new version as https://bpmtracker.app/privacy.html#privacy-choices.

## Build 15 verification

- `xcodebuild test`: 140 passed, 0 failed, 0 skipped. Result: `/private/tmp/BPM-Release15-Tests.xcresult`.
- Coverage includes workout start/end recovery, persistence and iCloud merging, chart ranges, sharing selection/export, AI consent/recording, timer behavior, landscape, accessibility text, and saved-workout editing.
- The seven UI tests passed. AI generation uses the DEBUG/simulator fixture; physical BLE and microphone routing remain outside simulator coverage.
- Xcode stalled in optional `simctl diagnose` after the test runners exited. That diagnostics process was terminated, after which xcodebuild exited 0 with `TEST SUCCEEDED`; the finalized result bundle reports all 140 passing tests.
- Backend: eight tests passed; `npm run build` passed.
- Archive: `build/BPM-2.0.13-15.xcarchive`, verified version 2.0.13 and build 15.
- Upload log: `/private/tmp/BPM-Release15-Upload.log`, `Upload succeeded`; App Store Connect subsequently reported Ready to Submit.
- `git diff --check` passed. No code changes were made after the validated source snapshot, apart from release documentation.

## Earlier build 14 verification

- Nine focused Swift unit tests and one UI regression test passed: `/private/tmp/BPM-VoiceConsent.xcresult`.
- UI test covers first-use cancel/approve, subsequent use, reset in Settings, editable generated fields, save, and persistence. AI generation uses a simulator-only fixture.
- Consent alert was visually reviewed on iPhone 18 Pro simulator without clipping.
- Final Release archive and App Store export passed; bundled version, microphone description, and privacy manifest verified.
- Backend production build passed; policy verified on staging before promotion and on the public domain afterward.
- `git diff --check` passed.
- Physical-device BLE, noisy gym audio, microphone routing, and interruption checks remain outstanding. Synthetic endpoint tests are documented in `docs/workout-voice-capture-validation.md` and are not an accuracy benchmark.

## What's New

• Turn up to 60 seconds of spoken workout notes into an editable title and exercise-by-exercise description, with explicit OpenAI consent.
• Share customizable chart and stats cards, plain-text summaries, or detailed workout logs.
• Edit saved workout titles and descriptions.
• Resume an accidentally ended workout or include recent heart-rate measurements when starting.
• Improved workout controls, timer layouts, and chart readability.
• Updated privacy disclosures and added an AI permission reset in Settings.

## App Review Notes

This app requires a physical Bluetooth Low Energy (BLE) heart rate monitor. Without a compatible monitor connected, it displays "---" instead of a heart rate value. Compatible monitors implement the standard Bluetooth GATT Heart Rate Service (UUID 0x180D). To test: wear or activate the monitor, grant Bluetooth permission, tap the heart icon, and select the device. Once connected, the live heart rate appears in large digits. In workout mode, swipe to the second view for the full-screen BPM display. Optional sharing lets users share their live heart rate using a 6-character code. No sign-in is required.

Version 2.0.13 adds optional AI voice notes to Save Workout. Start and end a workout, choose a workout type, and open Save Workout. Tap AI voice, grant microphone permission, record up to 60 seconds, then tap Send. On first use, an explicit "Send recording to OpenAI?" confirmation explains the data transfer. Cancel keeps the recording local and does not send it. Confirm to generate an editable title and exercise-by-exercise description. Review and correct the text before tapping Save. Manual title and description entry works without AI permission. Reset AI voice permission in Settings to test the confirmation again.

The recording is sent through BPM's backend to OpenAI for transcription; the transcript is processed to generate the workout text. Measured heart rate, HealthKit records, and workout history are not attached. Model-improvement sharing is disabled. Audio is processed transiently; transcript/result safety logs may be retained for up to 30 days, with legal or safety exceptions. The app links to https://bpmtracker.app/privacy.html#ai-voice before upload. App Privacy declares Health, Fitness, and Other User Content used for App Functionality, linked to identity because freeform speech may identify the user, and not used for tracking.

After saving a workout, a Share drawer opens with Chart Card, Stats Card, Plain Text, and Logs. Card editors let users choose fields and change the card title without changing the saved workout. Export uses the native share sheet; Save Image requests add-only photo library permission. Saved workout titles and descriptions can be edited separately from workout history. End a workout, then use Resume to continue it; time spent reviewing the ended workout is excluded as a pause.

HRV requires a monitor that provides RR intervals, such as a Polar H10. Remain still for the full two-minute recording. Disconnections, contact loss, or incomplete data cause the recording to be rejected rather than displaying an unreliable result. HRV is RMSSD in milliseconds. The app does not diagnose or treat medical conditions.

## Sources for privacy classification

- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing
- https://developers.openai.com/api/docs/guides/your-data

Proof screenshots are in ignored `build/privacy-release-proof/`.
