# Feature usage in TelemetryDeck

The iOS app sends these signals to the existing BPM TelemetryDeck app
(`458D3F06-26F3-4929-ADFA-C1B7DF052D28`, namespace `com.siav`). Existing event names
remain available, so historical charts continue to work. New coverage begins with
the first released build containing this change. Debug builds log events locally
but disable analytics uploads by default, including automatic SDK events. To test
ingestion, add `-BPMEnableAnalytics` in Xcode under **Edit Scheme → Run → Arguments →
Arguments Passed On Launch**. These uploads are always marked as test signals;
enable Test Mode in the TelemetryDeck dashboard to see them. Remove or uncheck the
argument to disable uploads again. Release builds keep the SDK's normal behavior.

## Questions and events

| Question | Signals and breakdown |
| --- | --- |
| Are people sharing workout/HRV exports? | `share_picker_opened`, `share_format_selected`, `share_export_requested`, `share_export_presented`, `share_export_completed`, `share_export_cancelled`, `share_export_failed`; split by `source` and `format`. See [sharing analytics](sharing-analytics.md). |
| Are people broadcasting live heart rate? | `stream_start_requested` → `share_on` (server created session) → `stream_broadcast_connected` (first nonempty heart-rate update accepted by server). `stream_start_failed` records setup failure; `share_off` records ending an active session. |
| Are people watching a stream? | `stream_viewer_started` with `source=user/restored` → `stream_viewer_connected` on the first nonempty data response. `stream_viewer_failed` has `stage=connecting/streaming`. `stream_viewer_stopped` has `connected=true/false`. |
| Are sound effects enabled? | `feature_configuration` has `bpm_alert_enabled` and `zone_alert_enabled`. `setting_changed` has `setting=bpm_alert/zone_alert` and `enabled=true/false`. Preset `workout_start`, `preset_selected`, and `preset_saved` include `sound_enabled`. |
| Are sounds actually being used? | `sound_used` with `sound=bpm_alert/zone_alert/preset_bell/hrv_completion`, once per category per app process and UTC day. This fires after the audio player accepts playback, not proof the speaker was audible. |
| Are people using HRV? | `screen_viewed` with `screen=hrv` → `hrv_start` → `hrv_completed` → `hrv_save`. `hrv_cancelled` means an in-progress measurement was reset. `hrv_failed` distinguishes `stage=start/measurement` and fixed `reason=sensor_unavailable/sensor_changed/data_stopped/quality_check/calculation`. No measurement values are sent. |
| Do people visit history or inspect a workout? | `screen_viewed` with `screen=workout_history/hrv_history/workout_detail/hrv_detail/workout_chart/workout_edit`. History visits count even when empty. |
| Which calorie fields are filled in? | `feature_configuration` and `calorie_configuration`: `weight_state`, `age_state`, `sex_state`, `height_state`, `resting_hr_state`, `max_hr_state`, `vo2_max_state`, `rmr_state`, `body_fat_state`, and `calories_enabled`. |
| Which calorie fields do people edit? | `calorie_field_edited` with `field=weight/age/sex/height/resting_hr/max_hr/vo2_max/rmr/body_fat` and `state=filled/empty/invalid/defaulted`. Emitted when leaving or backgrounding the form, once per edited field since the previous flush. No keystroke events. |
| Which workout views and presets are used? | `workout_start` with `mode=manual/preset`; existing `workout_save`; `workout_view_selected` with `view=table/bpm/stats/chart`; `preset_selected`; `preset_saved` with `action=create/edit`. Preset names and durations are excluded. |
| Is AI voice used? | `voice_recording_started` only after recording starts; `voice_recap_requested` → `voice_recap_completed/failed/cancelled`. These signals never contain recordings, transcripts, titles, or notes. |
| Which other areas are opened? | `screen_viewed` with `screen=home/workout/settings/presets/workout_save/calorie_settings/calorie_accuracy/zone_settings/zone_alerts/workout_types/devices`; `health_access_requested` when the Settings Apple Health action is used. |

## Counting rules

