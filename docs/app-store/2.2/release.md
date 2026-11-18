# BPM 2.2 (24)

Prepared November 9, 2026 for App Store Connect app `6754830191`, bundle `kvamme.BPM`. Previous production release: **2.1.1**, verified in App Store Connect and Apple's public lookup on November 9 (released October 30).

## Scope

- Live workout invitation links, synchronized trainer controls and presets, and shared HRV calculated on the monitor owner's device.
- Apple Health autofill with review, clearer calorie setup, max-heart-rate suggestions, and improved HRV readiness and error reporting.
- Reopening or foregrounding BPM returns to an active local or shared workout, including paused sessions.
- Sharing stops after five minutes without a viewer or after 90 minutes total. The local workout continues and explains why sharing stopped.
- Fresh screenshots: eight iPhone captures at 1320 × 2868 and five iPad captures at 2064 × 2752. Six iPhone images and all five iPad images were accepted for the store. Six iPhone images are also live on the marketing site. All are actual app UI with synthetic demo data. Source captures are RGB PNGs without alpha; the iPhone presets image was uploaded as an RGB JPEG after its initial upload stalled. See [capture inventory](screenshots/README.md). Updated store copy is saved in App Store Connect.
- Added the Other Diagnostic Data privacy-manifest declaration for existing bounded reliability events. Analytics purpose, not linked to identity, no tracking. App Store disclosure published and verified November 9 to match the manifest.

The user explicitly authorized all current edits for deployment. This release includes the existing working-tree changes. Store copy is recorded in [metadata.json](metadata.json).

## Validation

- Backend: all 32 tests passed, including isolated Redis integration; production build passed.
- iOS units: final full run passed all 393 distinct tests / 404 parameterized executions, with no failures or skips. Three timing-sensitive storage assertions failed under the initial concurrent build/test load, then passed the isolated 19-test storage run and the clean full rerun. No runtime change was required. Result: `build/release-review-20261109-units-final.xcresult`.
- Focused UI checks: all seven passed, covering Health autofill review, active/paused workout cold launch and foreground routing, shared trainer controls and HRV, and automatic sharing expiry without stopping the workout. Result: `build/release-review-20261109-ui.xcresult`.
- Signed archive succeeded: `build/BPM-2.2-24.xcarchive`. App and extension both verified as 2.2 (24), valid signatures and matching dSYMs, production API URL, Universal Links entitlement, and included diagnostics disclosure.
- Evidence: ignored `build/release-appstore-24/archive-validation.json`, `source-manifest.json`, and `archive-final.log`.
- Physical Bluetooth monitor behavior, locked-phone audio, and microphone routing have not been retested by this release action.

## Distribution status

**Ready for Distribution.** Apple approved and released version 2.2 on November 9, 2026 at 2:09 PM PST, verified in App Store Connect History. Review began at 1:53 PM. The version was submitted at 7:59 AM with automatic release after approval and immediate rollout, preserving existing ratings. The initial upload was blocked by Apple authentication; after the user signed in to Xcode and App Store Connect, upload succeeded at 7:45 AM PST.

- Upload options: `build/release-appstore-24/UploadOptions.plist`.
- Successful upload log: `build/release-appstore-24/upload-final.log`. The initial failed attempt remains in `upload.log`.
- Version 2.2 includes the updated description, promotional text, release/reviewer notes, and support URL. Six iPhone and five iPad screenshots accepted; old overrides removed and smaller devices inherit the new assets. Build 24 selected (Apple build ID `08333085-99c0-4eea-9592-06a4e210681d`). Other Diagnostic Data published as Analytics, not linked, no tracking.
- Submission ID: `3d85d04e-de96-4fe9-9c5d-5c109a9ab0e3`. [App Review receipt](https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/3d85d04e-de96-4fe9-9c5d-5c109a9ab0e3).
- Evidence: `build/release-appstore-24/waiting-for-review.jpg` and `submission-verification.json`. Final source-manifest verification matched all 96 archived source files with no drift.
- Approval follow-up: Apple's public App Store listing also verified version 2.2 with release timestamp `2026-11-09T22:09:39Z` (2:09:39 PM PST). Evidence: `build/changelog-approved/app-store-public-version.json`. The website changelog now identifies 2.2 as the latest released version.

## Website deployment

- Production `READY`: `dpl_A8zMLy7nzyEj5R7bd76Jv43NQ8uE`, promoted to https://bpmtracker.app.
- All 26 staged and 26 live API checks passed. An existing synthetic session survived promotion, accepted a legacy heartbeat, and was then deleted and verified unavailable.
- All 12 public assets match the deployment source. Independent readback additionally verified 11 website files including all six screenshot assets, revised copy/privacy page, CSS/JavaScript, and social preview. Evidence: `build/release-appstore-24/independent-live-readback.json`.
