# Live workout sharing

The current implementation supports shared heart rate, workout controls, and raw beat intervals for HRV. The supporting backend was deployed to production on November 4, 2026. The app changes are verified in Simulator and available as TestFlight 2.2 (20) in the internal Dev group. Physical-device validation remains outstanding.

## Connection and navigation

Device owns sharing, codes, invites, and connection errors. Start Sharing creates one six-digit code with Copy, Share Invite, and Stop Sharing in the same menu. Pending start requests belong to the service, so repeated taps or reopening Device cannot create another session. Home and Workout navigation keep the code unchanged.

Sharing and viewing are mutually exclusive. The friend-code input is hidden while broadcasting, and the service rejects joining your own code or joining another session before you stop sharing. Connect disconnects the local monitor before entering shared mode. If a local workout exists, Device asks to end and clear it first; Cancel preserves it. This confirmation also applies when joining from the HRV screen.

The Device menu uses monochrome controls with green connection indicators. Shared viewing adds a person badge to the green heart, and the Workout icon also carries a person badge. Workout turns green only when a local or shared workout is active; a missing shared snapshot stays inactive. There is no screen border, persistent viewing label, or code outside Device.

The viewer initially opens the broadcaster's screen and workout page, then navigates independently between Home, Workout, and HRV. Device → Disconnect Friend leaves the stream without stopping the broadcaster. Connect keeps Device open so an invalid code or network error remains visible; Done returns to the session. If an established sharing session ends, the viewer gets “Your friend stopped sharing.” and returns to a clean Home screen.

Share Invite opens the native share sheet with `https://bpmtracker.app/join/{code}`. The web page offers Open in BPM using the registered `bpm://join?code={code}` scheme, the six-digit code, and an App Store link. Opening the app link preloads Device; the user still selects Connect and sees any required workout confirmation. Join pages use no-store caching, no-referrer metadata/headers, and omit Vercel Analytics.

## Workout controls and measurements

Viewers can use the workout controls available in the broadcaster's current state: Start, include recoverable history, Pause, Resume, Work Set, Rest Set, Cool, End, Reset, and load or clear a preset. Save stays with the broadcaster. Reset requires confirmation. Start offers Start from now or the actual available history duration, using the same eligible sensor samples that the broadcaster would recover locally.

The broadcaster publishes presentation snapshots about once per second while sharing. They include timers, sets, statistics, chart, zones, estimated calories, active preset, available actions, and recoverable history duration. Saved titles, notes, profile inputs, and previous workouts are excluded. Charts retain measured peaks, troughs, and signal gaps in a bounded live payload; original measurements still drive the saved recording and statistics.

The viewer sends a request for the current workout ID and control revision. The server and broadcaster both check that the action is allowed and the snapshot is less than five seconds old. Accepted requests use the broadcaster's own timer methods, measurement clock, and sensor data. Paused, preset, cooldown, and completed workouts expose the actions valid for those states. The viewer never replaces the broadcaster's workout state. Trainer controls are disabled while the broadcaster is choosing workout type, editing Save details, or saving. An asynchronous save only clears the workout it originally captured.

Navigation does not change the control revision; workout transitions do. Duplicate command IDs cannot execute twice, and concurrent requests for one revision receive one claim. Expired requests remain queued until the broadcaster rejects and acknowledges them. The UI waits for a confirming revision instead of inventing a local result. Workout and HRV saves never write another person's shared measurements into the viewer's local history or Apple Health.

Workout freshness is independent of heart-rate freshness. A missing monitor reading remains blank while workout updates can continue. Stale workout streams freeze their displayed timers and disable all remote controls. Viewer timers advance with monotonic elapsed time between updates, bounded by the five-second freshness window.

## Shared HRV

The broadcaster separately uploads a bounded rolling window of raw RR intervals, with interval IDs, stream identity, and the monitor's monotonic timestamps. Workout and RR uploads run on independent loops, so a delayed workout request cannot starve RR updates. The viewer deduplicates intervals and uses the original source clock for its own 120-second HRV measurement; it does not derive beat intervals from rounded BPM or mirror the broadcaster's HRV countdown.

Shared HRV requires fresh RR data from a monitor that supports it. A stale stream, source change, or interrupted beat data stops the measurement with an error. The screen labels the result Shared HRV. Save is unavailable, and the model also refuses to create a saved record from a remote measurement, including after disconnection.

## API

| Route | Caller | Body / result |
| --- | --- | --- |
| `POST /api/share` | Broadcaster | Returns six-digit `code` and private `token` |
| `POST /api/share/beat` | Broadcaster | `token`, BPM or null, optional max/avg/min |
| `POST /api/share/workout` | Broadcaster | `token`, `snapshot`, `acknowledgedCommandIds`; returns `commands`, `serverTime` |
| `POST /api/share/rr` | Broadcaster | `token`, raw RR `snapshot` with source stream identity and timing |
| `GET /api/share/[code]` | Viewer | BPM fields, `workout`, `workoutTimestamp`, `rrStream`, `rrTimestamp`, `serverTime` |
| `POST /api/share/control` | Viewer | `code`, UUID `id`, `workoutID`, `controlRevision`, `action`; `preset` only for `loadPreset` |
| `DELETE /api/share` | Broadcaster | `token`; removes the session and associated workout, RR, and control data |
| `GET /join/[code]` | Invite recipient | Web page with app-opening link and code entry fallback |

Control actions are `work`, `rest`, `start`, `startIncludingHistory`, `pause`, `resume`, `end`, `reset`, `cool`, `loadPreset`, and `clearPreset`. There is no remote Save action. The six-digit code authorizes viewing and currently permitted workout controls; read responses never expose the broadcaster token.

Workout and RR schemas are defined in `BPM/SharedWorkout.swift` and `BPM/SharedHRV.swift` and validated in `backend/lib/share-workout.ts`. Host sequences must increase. Redis scripts atomically validate authorization, session existence, ordering, claims, acknowledgements, and expiry. Updates preserve the original 90-minute lifetime and cannot recreate deleted sessions. Older workout snapshots without `allowedActions` support only their original manual Work/Rest controls.

## Validation and rollout

- iOS coverage includes `SharedWorkoutPresentationTests`, `SharedWorkoutSyncTests`, `SharingAccuracyTests`, `SharedHRVTests`, `LiveHeartRateSharingUITests`, `SharedWorkoutViewerUITests`, and HRV acquisition tests. Start-history coverage also checks that the displayed recovery duration matches the measurements actually included.
- Backend: `cd backend && npm test`. Sharing integration tests run actual Lua against isolated Redis when `redis-server` is on PATH or `BPM_TEST_REDIS_SERVER` points to the binary; they report a skip if Redis is unavailable.
- Deploy the backend before distributing the updated app. Older backends continue heart-rate sharing; missing workout routes disable workout synchronization, and missing RR routes leave shared HRV unavailable.
- Real Bluetooth, background suspension, and two physical-device network conditions require device QA. Simulator tests use synthetic measurements and isolated sharing services.

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
