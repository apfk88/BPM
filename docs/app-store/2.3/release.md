# BPM 2.3 (27) upload

Uploaded to App Store Connect on November 12, 2026 at 8:22 AM PST. Apple accepted the binary and reported that processing began. This was an upload only; build 27 was not submitted for App Review.

Build 27 adds direct chart and stats sharing, a separate Customize action, and support for shorter workout links. The app uses legacy links until the production backend supports the shorter format. The signed release archive verified as 2.3 (27) for both the app and its Live Activity extension. Evidence: `build/release-appstore-27/upload.log`.

November 12 follow-up. Build 27 (`5c682d44-335a-4c03-b6a9-56be294f1682`) is visible in TestFlight. Build 26 is In Review, and withdrawal has not been authorized. The [short-link backend deployment](https://vercel.com/kvamme-team/bpm/5phXv2k88qZ2q1Rvq5djsvCdLieZ) is Ready on `bpmtracker.app`. The production short-link shell returned preview metadata and a noindex header. Both the unauthenticated workout read and unknown preview alias returned 404.

# BPM 2.3 (26)

Prepared November 11, 2026 for App Store Connect app `6754830191`, bundle `kvamme.BPM`. This replaces the earlier 2.3 build 25 submission. Manual release is retained.

## Scope

- Private workout pages with explicit opt-in, inaccessible background drafts, activation on final Share, full saved data, chart interaction, zones, sets, and downloads.
- Compact share drawer with fixed checkbox disclosure and full-size cards.
- One-URL card sharing with native selected-image metadata and a separately authorized, remotely fetched full-workout chart preview.
- Private-link status and Open, Copy, Manage, and Delete controls in workout history, alongside Settings → Shared Pages. Deleting a page retains the local workout.
- Durable ownership, recovery, updates, link replacement, deletion, and pending-operation retry.
- Production App Attest configuration and corrected retry/error handling for supported development signing.

The viewer/backend and privacy policy were deployed before this archive. The November 11 viewer revision removes the recording-completeness notice and range-inspection panel, adds drag panning while zoomed, and matches homepage branding. These web changes do not depend on App Store rollout.

## Validation

- All 438 unit tests passed, with no failures or skips. Result: `~/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/result-bundles/test_sim_2026-11-12T00-36-36-001Z_pid10069_a92d03ae.xcresult`.
- The preceding focused native passes covered the final drawer layout, exact selected PNG metadata, URL preview/view credentials, active-link reuse, history Copy verified through in-app paste, management, deletion retaining the workout, pending creation, and pending deletion. All 43 focused checks passed across those refinement runs; details are in [workout-page validation](../../workout-web-sharing-validation.md).
- All 83 backend tests and the production build passed. Hosted checks verified preview-token isolation, PNG rendering, unchanged full-workout data, privacy headers, desktop drag pan, keyboard pan, mobile layout, and no analytics requests.
- Archive and App Store distribution export succeeded. App and extension both report 2.3 (26), with valid signatures and matching dSYMs. Distribution builds disable debugger access, use the production API and App Attest environment, and contain Universal Links plus the privacy manifest. Debug-only fixtures are absent.
- All 104 source files in the archive manifest matched after packaging. Evidence is in ignored `build/release-appstore-26/`.
- Physical-device App Attest upload, receiving-app Messages/Mail preview behavior, and physical Bluetooth/audio behavior were not retested in this release action. Receiving apps decide whether to honor the selected native image or fetch the default full-workout card.

## Submission status

BPM 2.3 (26) is **Waiting for Review**, verified in App Store Connect at 4:55 PM PST on November 11. Build 25 was withdrawn and replaced. Manual release remains selected, so Apple approval will not publish the version automatically.

- Apple build ID: `026241dc-347f-4b75-a001-3e783d8028a4`.
- Submission ID: `828de2d2-878b-4470-839e-1074e1ad58e0`. [App Review receipt](https://appstoreconnect.apple.com/apps/6754830191/distribution/reviewsubmissions/details/828de2d2-878b-4470-839e-1074e1ad58e0).
- Apple showed “1 Item Submitted,” the correct build 26, and the updated reviewer notes and What’s New text on readback.
- Upload succeeded November 11 at 4:40:50 PM PST. Evidence: `build/release-appstore-26/upload.log`.

App Privacy changes were published and verified: User ID is linked data for App Functionality; Device ID is linked data for App Functionality and Analytics. Both remain No Tracking. Health, Fitness, Other User Content, Product Interaction, and Other Diagnostic Data retain their existing purposes. Exact metadata and evidence are saved in `build/release-appstore-26/submission-metadata.json` and `privacy-labels.jpg`.
