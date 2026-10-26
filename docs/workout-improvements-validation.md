# Workout recovery, charts, and dictated recap
Voice capture was replaced on October 26, 2026. See [the current voice capture validation](workout-voice-capture-validation.md); the October 23 recap notes below describe the earlier implementation.

Implemented locally on 2026-10-23 from clean `master` at `88e4a8e`, using Xcode 27.0 (27A266a). No commit, push, merge, release, entitlement enrollment, or production deployment was performed. The repository AGENTS.md was inspected; there was no repository `.agents` directory. No session archives were accessed.

## Behavior

- Ordinary Start offers Start from now / Include previous measurements / Cancel when eligible current-sensor-session readings exist. Confirmation rereads the buffer, limits recovery to one hour, filters invalid/future/contact-lost readings, and respects reset, completion, and changed-session boundaries. Included readings backdate elapsed and set time. Imported/live duplicate identities are rejected. Preset countdowns and pause/resume retain their existing semantics.
- Live and saved charts share adaptive elapsed-time ticks based on width, Dynamic Type, visible duration, and scroll position. Labels use `m:ss` or `h:mm:ss` without forcing an overlapping endpoint.
- Save Workout → Dictate workout recap opens a review step. Speech requires on-device recognition; unavailable or denied permission leaves manual input available. Available iOS 26+ Foundation Models generates an extractive draft; iOS 17 remains supported with manual/extractive fallback. The original transcription stays visible and editable. A conservative validator rejects changed/dropped factual tokens, numbers, units, exercise names, punctuation, or uncertainty. This intentionally limits paraphrasing; descriptions may retain most of the transcription to protect facts.
- Use Draft preserves a custom title and appends to existing notes; it does not save the workout. Save and Cancel remain explicit. Canceling the recap does not apply it. Recording owns the audio session, suppresses queued alerts, stops on interruption/backgrounding, and permits final transcription before enabling generation after Stop.

## Source inputs

All three Library files were materialized into this laptop's `build/inputs/` through the supported transfer helper, and verified readable: patch 24,028 bytes, README 2,932 bytes, PNG 375,557 bytes. The PNG pixels were inspected. The draft was reviewed before applying, then extended and built here.

## Validation

- Build and launch succeeded on the BPM iOS 27 Review simulator (iPhone 17e). Deployment target remains iOS 17.0. The final builds produced no source warnings.
- All 105 BPMTests passed in `build/Improvements-Final-Checks.xcresult`, including recovery/repeated starts/reset/stale session/empty buffer/completion, pause/resume, preset timing, persistence, chart spacing, number and unit fidelity, permission denial and interruption tests.
- `ModernInterfaceUITests/testDeviceCodeEntryAndNavigationAtAccessibilityTextSize` passed in the same bundle.
- `ModernInterfaceUITests/testSaveCancellationAndAdaptiveChart` passed in `build/Improvements-UI-Final.xcresult`: save cancellation, saved history, expanded chart portrait/landscape, and chart controls.
- The initial recap UI test passed in `build/Improvements-UI-Final.xcresult`: Start Cancel/Include, recap Cancel, manual fallback, draft review, Save and history.
- Five rendered chart cases passed and were visually inspected: 280pt and 390pt 19:12 charts, 320pt accessibility text, 768pt three-hour chart, and a 320pt zoomed/scrolled three-hour chart. Images are in `build/chart-screenshots/` with readable case names. These are synthetic data rendered through the actual shared chart view.
- Final follow-up: all 5 selected tests passed in `build/Improvements-Recap-Final.xcresult` (four permission/interruption tests and the expanded recap UI test). This rebuilt the final recording cleanup changes and verified editing, preserving/appending existing notes, explicit save, app relaunch and history persistence.
- `git diff --check` passed.

Earlier UI runs failed. These identified a recap sheet presentation issue (fixed by using navigation inside Save Workout), iOS 27 Health authorization scrolling needed by the test, device-picker dismissal timing, and offscreen/editor-caret assumptions in UI tests. Earlier render snapshots cropped the axis because of the test hosting window's safe area; the corrected snapshots are the ones listed above.

## Remaining device checks / PCC

The paired AK iPhone was reported **unavailable** by `devicectl`. Physical BLE reconnect/device switching, actual microphone transcription quality, interruption during live audio capture, alert coexistence on hardware, and real on-device Foundation Models generation were not exercised. Permission/interruption control paths used injected synthetic tests; the simulator recap used manual input/fallback. No real private workout was sent for testing. No iOS 17 simulator runtime was installed, so iOS 17 runtime behavior is not verified beyond compilation/deployment availability guards.

Apple's installed SDK declares `PrivateCloudComputeLanguageModel` available on iOS 27+. Apple's current documentation is beta and requires eligibility plus the managed Private Cloud Compute entitlement; availability must also be checked at runtime. No entitlement or account eligibility is assumed, and no cloud or third-party provider path is enabled.

Sources checked:
- https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel
- https://developer.apple.com/private-cloud-compute/
- Installed Xcode 27 FoundationModels Swift interface.

## New phone follow-up

The newly paired iPhone 18 Pro became connected. A Debug device build with automatic provisioning updates and device registration succeeded (`build/device-review-build.log`), and `kvamme.BPM` installed successfully. Remote launch was denied by iOS because the phone was locked (`FBSOpenApplicationErrorDomain`, Locked). Unlocking the phone is required to continue launch and hardware validation. No signing identifier or source setting was changed. The signing screenshot supplied in this follow-up names a different app identifier, `com.controlyourbreath.app`.
