# Reliability monitoring

Use Apple's crash reports for crashes and the existing TelemetryDeck integration for recoverable failures. No additional crash SDK is needed. New instrumentation takes effect only after its build reaches users.

## Dashboard

The saved [Reliability dashboard](https://dashboard.telemetrydeck.com/o/B7DA979E-CBFC-4345-8175-51DC68945633/apps/458D3F06-26F3-4929-ADFA-C1B7DF052D28/d/4F9B563E-29A8-49D4-B7CA-D185B3764F27) contains seven production tables for the last 30 days: HRV outcomes, HRV failures by reason, live-sharing failures by stage, failures by app version, app failures by component, observed connected sensor models, and sensor connection failures. Sensor usage counts unique users with `sensor_connection` and `outcome=ready` or `capabilities`; sensor failures count signals with `outcome=failed`, both grouped by model. Model groups are not exclusive: a user can use several models or appear as unknown before later identification. New-event tables await ingestion from the instrumented build. No alerts or email notifications are enabled.

Table percentages are shares of events, not per-attempt failure rates. Use Explore to inspect the release-specific stage, source, reason, category and operation breakdowns below.

## Crash triage

1. Open **Xcode → Window → Organizer → Crashes**, select BPM, and filter by app version/build and date. Review App Store Connect crash totals separately. Record affected devices, report count, OS versions and the reporting window; these are different measures.
2. Download a representative report for each signature and affected build. Inspect the exception, termination reason, crashed thread and repeating app frames. Do not infer a cause from aggregate counts or from another version's report.
3. Match the report to its archived build and dSYM. If names or lines are missing, compare binary/dSYM UUIDs with `xcrun dwarfdump --uuid`, then symbolicate with the matching archive. Rebuilding the same version does not recreate matching symbols.
4. Reproduce the failure, add a regression test for the trigger, and verify the exact fixed release. After distribution, check that signature in the new build cohort. Old-version reports can continue after a fix ships.

Apple already collects TestFlight crash reports automatically. App Store reports depend on users sharing diagnostics, and reports can be delayed. Absence of reports is not proof of no crashes. Keep downloaded logs out of this public repository.

## Release safeguards

- Project Release configuration uses `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`; preserve this for the app and Live Activity extension.
- Existing App Store export options enable `uploadSymbols = true` and `stripSwiftSymbols = true`. Keep symbol upload enabled and retain the signed `.xcarchive`, its dSYMs and the source revision/manifest for every distributed build.
- Verify the app and extension version/build in the archive, inspect symbol files, and retain the upload result. An archive, successful upload, Apple processing and TestFlight availability are separate milestones.
- Before distributing a reliability fix, run its regression tests plus the affected workflow. Record any physical HRM validation that remains outstanding.

## Recoverable failures

Review the existing events in TelemetryDeck by **version and build**, OS version and a fixed date range. New fields and signals begin only with the build containing them. Filter out Test Mode for production; do not merge historical events lacking a denominator into a new failure rate.

| Area | Event counts and denominator | Interpretation |
| --- | --- | --- |
| HRV measurement | `hrv_completed`, measurement/validation/calculation `hrv_failed`, and `hrv_cancelled`, compared with `hrv_start` | Start means measurement actually began. Keep start-stage failures separate because they have no corresponding start event. |
| HRV blocked before starting | Unique users with `hrv_readiness` `state=blocked` / HRV screen visitors | Split by source and reason. Readiness observations are not measurement attempts and can include several states per visit. |
| Stream creation | `stream_start_failed` / `stream_start_requested` | Failure to create a broadcasting session. |
| Stream viewing | `stream_viewer_failed` / `stream_viewer_started` | Split by connecting/streaming stage and user/restored starts. A failed attempt can later connect; success and failure are not mutually exclusive. |
| Export | `share_export_failed` / `share_export_requested` | Split by source and format. Track cancellation separately. Native completion does not prove recipient delivery. |
| Voice recap | `voice_recap_failed` / `voice_recap_requested` | Show cancellation separately from failure. |
| Storage, Health and Bluetooth | `app_failure`, split by component/operation/category; affected users / active users in the same build | A deduplicated incident signal, not an operation failure rate. There is no matching attempt denominator for every operation. |
| Sensor compatibility | `sensor_connection` ready/capabilities user counts and failed-signal counts by model | Compare within the same release/source cohort. Multiple failure stages can occur in one connection; `connected` is not an attempted-connection denominator. |

Use signal counts for attempts and unique users for affected-user/adoption views. Keep numerator and denominator in the same release cohort and time window. These ratios are operational indicators, not exact per-attempt conversion: no custom session IDs are sent, and process termination or delayed delivery can leave incomplete funnels. Do not divide Apple's crash counts by TelemetryDeck sessions to claim an exact crash-free rate; the reporting populations differ.

For implementation and event details, see [feature analytics](feature-analytics.md) and [sharing analytics](sharing-analytics.md). Telemetry contains fixed categories, including allowlisted sensor brands/models, but no raw errors, health measurements, advertised names, device identifiers, share codes, URLs, recordings or transcripts.

### Sensor diagnostics

`sensor_connection` describes one user connection, including automatic reconnects:

| Parameter | Values / meaning |
| --- | --- |
| `outcome` | `connected`, `ready` (first usable HR), `capabilities`, `failed`, `disconnected` |
| `sensor_vendor`, `sensor_model` | Fixed allowlist in `SensorAnalyticsIdentity`; unmatched devices remain `unknown` |
| `sensor_identity_source` | `unknown`, `advertisement`, `device_information` |
| `rr_support` | `unknown`, `not_yet_observed`, `observed` |
| `contact_support` | `unknown`, `unsupported`, `supported` |
| `battery_support` | `unknown`, `unavailable`, `supported` |
| Failure `stage`, `reason` | `connect/services/characteristics/subscribe/measurement`; fixed `AppFailureCategory` |
| Disconnect `reason` | `user` or `connection_lost` |

Connected, ready and disconnected emit once per logical connection. Failures emit once per stage/category; capabilities emit only when the observed identity/support changes after readiness. Missing RR observations do not prove the monitor lacks RR support. Classification may improve after Device Information arrives; inspect `capabilities` and identity source when a ready snapshot is `unknown`.

Manufacturer/model and battery characteristics are read locally. Only fixed identity and support categories are emitted, never raw advertisements/names, UUIDs, serials, company IDs, firmware, HR/RR or battery values. Local HRV start/completion/cancellation/failure capture sensor identity at attempt start; shared HRV omits local-sensor fields. Local readiness includes the current safe identity.

### HRV diagnostics in the updated build

`hrv_start`, `hrv_completed`, `hrv_cancelled` and `hrv_failed` include `source=local/shared`. Failures retain their existing reason families and add fixed details:

| Reason | Stage | Detail examples |
| --- | --- | --- |
| `sensor_unavailable` | `start` | `rr_unavailable`, `heart_rate_unavailable`, `stream_unavailable`, `clock_unavailable` |
| `sensor_changed` | `measurement` | `source_changed`, `stream_changed`, or unavailable-source details |
| `data_stopped` | `measurement` | `no_beats_received`, `beat_data_stopped` |
| `quality_check` | `validation` | `insufficient_intervals`, `late_start`, `early_end`, `receipt_gap`, `coverage_mismatch`, `abrupt_variation`; full enum in `HRVCalculator.QualityIssue` |
| `calculation` | `calculation` | `invalid_result` |

Older releases labeled quality and calculation failures `stage=measurement`; compare by reason across releases or use build-specific stage filters. `rr_unavailable` means fresh usable beat intervals are unavailable. It does not distinguish missing monitor capability from poor contact or stale data. No interval values, timing values or source IDs are sent.

The updated HRV screen gates measurement on fresh usable data. `hrv_readiness` preserves visibility into blocked users with `state=ready/blocked`, `source=local/shared` and `reason=ready/monitor_disconnected/sensor_contact_lost/waiting_for_heart_rate/waiting_for_rr/stale_rr/shared_data_unavailable`. Each source/reason is emitted at most once per screen presentation while idle, not every redraw or callback. Readiness reasons can also appear as `sensor_unavailable/detail` if readiness changes after the instructions appear. Fewer start-stage failures after this change may reflect prevention by the gate; assess blocked readiness alongside starts and completions.

### Other recoverable failures in the updated build

`app_failure` has exactly three application parameters: `component`, `operation`, `category`. Components are `workout_store`, `hrv_store`, `healthkit`, `health_autofill` and `bluetooth`. Operations describe load/save/sync, authorization or Bluetooth connection setup. Categories are bounded labels such as `storage_full`, `permission_denied`, `device_locked`, `corrupt_data`, `unavailable`, `timeout`, `connection_lost`, `invalid_response`, `network` and `unknown`.

The reporter suppresses the same component/operation/category until recovery for that operation or a new reporter instance; retries are not counted as independent failures. Cancellation is excluded. Treat `unknown` as a triage category, not permission failure. No empty Health read is interpreted as denied access.

`stream_viewer_failed` adds `source=user/restored` and `reason=invalid_request/session_not_found/network/timeout/invalid_response/server_error/rate_limited/stale_data/unknown`, retaining `stage=connecting/streaming`. It emits only the first failure per viewing attempt. A missing session before connection is `session_not_found`; after connection it is a normal stop. This cannot distinguish an expired code from an incorrect code. Bluetooth failure suppression resets only when a real reading resumes. `voice_recap_failed` adds the same fixed `category` labels used by `app_failure`.

## Local verification

Debug builds log fixed analytics labels locally and do not initialize/upload through TelemetryDeck by default. For an explicit ingestion check, add `-BPMEnableAnalytics` to the Xcode Run launch arguments. Those Debug uploads remain test signals; inspect them with dashboard Test Mode enabled and remove the argument afterward. Release/TestFlight builds use normal release analytics behavior.

Check event de-duplication and recovery in unit tests before device testing. Use the local Xcode console for diagnostics that do not belong in telemetry. A recoverable error event is not a crash report.

### Verification on November 5, 2026

Across final runs, **370 unit tests and 15 UI tests passed**. Coverage includes cold launch, setup timing and dismissal, calorie tiers and decimal input, Apple Health review/autofill, custom zones, accepting/dismissing a new max, landscape, accessibility text, and analytics navigation. The last sensor run covers all 29 recognized models, generic-name rejection, metadata enrichment and event deduplication.

Result bundles in the local XcodeBuildMCP workspace:

- Full unit suite plus zone/max-HR UI: `test_sim_2026-11-05T18-13-39-263Z_pid95912_03b5e1d5.xcresult` (369 unit + 3 UI).
- Apple Health and calorie essentials/optional: `test_sim_2026-11-05T18-17-08-039Z_pid95912_b5b09724.xcresult` (4 UI plus sensor regression suite).
- Decimal weight and setup dismissal: `test_sim_2026-11-05T18-21-57-432Z_pid95912_0a159ec6.xcresult` (2 UI plus the expanded 10-test sensor suite).
- Analytics, landscape and accessibility: `test_sim_2026-11-05T18-24-45-012Z_pid95912_f0fb85d4.xcresult` (3 UI plus sensor suite).
- Final sensor assertions: `test_sim_2026-11-05T18-26-59-804Z_pid95912_f7f91d71.xcresult` (10 unit).
- Cold-start, first-workout prompt and largest-text setup passed in the initial combined run, `test_sim_2026-11-05T18-03-55-488Z_pid95912_8880c622.xcresult`; its other UI failures were corrected and passed in the runs above.

Settings and calorie screens were visually checked; screenshots are in ignored `build/settings-refinement-qa/`. Physical HRM behavior and production ingestion of new events remain unverified. The earlier 2.2 (22) archive attempt failed because the session could not write Xcode package caches; a later local archive succeeded with macOS signing access. See [TestFlight status](app-store/2.2/testflight.md).

### Local follow-up review, November 5, 2026

Reviewed the full uncommitted app/settings, Health autofill, HRV, sensor telemetry, sharing, persistence and deployment changes. Fixed native HealthKit authorization cancellation being treated as an unknown failure. Autofill now preserves cancellation through the service and exits quietly in the UI; a regression verifies that no failure event is emitted.

**371 unit tests and 25 distinct UI tests passed across the final runs** on iPhone 18 Pro / iOS 27.0. The initial invite test expected the Workout screen after a fresh URL launch; it now separately verifies warm delivery and cold-launch cancellation, including preservation of the running workout. Added coverage for an invite received while Settings is open. The accessibility test now starts without a persisted friend code, avoiding state inherited from sharing tests.

Result bundles in the local XcodeBuildMCP workspace:

- `test_sim_2026-11-05T21-39-22-795Z_pid32666_6c3c2a23.xcresult`: 370 unit tests and 21 UI tests passed; the outdated invite expectation failed.
- `test_sim_2026-11-05T21-54-39-451Z_pid32666_b9494b35.xcresult`: all 371 unit tests, both invite regressions, and workout save/adaptive-chart UI passed; the accessibility test exposed inherited sharing state.
- `test_sim_2026-11-05T21-58-04-272Z_pid32666_0e0252ab.xcresult`: the isolated accessibility test passed.
- `test_sim_2026-11-05T22-01-37-250Z_pid32666_7e94dedd.xcresult`: rotation passed again after moving the HRV readiness message below the top controls. Portrait and landscape screenshots confirm the message stays above the timer and stats, matching Home's placement and footnote styling. Debug and device-target Release builds were repeated successfully for this adjustment.
- `test_sim_2026-11-05T22-29-24-789Z_pid32666_564f5ab0.xcresult`: 20 focused share/rotation tests passed after simplifying calorie labels and increasing the HRV message's top spacing to 20 points. Final portrait and landscape screenshots are in `build/release-testflight-22/`.

Debug simulator build/run and the unsigned device-target Release build passed. App and extension both report 2.2 (22). Backend production build passed; 10 backend tests passed and the Redis integration group was skipped because `redis-server` is unavailable. The live AASA endpoint returned HTTP 200 / JSON and matched the checked-in file.

Visually checked calorie setup, Settings, max-HR suggestions, largest accessibility text, and the disconnected HRV screen. Screenshots are in ignored `build/local-review-screenshots/`. Two non-failing SwiftUI runtime warnings remain: publication during view updates (also present in November 4 logs) and invalid frame dimensions during calorie editing. Captured stacks have no usable symbols/source locations; no visual failure was observed, and no speculative layout changes were made. Physical monitor behavior, real Apple Health permission/data retrieval, and production ingestion of the new events still need device validation. The subsequent requested TestFlight release is tracked in the [release notes](app-store/2.2/testflight.md).

## Findings recorded November 5, 2026

- Five downloaded reports from **2.0.12 (13)**, dated October 20 (two reports), October 27, October 28 and November 1, share an `EXC_BAD_ACCESS` stack-overflow signature involving recursive zone-preference load/save notifications. They span iOS 26.5.2, 26.6.2 and 27.0.1.
- Organizer showed that signature affecting 19 devices over its one-year view and 3 over its two-week view. These are affected-device counts, not the five downloaded-report count.
- App Store Connect's August 6–November 3 window reported crashes by version: 2.0.12: 11; 2.0.11: 6; 2.0.9: 2; 2.0.7: 1; 2.0.10: 1. Reports from the other versions were not established to have the same cause.
- The zone-storage recursion fix is in commit `24d7780`, included in 2.2. The public 2.0.12 build lacks it. Verify the fixed build's distribution and subsequent crash reports before calling the public issue resolved.
- TelemetryDeck production events in October 6 00:00 UTC–November 6 00:00 UTC showed 14 `hrv_failed` events: 4 quality-check failures in 2.1.1, 2 start-stage sensor-unavailable failures in 2.1 and 8 in 2.1.1. The event detail reported 10 unique users and 12 sessions overall; grouped unique-user counts overlap. These are recoverable measurement/start failures, not crashes, and the start-stage events must not be divided by `hrv_start`.
- In that same window, 2.1.1 emitted 11 HRV starts, 4 measurement failures, 5 cancellations, 1 completion and 1 save. One start had no observed terminal event. Version 2.1 emitted 1 start and 1 cancellation. Older builds emitted starts before completion instrumentation existed, so the all-version 52 starts and 1 completion do not form a valid conversion metric.
- Version 2.1.1 emitted 5 stream-viewer failures and 5 viewer starts across 2 users, all failures at `stage=connecting`. Those events lack reason categories, so their underlying cause is not established.
- The same query window showed 10 export requests, 2 voice-recap requests and 23 stream-start requests without their corresponding failure events. This records an absence of emitted failures, not proof that every operation succeeded.

## References

- Apple: [Acquiring crash reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs), [debug symbols](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information), [symbolication](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report).
- TelemetryDeck: [default metadata](https://telemetrydeck.com/docs/ingest/default-parameters/), [dashboard filters and Test Mode](https://telemetrydeck.com/docs/basics/).