- Screen events fire once per view presentation. Returning from a child sheet or
  redrawing a view does not count another visit. Home/workout/HRV use actual mode
  transitions so rotation does not create visits.
- `feature_configuration` fires on first foreground activation each UTC day and whenever the
  snapshot differs from the last one in that process (also checked on alert toggles and calorie-form exit). It includes existing users
  who never open Settings. The calorie form also emits a snapshot on exit or
  backgrounding. These are adoption observations, not edit events.
- Calorie `filled` means a positive, finite number (integer for age and heart-rate
  fields), not clinical validation. `sex_state=defaulted` means no stored choice;
  the form supplies its existing default. A stored choice is `filled` regardless
  of the selected sex. `calories_enabled` follows required field completion.
- Stream connections, viewer failures, and stop callbacks are deduplicated within
  each viewing attempt. A failed connection can later succeed. No per-poll,
  per-beat, or per-zone-change event stream is emitted. Broadcast success does
  not establish that anyone viewed it.
- HRV start means measurement actually began. A missing sensor can produce a
  start-stage failure without `hrv_start`. Save means local storage confirmed
  success. Resetting a completed or failed measurement is not cancellation.
- UIKit export completion means the native share activity reported success, not
  delivery to a recipient.
- Debug uploads require the launch opt-in above. No new user identifiers or
  persistent telemetry stores are added.

## Suggested dashboard

Use **unique users** for feature adoption and signal counts for attempts. Filter
to the first instrumented release/build and exclude Test Mode for production.

1. **Feature adoption, 7 and 28 days:** unique users of completed export, broadcast
   connected, viewer connected, sound used, HRV started/completed, history visits,
   preset workout starts, and voice recap completed, divided by active users in
   the same release cohort and period.
2. **Sharing:** requested → presented → completed, split by format and source;
   show cancellations and failures separately.
3. **Streaming:** requested → session created → first accepted beat; viewing
   started (`source=user`) → first received beat. Show restored views separately.
4. **Sounds:** current observed settings split by enabled state; unique users of
   `sound_used` split by sound category. Count preset sound use separately from
   enabling a preset's sound option.
5. **HRV:** started → completed → saved, plus fixed failure categories and cancels.
6. **History:** unique visitors to workout and HRV history and their detail pages.
7. **Calorie setup:** field-state breakdowns from configuration snapshots and
   unique editors split by field and final state. Use the latest snapshot per
   user where supported; otherwise label the chart as snapshot observations,
   since users can change states during the period.

Do not describe event-count ratios as exact per-attempt conversion: analytics
does not send record/session identifiers, and users can make multiple attempts.
Process termination or offline delivery can leave a funnel incomplete.

## Validation

`AppAnalyticsTests` checks privacy-safe calorie snapshots, invalid/cleared fields,
concurrent sound deduplication, stream failures/recovery/late callbacks, HRV
completion/failure/cancellation, and the existing export lifecycle.
`FeatureAnalyticsUITests` exercises calorie edit bindings and both history routes;
the Debug `Analytics` log exposes only the same fixed labels sent to the SDK.
Physical BLE/audio behavior and production dashboard ingestion require a device
running a released build.

Verified October 28, 2026:

- Simulator build/run succeeded with the concurrent sound-player integration.
- The full unit run passed 162 tests. After the final telemetry refinements, all
  16 focused analytics/UI tests passed (`/tmp/BPMTelemetryTests-Verified.xcresult`).
- The final UI run emitted two `calorie_field_edited` events for changing and
  restoring age, each containing only `field=age` and `state=filled`; one visit
  each for workout/HRV history; and no duplicate Settings visit after returning
  from its child pages.
- BPM's live TelemetryDeck Recent Events page in Test Mode showed the new
  `screen_viewed`, `setting_changed`, `feature_configuration`,
  `calorie_configuration`, and `calorie_field_edited` signals. Inspected the
  calorie edit payload and confirmed fixed labels, simulator/debug context,
  version 2.0.13/build 17. This is test ingestion, not a released build.
- Privacy wording was updated in both policy sources. Neither the app changes nor
  the policy changes were published by this task.
