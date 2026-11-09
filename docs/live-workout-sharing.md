# Live workout sharing

The current local revision supports shared heart rate, workout controls, and one HRV measurement owned by the monitor's device. Viewers see its countdown and result and can request Start, Stop, or Reset. Raw beat transport remains available for older clients. The November 4 deployment and TestFlight records below describe earlier revisions; the shared-HRV revision needs its own deployment and final app-validation record. Physical-device validation remains outstanding.

## Connection and navigation

Device owns sharing, codes, invites, and connection errors. Start Sharing creates one six-digit code with Copy, Share Invite, and Stop Sharing in the same menu. Pending start requests belong to the service, so repeated taps or reopening Device cannot create another session. Home and Workout navigation keep the code unchanged.

Sharing and viewing are mutually exclusive. The friend-code input is hidden while broadcasting, and the service rejects joining your own code or joining another session before you stop sharing. Connect disconnects the local monitor before entering shared mode. If a local workout exists, Device asks to end and clear it first; Cancel preserves it. This confirmation also applies when joining from the HRV screen.

The Device menu uses monochrome controls with green connection indicators. Shared viewing adds a person badge to the green heart, and the Workout icon also carries a person badge. Workout turns green only when a local or shared workout is active; a missing shared snapshot stays inactive. There is no screen border, persistent viewing label, or code outside Device.

An explicit join initially opens the broadcaster's Home or Workout screen, with Workout always starting on its first table page. Returning from Home to Workout also starts on the table page; subsequent host navigation does not change the viewer's selected page. Opening or returning to the app shows Workout when a local or shared workout is active, including paused sessions and cooldowns. Restored sharing waits for a fresh snapshot and uses workout state regardless of the host’s current screen. A cold shared launch starts on the table page; returning from the background preserves the viewer’s chosen page. Idle sessions stay on their current screen. A new shared HRV measurement opens HRV on the connected devices; on reopening, an active workout takes priority without cancelling HRV.

Device → Disconnect Friend leaves the stream without stopping the broadcaster. Manual Connect and invitations keep Device visible while connecting or on an error, then dismiss it after the first successful session response. Reopening Device after connecting keeps its controls available. If an established sharing session ends, the viewer gets “Your friend stopped sharing.” and returns to a clean Home screen.

Share Invite opens the native share sheet with `https://bpmtracker.app/join/{code}`. For recipients without the updated app, the web page offers Open in BPM using the registered `bpm://join?code={code}` scheme, the six-digit code, and an App Store link. HTTPS invites are Universal Links for the production app identifier `5HW85B6746.kvamme.BPM`. iOS opens BPM directly for `/join/` paths with six characters; the app validates that the code is six ASCII digits. Both Universal Links and the `bpm://` fallback automatically connect. Device stays visible while connecting or on an invalid/expired-code error, then dismisses after the first successful session response. If a local workout exists, the recipient must confirm ending and clearing it first; Cancel preserves the workout and monitor. Reopening the same connected invite is idempotent. Join pages use no-store caching, no-referrer metadata/headers, and omit Vercel Analytics.

## Workout controls and measurements

Viewers can use the workout controls available in the broadcaster's current state: Start, include recoverable history, Pause, Resume, Work Set, Rest Set, Cool, End, Reset, and load or clear a preset. Save stays with the broadcaster. Reset requires confirmation. Start offers Start from now or the actual available history duration, using the same eligible sensor samples that the broadcaster would recover locally.

The broadcaster publishes presentation snapshots about once per second while sharing. They include timers, sets, statistics, chart, zones, estimated calories, active preset, available actions, recoverable history duration, and current HRV state/countdown/result. Saved titles, notes, profile inputs, and previous workouts are excluded. Charts retain measured peaks, troughs, and signal gaps in a bounded live payload; original measurements still drive the saved recording and statistics.

