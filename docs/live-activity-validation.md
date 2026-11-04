# Live Activity lifecycle and layout

A Live Activity requires a fresh positive heart-rate reading from the local monitor or the selected friend, or an active workout timer. Running, paused, cooldown, and paused cooldown workouts qualify. Sharing enabled, a saved friend code, connection errors, and old summary statistics do not qualify by themselves.

Local readings expire after the existing 3-second measurement freshness window. Friend readings use the sharing service's remaining freshness window; polling a duplicate packet does not renew it. A shared workout timer is eligible only while its snapshot is fresh (5 seconds). Explicit disconnects, invalid readings, stopping viewing, and finishing a timer without readings remove the activity immediately through ActivityKit.

Sensor, viewer, and local workout state are independent. Disconnecting a sensor preserves a workout timer or a friend's activity. A local workout takes display priority over viewing a friend. Dismissals stay suppressed per source until that source session ends. ActivityKit updates and removals are serialized so queued work cannot revive a stopped session.

## Layout

On iOS 27, `isDynamicIslandLimitedInWidth` identifies the reduced compact layout used when another activity is present. Both this layout and the minimal layout use 13-point three-digit text within the 28-point safe circle. Normal compact text is 18 points. Timer-only workouts show a stopwatch in the smallest layout and elapsed time in regular compact, expanded, and Lock Screen layouts.

## Regression checks

- `BPMTests/HeartRateActivityControllerTests`: eligibility, source isolation, expiry, manual dismissal, coalesced session changes, and blocked asynchronous update/removal races.
- `BPMTests/SharedWorkoutSyncTests`: shared timer expiry, paused/idle states, cooldown, and failed viewing.
- `BPMUITests/LiveActivityLifecycleUITests`: actual ActivityKit counts for local/friend removal, timer-only continuation, and concurrent activities.
- Launch a Debug build with `--live-activity-ui-test` for an isolated ActivityKit fixture. End its activities before returning to the normal app. The fixture is excluded from Release builds.

## Verified 2026-11-04

- Simulator build passed; 276 unit tests and all 4 lifecycle UI tests passed.
- A separate temporary app bundle confirmed the actual iPhone 18 Pro / iOS 27 concurrent Island layout: white 220 and green 188 both fit without clipping. Two activities from the same app alone do not reproduce this system layout because iOS groups them.
- [Concurrent Island screenshot](../artifacts/live-activity-2026-11-04/concurrent-island.png) and [normal compact screenshot](../artifacts/live-activity-2026-11-04/compact-island.png).
- Test activities were ended and the temporary comparison app was removed. The permanent UI suite has no dependency on that app.

## Device validation still required

Check a physical heart-rate monitor disconnect/reconnect with the phone locked, a friend stopping their monitor while the viewer is locked, manual Lock Screen dismissal, and an active FaceTime call alongside BPM. Simulator readings do not validate Bluetooth delivery or iOS suspension behavior.

The viewer currently receives updates through app polling, without ActivityKit APNs updates. If iOS suspends the app, expiry can mark the content stale and cap a shared timer, but app code cannot guarantee immediate removal until it receives runtime again. Reliable removal while suspended requires a server-driven ActivityKit end notification. Force-quit cleanup has the same runtime constraint. `staleDate` is not an automatic dismissal deadline.

Apple references: [Live Activity presentation and lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [immediate dismissal](https://developer.apple.com/documentation/activitykit/activityuidismissalpolicy/immediate).
