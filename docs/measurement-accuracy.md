# Measurement accuracy audit

## October 30, 2026 follow-up

Reviewed the current iOS heart-rate acquisition and freshness paths, RR/HRV acquisition and arithmetic, calorie formulas and time integration, live/saved charts, workout summaries and persistence, sharing, zones, and Apple Health export. Changes preserve existing saved measurements; they do not establish clinical or individual calorie accuracy.

### Confirmed defects and corrections

| Area | Defect | Correction |
| --- | --- | --- |
| Sensor changes | A new sensor could inherit the previous sensor's HR/RR state; late callbacks from the old device could alter the new connection. | Reset measurement identity/capabilities at connection boundaries and reject callbacks from another device/service. |
| Current HR | Malformed notifications could leave the previous reading visible. | Clear current HR and invalidate the RR stream immediately. |
| HR averages | Live-hour average weighted notification count; HRV's BPM trace sampled a UI timer and could miss peaks. | Use every received sensor value and weight averages by represented time, capped at three seconds per reading. The HRV model owns its subscription. |
| Known signal loss | Aggregates could hold the prior reading until its normal timeout even after explicit contact loss. | Retain an optional invalidation timestamp with the last valid sample and cap live/saved statistics, calories, and charts at that boundary. |
| Cloud history reduction | Integer stride plus truncation could omit the end of a workout. | Retain points across the complete timeline, including endpoints and explicit loss boundaries; keep saved full-session summaries authoritative. |
| Timestamp storage | Whole-second date encoding discarded rapid receipt and pause timing. | Preserve fractional-second ISO timestamps on disk/export. Cloud payloads retain legacy-readable whole-second fields plus optional precision companions for new readers. Historical files remain readable. |
| Session scope | Saved duration and graph included cooldown while average/min/max stopped at workout end. | Use the same complete recorded interval for whole-session statistics. |
| HRV coverage | Missing intervals early and extra intervals later could cancel in the final duration total. | Check cumulative RR coverage at each complete notification, using the existing five-second tolerance. |
| Calorie formula | Entered RMR incorrectly rescaled gross oxygen-based energy; resting subtraction ignored it. Female regression age coefficient was rounded incorrectly. | Use `kcal/min = VO2 (ml/kg/min) × kg / 200`, subtract entered resting energy when provided, and use the published Keytel coefficients and `/ 4.184` conversion. |
| Calorie timing | Gaps up to 30 seconds were filled, every segment invented a one-second tail, and smoothing depended on packet frequency. | Integrate actual elapsed time with a three-second freshness cap, explicit workout end, pause boundaries, and no notification-count smoothing. |
| Calorie profile | Missing sex silently selected the male equation; nonfinite inputs and the medication setting were not handled correctly. | Require explicit sex selection, validate finite input ranges, and honor the HR-altering medication setting. |
| Calorie claims | The app presented an invented high/medium/low accuracy score based on completed fields. | Identify calories as estimates and the model as not individually validated. Legacy confidence storage remains for compatibility. |
| Workout saving | Saved calorie totals could use an older queued calculation; a reset could briefly display the previous workout's result. | Recompute from the current record at save time; generation-check queued results and clear reset state synchronously. |
| Pauses and charts | A still-fresh pre-pause reading could contribute after resume; chart lines and selected values could imply measurements inside gaps. | End the represented interval at pause, split graph series on gaps/pauses, use linear interpolation within a segment, and show the selected sample's actual time. |
| Shared HR | Repeated GET responses renewed an old server value; expired/error states and old requests could retain or replace the current reading. | Check source timestamp age, use monotonic local expiry, ignore replay/out-of-order/session-mismatched results, and clear expired/error readings. |
| Apple Health | Missing active calories fell back to total calories, counting resting energy as exercise. HR samples invented a one-second interval. | Export finite active calories only; preserve each HR reading as an instantaneous sample and exclude samples inside pauses. |
| Custom zones | Internal zone upper limits were ignored, silently assigning unconfigured gaps to the lower zone. | Respect internal upper limits. Shared boundaries enter the higher zone; gaps remain unassigned. |

Example verified by regression tests: for 80 kg, VO2max 50 ml/kg/min, RMR 1,440 kcal/day, and HR at the entered maximum, the corrected model gives **20 total / 19 active kcal/min**. The previous implementation gave 28 total / 26.6 active. At resting HR, the corrected total is 1 kcal/min with zero active energy. These are formula checks, not measured calorie burn.

### What remains uncertain