The viewer sends a request for the current workout ID and control revision. The server and broadcaster both check that the action is allowed and the snapshot is less than five seconds old. Accepted requests use the broadcaster's own timer methods, measurement clock, and sensor data. Paused, preset, cooldown, and completed workouts expose the actions valid for those states. The viewer never replaces the broadcaster's workout state. Trainer controls are disabled while the broadcaster is choosing workout type, editing Save details, or saving. An asynchronous save only clears the workout it originally captured.

Navigation does not change the control revision; workout and HRV transitions do. Duplicate command IDs cannot execute twice, and concurrent workout/HRV requests for one revision receive one claim. Expired requests remain queued until the broadcaster rejects and acknowledges them. The UI waits for a confirming revision instead of inventing a local result. Workout and HRV saves never write another person's shared measurements into the viewer's local history or Apple Health.

Workout freshness is independent of heart-rate freshness. A missing monitor reading remains blank while workout updates can continue. Stale workout streams freeze their displayed timers and disable all remote controls. Viewer timers advance with monotonic elapsed time between updates, bounded by the five-second freshness window.

## Shared HRV

The monitor's device performs the 120-second measurement using original RR intervals and its monotonic clock. Either person can start it. A viewer's request uses the same server and owner-side checks as workout controls, then starts acquisition on the owner even if the owner has not previously opened HRV. Both screens display that measurement's countdown, heart-rate summary, outcome, and result. The viewer does not run a second calculator or create a saved record from the shared result.

Start requires fresh heart rate and RR data from a connected monitor with usable contact. A source change, interrupted beat data, or failed quality check stops the owner's measurement with an error that is shared with viewers. If the sharing connection goes stale, the viewer freezes its countdown and disables remote controls until fresh updates arrive. It does not invent a completed result.

Stop cancels the owner's active measurement. A viewer stays on HRV while Stop is pending and until the owner confirms a state change; a failed request keeps the error visible. Leave screen exits without cancelling and remains available when the connection is stale. Closing a completed shared result does not reset the owner. Reset clears the result on both sides. Only the owner can save; viewing, closing, or disconnecting never makes the shared result eligible for the viewer's local history or Apple Health.

The broadcaster also uploads a bounded rolling window of raw RR intervals, with interval IDs, stream identity, and original monotonic timestamps. Workout and RR uploads use independent loops. This transport remains compatible with older clients that perform a separate shared measurement. Rounded BPM is never treated as beat data.

## API

| Route | Caller | Body / result |
| --- | --- | --- |
| `POST /api/share` | Broadcaster | Returns six-digit `code` and private `token` |
| `POST /api/share/beat` | Broadcaster | `token`, BPM or null, optional max/avg/min |
| `POST /api/share/workout` | Broadcaster | `token`, `snapshot` with optional `hrv`, `acknowledgedCommandIds`; returns `commands`, `serverTime` |
| `POST /api/share/rr` | Broadcaster | `token`, raw RR `snapshot` with source stream identity and timing |
| `GET /api/share/[code]` | Viewer | BPM fields, `workout`, `workoutTimestamp`, `rrStream`, `rrTimestamp`, `serverTime` |
| `POST /api/share/control` | Viewer | `code`, UUID `id`, `workoutID`, `controlRevision`, `action`; `preset` only for `loadPreset` |
| `DELETE /api/share` | Broadcaster | `token`; removes the session and associated workout, RR, and control data |
| `GET /join/[code]` | Invite recipient | Web page with app-opening link and code entry fallback |

Workout control actions are `work`, `rest`, `start`, `startIncludingHistory`, `pause`, `resume`, `end`, `reset`, `cool`, `loadPreset`, and `clearPreset`. HRV actions are `hrvStart`, `hrvCancel`, and `hrvReset`. There is no remote Save action. The six-digit code authorizes viewing and currently permitted workout/HRV controls; read responses never expose the broadcaster token.

Workout, HRV, and RR schemas are defined in `BPM/SharedWorkout.swift` and `BPM/SharedHRV.swift` and validated in `backend/lib/share-workout.ts`. Host sequences must increase. Redis scripts atomically validate authorization, session existence, ordering, claims, acknowledgements, and expiry. Updates preserve the original 90-minute lifetime and cannot recreate deleted sessions. Older workout snapshots without `allowedActions` support only their original manual Work/Rest controls.

