# Measurement accuracy audit

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