- Heart rate comes from the strap's beat detection. Code cannot prove the strap measured the physiological rate accurately. Test against a synchronized ECG/reference device before claiming sensor accuracy.
- RMSSD arithmetic and Bluetooth's `1000 / 1024` conversion are correct. The two-minute protocol still uses packet receipt times because standard HRS notifications contain no absolute beat timestamps or sequence numbers. Acquisition gates cannot prove every interval is a normal sinus beat, catch every small loss, or distinguish all artifacts from genuine variability. The existing 30% local-median rejection can reject real variability.
- Calorie models estimate oxygen use or energy from HR and profile inputs. They are not individually calibrated, and accurate HR does not make calorie estimates accurate. The Keytel study used steady submaximal exercise in adults; lifting, intervals, stress, heat, and cardiovascular drift can weaken the relationship. Accepted input ranges are sanity checks, not claims of validation for every person within them. Gaps reduce covered time; totals are not extrapolated to unmeasured time.
- Default zones use a configurable HR maximum and percentage bands, not measured lactate/ventilatory thresholds. Z1 includes resting values below its nominal lower threshold; Z5 includes readings above estimated max HR. User-defined gaps do not count toward zone time.
- Shared timestamps currently describe server receipt, not original strap acquisition; network transit and broadcaster ordering remain protocol limitations. Local stale-data protections do not validate the remote sensor.
- Apple Health receives an aggregate active-energy estimate over the workout's wall-clock bounds. Pause events preserve active workout duration, but minute-by-minute energy allocation is not directly measured.
- Older apps can read the compatible cloud payload, but an older app that rewrites it may drop new precision/loss metadata. All devices need the updated version to retain the new fields through every sync.
- Existing saved history is unchanged. Older records may contain the earlier calorie/summary behavior, and reduced iCloud sample histories cannot recreate every original beat or peak.

### Validation

Verified October 30, 2026:

- **233 unit tests passed, zero failures/skips**, on iPhone 18 Pro Simulator, iOS 27.0. Final suite includes reference equations, packet parsing, sensor changes, explicit loss, pause/cooldown boundaries, asynchronous save/reset, chart gaps, cloud reduction, rapid timestamp round trips, strict legacy cloud decoding, and Apple Health export semantics.
- Unsigned **Release build for generic physical iOS succeeded** (`CODE_SIGNING_ALLOWED=NO`). This is compilation validation, not a device run or App Store upload.
- Simulator build/run succeeded. Observed the disconnected workout state, Calorie Settings, and accuracy explanation; labels and explanation rendered correctly. Existing chart/share rendering tests passed.
- `git diff --check` passed. Test output retains existing Swift concurrency/unused-result warnings and debugger PCM lookup warnings; there were no build errors or failed assertions.

Final test result bundle: `/Users/kvamme/Library/Developer/XcodeBuildMCP/workspaces/BPM-1a5198e4ed5c/result-bundles/test_sim_2026-10-30T13-33-28-307Z_pid83587_d0a730a0.xcresult`. Device Release build log: `/tmp/BPM-accuracy-release-20261030.log`.

At audit completion, changes were local and uncommitted. Subsequent distribution status is tracked in [BPM 2.1.1 release notes](app-store/2.1.1/release.md).

Physical-device acceptance still required:

1. Record at rest and during changing exercise intensity with a real chest strap. Compare timestamped raw HR/RR exports to an independent reference calculation; verify RMSSD in milliseconds from the same adjacent RR sequence.
2. Repeat with brief contact loss, malformed/absent packets where a simulator is available, device changes, reconnects, backgrounding, screen lock, and pauses. No old reading should continue as current or contribute beyond a known loss/pause boundary.
3. Confirm rapid notifications, long gaps, end/save/reset, and restart yield consistent recorded time, averages, zone durations, and calories.
4. On a real device, compare BPM versus Apple Health HR sample timestamps, active energy, and pause-excluded duration. Calorie accuracy requires comparison with measured energy expenditure, such as indirect calorimetry.

### Primary references