The optional `hrv` object contains a UUID revision, presentation flag, state, remaining seconds, optional RMSSD and BPM summaries, readiness reason, optional error message, and remote-control permission. HRV commands require that permission; Start accepts ready idle/completed state, Stop accepts measuring state, and Reset accepts completed/error state. The HRV revision contributes to the top-level control revision. Missing or null `hrv` disables HRV controls. The top-level `allowedActions` array stays workout-only so older viewers can decode it.

## Validation and rollout

- iOS coverage includes `SharedWorkoutPresentationTests`, `SharedWorkoutSyncTests`, `SharingAccuracyTests`, `SharedHRVTests`, `LiveHeartRateSharingUITests`, `SharedWorkoutViewerUITests`, and HRV acquisition tests. Start-history coverage also checks that the displayed recovery duration matches the measurements actually included.
- Backend: `cd backend && npm test`. Sharing integration tests run actual Lua against isolated Redis when `redis-server` is on PATH or `BPM_TEST_REDIS_SERVER` points to the binary; they report a skip if Redis is unavailable.
- Deploy the backend before distributing the updated app. A backend predating the optional `hrv` field rejects the whole new workout snapshot. The upgraded backend accepts old snapshots with missing/null `hrv`; legacy BPM, workout, and RR clients continue to work.
- Real Bluetooth, background suspension, and two physical-device network conditions require device QA. Simulator tests use synthetic measurements and isolated sharing services.

### Shared-HRV revision, November 5, 2026 (local validation)

- All 29 backend tests passed with real isolated Redis and zero skips. Coverage includes HRV schema bounds, state/readiness permissions, result transport, replay protection, stale snapshots and commands, shared command claims, legacy payloads, and session expiry/deletion.
- The Next.js production build and whitespace checks passed. Final app tests and production deployment for this revision are still being verified; the dated records below do not establish release of these changes.

### Trainer revision verified November 4, 2026

- 72 focused iOS unit tests and 10 UI tests passed across the final runs. Coverage includes zone-defaults recursion, remote HRV provenance and expiry, own-code rejection, monitor disconnection, active-workout join confirmation from HRV, shared navigation, all workout actions, the save/control race, and stopped-session reset. One initial test-runner launch failed; the independent unit rerun succeeded. Two old test assumptions were updated for the intentionally changed stopped-session and simulator-discovery behavior, and both passed on rerun.
- The final affected-suite run passed all 30 selected tests. Existing launch-time SwiftUI publication warnings and a test-only actor-isolation warning remain. Result bundle: `test_sim_2026-11-04T16-58-57-804Z_pid65164_130aeefd.xcresult` under the local XcodeBuildMCP BPM workspace.
- All 25 backend tests passed with isolated Redis and zero skips, including sessions created by the exact legacy KV SDK serialization. Both the sharing-only release build and Vercel production build passed.
- Production deployment `dpl_AH8UrWd8hoHG8bXidCZMKFfDjtdt` is READY and serves [bpmtracker.app](https://bpmtracker.app). It was staged without a domain, checked, then promoted. Existing marketing, workout-recap source, and dependency lockfile hashes matched the previous live deployment. Only sharing routes, invitation support, and the relevant privacy disclosure were released.
- 61 API checks passed against both the staged deployment and live domain, covering all eleven actions, command replay/acknowledgement, exact raw RR values, private owner tokens, rejected Save/unauthorized writes, and invitation routing. The staging check upgraded a synthetic session created by the old production deployment. All synthetic API sessions were deleted and returned HTTP 404.
- The running Simulator app used the live backend with its synthetic monitor. A trainer API client loaded a preset, started, paused, resumed, ended, and reset it while the owner stayed Home. A manual workout also accepted Start, Work, Rest, Cool, End, and Reset. Raw RR intervals arrived separately. End during a preset prestart countdown correctly cancelled the unstarted preset; an immediately stale command after Reset was rejected, then succeeded against the settled revision.
- Stop Sharing in the app removed its synthetic production session (HTTP 404). The monitor was disconnected and the app returned to Home with no active workout.
- Current UI captures: [Device](../artifacts/live-workout-sharing/2026-11-04/trainer-revision/device-sharing-menu.png), [shared Home](../artifacts/live-workout-sharing/2026-11-04/trainer-revision/viewer-home.png), [shared Workout](../artifacts/live-workout-sharing/2026-11-04/trainer-revision/viewer-workout.png), and [landscape](../artifacts/live-workout-sharing/2026-11-04/trainer-revision/viewer-landscape-chart.png). These come from passing UI tests; provenance is recorded beside the images.
- Physical BLE/RR fidelity, background suspension, and two-phone network QA remain unverified. A subsequent signed archive and upload produced TestFlight 2.2 (20), verified Testing in Dev. See `docs/app-store/2.2/testflight.md`. No public App Store submission was performed.

## Earlier validation history

The following results are retained for traceability. Their Work/Rest-only controls and green-outline/cyan-heart designs have been superseded by the implementation above.

### Initial Work/Rest revision, November 4, 2026 (superseded)

- 33 focused iOS unit/UI tests passed across the sharing, presentation, synchronization, and navigation suites. The final sync/presentation/viewer run passed all 22 selected tests. That run reported launch-time SwiftUI publication and test-only actor-isolation warnings.
- All 20 backend tests passed with real isolated Redis, with no skips. The final production build, lint, and typecheck passed.
- Two separate Simulator instances used the real local Next.js routes and Redis. Viewer Work/Rest taps produced one matching set each on the broadcaster, using identical captured times and BPM summaries.
- The broadcaster returned Home while the viewer stayed in Workout and successfully requested another Work set. The viewer independently navigated Home and back, preserving the shared session. Pausing on the broadcaster froze viewer timers and disabled both set controls.
- The initial two-device run used the green outline. That design was subsequently replaced with the cyan Device heart and menu-only sharing controls; the original screenshots document the initial run only.
- Ending sharing returned HTTP 404 for the session. Local test services and the dedicated sharing simulators were stopped. No deployment or app distribution was performed.

### Cyan Device menu revision, November 4, 2026 (superseded)

- 30 focused tests passed: 23 sharing unit tests and seven UI tests. These verify one session/code across Home and Workout, repeated-start coalescing, menu-only controls, invalid-code feedback and retry, independent viewer navigation, and stale/paused control handling.
- At this revision, shared viewing used a cyan heart without a screen border or persistent viewing label. Screenshots: [Device menu](../artifacts/live-workout-sharing/2026-11-04/device-sharing-menu.png), [Home](../artifacts/live-workout-sharing/2026-11-04/viewer-cyan-home.png), [Workout](../artifacts/live-workout-sharing/2026-11-04/viewer-cyan-workout.png).
- At this revision, Connect kept Device open for connection errors and Done returned to the session. The backend had not been deployed for workout synchronization outside the isolated local test environment.

## Universal Links revision, November 4, 2026

- Associated Domains entitlement: `applinks:bpmtracker.app`, restricted by `/.well-known/apple-app-site-association` to `/join/??????`. Other website routes stay on the web.
- The AASA endpoint is served over HTTPS with status 200, `application/json`, no redirect, and a five-minute origin cache. Apple's association CDN was read back with matching JSON and status 200.
- Website association deployment: `dpl_1ZBwMSSqk2B6GZ4cX5xvqCLYS7pL`, verified and promoted to `bpmtracker.app`. The prior sharing-only deployment's other source files were preserved.
- Five sharing lifecycle unit tests and three focused UI regressions passed across final runs: URL validation and self-join rejection, automatic joining/monitor disconnection, active-workout confirmation and cancellation, and manual invalid-code retry. The HTTPS test uses `XCUIDevice.shared.system.open` for real OS routing, then exercises URL delivery during cold launch. Initial OS routing ran before the association cache refreshed; the final run passed.
- Final OS-routing result: `test_sim_2026-11-04T18-45-04-998Z_pid65164_1e7f87df.xcresult`. Screenshot: [iOS invite routing](../artifacts/live-workout-sharing/2026-11-04/universal-links/ios-invite-routing.png).
- The fallback landing page remains available when BPM is not installed or a person has chosen to open this domain in the browser. Apple's routing behavior is described in [Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains) and [TN3155](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links).
- App build: 2.2 (21). Signed archive and upload succeeded; build `dac7070f-2a6b-4ddd-b476-30c71db24394` is verified Testing in the internal Dev group, expiring in 90 days. Physical-device link validation remains outstanding.

## November 5 follow-up validation

- 66 focused unit tests passed: shared HRV lifecycle and raw RR transport, workout/preset commands, synchronization, readiness/failure diagnostics, and simulator beat generation.
- 20 distinct UI regressions passed across final runs: 10 connection/invite tests, four shared-workout viewer tests, three preset/whole-second timer tests, and three shared-HRV tests. A transient simulator launch failure passed on rerun. Initial preset tests exposed the full-row action and landscape width mismatch; both were corrected.
- Final shared-HRV host test runs the actual simulator monitor for 120 seconds, receives a valid result, and verifies the owner's result is published. The viewer tests verify remote start, pending confirmation, countdown/result mirroring, no Save/Shared HRV label, result preservation on close, reset, and acknowledged cancellation.
- Final host/viewer portrait and landscape screenshots were reviewed; both layout tests passed in `test_sim_2026-11-06T05-19-33-543Z_pid21969_de39fddf.xcresult`. Captures are in ignored `build/shared-hrv-validation/`.
- Result bundles in the local XcodeBuildMCP workspace: `test_sim_2026-11-06T05-01-25-882Z_pid21969_84a672e9.xcresult` (connection/viewer tests), `test_sim_2026-11-06T05-11-17-302Z_pid21969_9e2ff8ad.xcresult` (66 units and portrait/whole-second UI), `test_sim_2026-11-06T05-14-05-954Z_pid21969_c5d29e17.xcresult` (viewer HRV and landscape), `test_sim_2026-11-06T05-16-37-942Z_pid21969_5acefdae.xcresult` (full 120-second host HRV).
- Backend preview `https://bpm-jdjfbwnaq-kvamme-team.vercel.app` passed 15 real API checks after the 29-test Redis-backed suite and production build. Synthetic session cleanup was verified. Smoke script and source manifest are in ignored `build/shared-hrv-validation/`.
- Local signed archive 2.2 (23) is verified. Production backend release and TestFlight upload were approved on November 6; see the release follow-up below.
- Physical BLE/background behavior remains unverified. Existing SwiftUI publication warnings remain; the completed measurement also emitted an audio-session main-thread performance warning, without a test failure.

## November 6 production release

- Promoted `dpl_JDsCQCikYRopF99wwBCg2khJKyHd` (`https://bpm-bcqgo355s-kvamme-team.vercel.app`) to `https://bpmtracker.app` after 20 staged production API checks passed. The live domain passed the same 20 checks.
- All 29 backend tests passed, including legacy SDK session/expiry preservation. A synthetic session created on the previous live deployment survived the switch and continued receiving old-client heartbeats. Test sessions were deleted and verified unavailable.
- Only `lib/share-workout.ts` changed production runtime behavior. Compared source hashes with prior deployment `dpl_1ZBwMSSqk2B6GZ4cX5xvqCLYS7pL`; retained its website, privacy page, and workout-recap source. Public page and AASA content matched the staged files after promotion.
- Production was read back as `READY`; the post-release error scan returned zero error logs. Evidence: ignored `build/shared-hrv-validation/production-source-manifest.json`, `production-stage-smoke.log`, `production-live-smoke.log`, `production-continuity.log`, `production-verification.json`, and `production-error-scan.json`.
- Build 2.2 (23) uploaded successfully after the user refreshed Xcode’s Apple Account sign-in. Apple processing completed; the Dev group verified **Testing**, expiring in 90 days. Build ID: `11e88d9a-50e9-40a3-aba2-5a998636c23c`. No public App Review submission was made.