- [Bluetooth Heart Rate Service 1.0](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HRS_v1.0/out/en/index-en.html): measurement flags, optional fields, multiple RR values and absence of measurement timestamps.
- [ESC/NASPE HRV standards](https://pubmed.ncbi.nlm.nih.gov/8598068/): RMSSD definition and measurement limitations.
- [Keytel et al., 2005](https://pubmed.ncbi.nlm.nih.gov/15966347/): HR-based energy regression and study population/protocol.
- [Swain and Leutholtz, 1997](https://pubmed.ncbi.nlm.nih.gov/9139182/): relationship between heart-rate reserve and oxygen-uptake reserve.
- [2022 exercise-intensity study](https://pmc.ncbi.nlm.nih.gov/articles/PMC9048681/): intensity/duration effects on the HR-reserve/oxygen-reserve relationship.
- [Apple active energy](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/activeenergyburned) and [heart rate](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartrate): resting energy exclusion and discrete HR quantities.

## September 14, 2026 audit (historical)

Reviewed September 14, 2026. These changes correct software defects; they do not establish clinical or sensor accuracy.

## HRV

BPM reports RMSSD in milliseconds: the square root of the mean squared differences between successive beat intervals. This matches the definition in the [ESC/NASPE measurement standards](https://www.escardio.org/static-file/Escardio/Guidelines/Scientific-Statements/guidelines-Heart-Rate-Variability-FT-1996.pdf). Rounded BPM is not a substitute for the original beat intervals.

- Removed the BPM-to-RR fallback and the simulator-only five-second measurement path.
- Preserved Bluetooth's interval order and conversion from 1/1024 second to milliseconds. Truncated fields, odd RR byte counts, and zero RR values invalidate the packet. See the [Bluetooth Heart Rate Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HRS_v1.0/out/en/index-en.html).
- The measurement owns its collected interval buffer. Rolling history pruning cannot shift its starting index or discard already collected intervals.
- A 120-second monotonic clock defines the measurement. Late callbacks cannot extend the recording. Post-deadline packets are excluded.
- Reconnection, device changes, malformed data, or reported poor contact invalidate the measurement. No result is fabricated or silently interpolated.
- Successful HRV saves are acknowledged only after writing the file. Consecutive saves use serialized history state.

Acquisition checks are conservative app rules, not clinically validated thresholds: at least 30 intervals, each 250–2500 ms, interval duration within five seconds of the 120-second window, no receipt gap over five seconds, and data within five seconds of each end. An interval more than 30% from an eleven-beat local median rejects the recording. A rejection can also occur with real physiological variability; it is not a diagnosis. Rejected intervals are not deleted and joined into a new sequence to manufacture a lower RMSSD.

Standard Bluetooth HR notifications contain neither absolute beat timestamps nor a sequence number. The recording window therefore uses packet receipt times; boundary alignment and small undetectable losses cannot be guaranteed. These checks cannot establish that every beat is a normal sinus beat. A two-minute resting RMSSD reading is not interchangeable with SDNN or every five-minute HRV protocol. Existing historical values remain unchanged.

## Heart rate and workout time

- Workouts capture received sensor measurements, including multiple measurements per second. Paused/completed sessions reject incoming measurements. Viewing a friend does not change the workout's sensor source.
- No contact, zero BPM, stale values, malformed packets, and callbacks from the wrong device or characteristic are excluded from valid acquisition.
- Timer and freshness calculations use a clock that advances through device sleep and ignores calendar-clock changes. On the same device boot, persisted clock anchors preserve that timeline across app restart. After reboot, or if boot identity cannot be read, restore falls back to calendar time.
- Partial preset intervals save their actual duration. Automatic phase catch-up preserves deadlines and records the final set once.
- Cooldown records contain two 60-second segments, with totals relative to the frozen workout duration. Resuming cooldown does not restart a new two-minute countdown.
- Delayed callbacks do not assign current HR to past boundaries. Early or paused cooldowns do not report a two-minute recovery result.
- Set HR statistics use the recorded active-time coordinate, unaffected by pauses. Averages and zone durations account for sample spacing and cap an unrefreshed value at three seconds.
- Original workout start/end dates and pause intervals survive export and Apple Health synchronization. Pause/resume events exclude pauses from Apple Health duration.
- Lock Screen elapsed time is rendered by the system, with a cap for preset/cooldown completion. Stale HR is hidden.

## Validation

Verified: 88 unit tests passed on iPhone 17 Pro Simulator (iOS 26.5); unsigned Release build for physical iOS succeeded; bundled privacy manifest and whitespace checks passed. A simulator UI session confirmed pause/resume and completion behavior. The signed Release archive for version 2.0.10 (build 11) passed signature verification and was uploaded to App Store Connect on September 14, 2026. Apple finished processing the build and accepted the App Store review submission; final verified status was **Waiting for Review**, with automatic release after approval retained.

Regression tests cover reference RMSSD arithmetic, RR decoding, corrupt packets, missing data, buffer pruning, late completion, connection changes, partial intervals, cooldown accounting, pause/resume, restart catch-up, rapid samples, history save failures, and Apple Health pause events.

Outstanding physical-device validation: compare exported RR intervals and RMSSD against a reference calculation using a physical chest strap. Repeat with screen lock, backgrounding, interruptions, contact loss, reconnects, and long workouts. Check real-device Apple Health duration and samples. Simulator tests validate software behavior, not BLE, sensor beat detection, or physical Lock Screen delivery. Force-quitting the app prevents new Bluetooth acquisition; missing measurements cannot be recovered by a timer.
