# BPM sound effects

The local app now uses ten bundled WAV files for BPM threshold crossings, spoken zones, separate work/rest bells, and HRV completion. Workout completion is a separate event that reuses the rest bell. Playback runs through one shared player, with no runtime ElevenLabs requests.

This inventory reflects the local source on October 28, 2026. Durations are measured from the bundled files, not physical-device playback. The simulator build, launch, and 172 unit tests passed; physical-device listening remains pending.

## Current sounds

| Sound | Trigger | Asset and duration | Control |
| --- | --- | --- | --- |
| BPM threshold up | A valid local reading reaches or exceeds the threshold after being below it, or after alert state resets. | `bpm-threshold-up.wav`: rising two-note cue, 0.30 seconds. | Settings → BPM Alert. Off by default; threshold defaults to 160 BPM. |
| BPM threshold down | A valid local reading drops below the threshold after being at or above it. | `bpm-threshold-down.wav`: matching falling two-note cue, 0.30 seconds. | Same BPM Alert setting. |
| Zone entry | A valid local reading enters a selected zone, from either direction or after alert state resets. | One spoken “Zone one” through “Zone five” clip, about 0.76–0.86 seconds. | Settings → Zone Alert → Selected Zones. Alerts off by default; zones 3, 4, and 5 selected by default. |
| Work begins | The initial preparation countdown finishes, or a timed rest phase ends. | `work-begins.wav`: higher bell with its full ringing tail, 2.00 seconds. | Preset Play Sound toggle. On by default for new and built-in presets. |
| Rest or cooldown begins | A timed work phase enters rest, or an active preset enters cooldown, including a manual skip into cooldown. | `rest-begins.wav`: deeper bell, 1.70 seconds. | Same preset Play Sound toggle. |
| Workout completes | The final preset work interval ends without cooldown, or the two-minute preset cooldown finishes. | The same 1.70-second rest bell, through a separate `workoutComplete` event. | Same preset Play Sound toggle. |
| HRV completes | The two-minute measurement finishes and passes data-quality and RMSSD calculation checks. | `hrv-complete.wav`: resonant meditation finish, 5.35 seconds, plus haptics below. | No dedicated sound toggle. |

Sources: [shared player and asset mapping](../BPM/AlertSoundPlayer.swift), [threshold and zone decisions](../BPM/HeartRateAlerts.swift), [alert settings](../BPM/SettingsView.swift), [preset transitions](../BPM/TimerViewModel.swift), [preset defaults](../BPM/TimerPreset.swift), [HRV completion](../BPM/HRVMeasurementViewModel.swift).

### Spoken zones

| Destination | Asset | Spoken label | Duration |
| --- | --- | --- | --- |
| Zone 1 | `zone-1.wav` | Zone one | 0.783 seconds |
| Zone 2 | `zone-2.wav` | Zone two | 0.763 seconds |
| Zone 3 | `zone-3.wav` | Zone three | 0.813 seconds |
| Zone 4 | `zone-4.wav` | Zone four | 0.793 seconds |
| Zone 5 | `zone-5.wav` | Zone five | 0.863 seconds |

Entering a lower selected zone uses the same destination label as entering it from below. A jump from zone 1 to zone 4 requests “Zone four” only. Remaining in a zone produces no repeated cue. The existing `playZoneCount` method now selects one spoken asset; it no longer repeats pulses.

### Preset transitions

| Event | Entering state | Sound |
| --- | --- | --- |
| Initial preparation countdown finishes | First work interval | Work bell |
| A nonfinal work interval ends | Rest | Rest bell |
| A rest interval ends | Next work interval | Work bell |
| Final work interval ends, cooldown enabled | Two-minute cooldown | Rest bell |
| Active preset is manually skipped into cooldown | Two-minute cooldown | Rest bell |
| Final work interval ends, cooldown disabled | Workout complete | Rest bell via the completion event |
| Two-minute preset cooldown ends | Workout complete | Rest bell via the completion event |

Timed cues are delivered only when processed from zero to one second after their scheduled boundary. When several boundaries are reconciled together, only the latest resulting cue is considered. This prevents stale announcements and duplicate rest/work sounds for a zero-length rest phase. A final work interval that completes the workout uses the completion event; it does not announce another work interval.

Preparation countdown ticks, pause/resume, manual set logging, and stopping early without entering a recovery phase remain silent. Manually entering cooldown from an active preset plays the rest bell because recovery begins. A freestyle workout's cooldown remains silent. Any action that first reconciles a just-reached timed boundary can still trigger that boundary's normal cue.

Source: [TimerViewModel.swift](../BPM/TimerViewModel.swift), especially `completePersistedPresetCountdown`, `advancePresetPhase`, `beginCooldown`, `requestPresetSound`, `deliverPresetSound`, and `refreshTiming`.

## Playback behavior

- **One shared player.** `AlertSoundPlayer` uses `AVAudioPlayer` to play the bundled assets. BPM pairs and spoken labels are complete files. There is no runtime tone synthesis or system-sound fallback; missing or unreadable assets are logged and skipped.
- **Phase and HRV priority.** A new work, rest, workout-completion, or HRV cue stops current playback and clears queued alerts before starting. A newer cue in this priority group can also replace an earlier one in the same group.
- **BPM and zone alerts queue whole cues.** They do not interrupt one another. The queue keeps only the latest pending BPM cue and latest pending zone cue. A duplicate of the currently playing cue is suppressed; queued alerts older than three seconds are discarded before playback.
- **Recording takes priority for every sound.** Workout dictation stops current playback and clears the queue. New cues, including HRV completion, are suppressed while recording and are not replayed afterward. The shared player hands audio-session ownership to recording so an old completion callback cannot deactivate the recorder's session.
- **Interruptions clear playback.** An audio interruption, removal of the current output device, or media-services reset stops the current sound and clears queued cues. Canceled sounds do not resume automatically.
- **Silent mode and other audio.** The shared player requests `.playback` with `.duckOthers`, intended to play through silent mode and temporarily lower other audio. After the last cue finishes, it deactivates its audio session with `.notifyOthersOnDeactivation`. There is no in-app volume slider or global mute. Background audio is declared; routing, background delivery, and restoration of other audio still need physical-device verification.
- **Local readings only.** BPM and zone alerts run from local heart-rate updates, even outside an active workout. Viewing a friend's shared readings suppresses them and resets alert state. Invalid or missing heart rate also resets state. The first valid reading afterward can request an up cue and/or a selected-zone cue.
- **No threshold smoothing or dwell requirement.** The threshold comparison remains `>=`. Repeated crossings can request alternating cues on successive readings. Zone decisions have no hysteresis or minimum dwell time; the playback queue only limits obsolete pending audio.

Sources: [AlertSoundPlayer.swift](../BPM/AlertSoundPlayer.swift), [WorkoutDictation.swift](../BPM/WorkoutDictation.swift), [HeartRateBluetoothManager.swift](../BPM/HeartRateBluetoothManager.swift), [HeartRateAlerts.swift](../BPM/HeartRateAlerts.swift), [Info.plist](../BPM/Info.plist).

## Haptics and silent events

| Event | Current feedback |
| --- | --- |
| HRV measurement completes successfully | Completion sound plus a success notification haptic, followed by a medium impact 150 ms later. Recording can suppress the sound without changing the haptics. |
| HRV result saves successfully | Success notification haptic and visual confirmation. No sound. |
| A saved workout is confirmed after the save sheet dismisses | Success notification haptic and visual confirmation. No sound. |

Sources: [HRVMeasurementViewModel.swift](../BPM/HRVMeasurementViewModel.swift), [HRVMeasurementView.swift](../BPM/HRVMeasurementView.swift), [ContentView.swift](../BPM/ContentView.swift).

There are no app-authored sounds for Bluetooth connection/disconnection, sensor-contact warnings, ordinary button taps, sharing, errors, recording start/stop, or AI recap completion. The HRV countdown and failed/canceled measurements have no completion sound. There is no heartbeat tick or background music. The Live Activity extension and web backend contain no sound playback. System UI and accessibility speech are outside this inventory.

## Bundled assets and audition history

All ten files in [BPM/Sounds](../BPM/Sounds) are mono, 44.1 kHz, 16-bit PCM WAVs. Their durations, source files, edits, and SHA-256 hashes are recorded in the [integration manifest](../artifacts/sound-effects/2026-10-28/integration/manifest.json). The bundle copies match those hashes.

- The [first audition](../artifacts/sound-effects/2026-10-28/first-pass/manifest.json) established the BPM pair and compared short pulses and completion cues.
- The [second audition](../artifacts/sound-effects/2026-10-28/second-pass/manifest.json) supplies the louder BPM pair, selected HRV finish, and retained “Zone three” recording. Zones one, two, four, and five were generated in the same voice for integration. The bare numbers, double gym bell, and electronic interval beeps were not selected.
- The [third audition](../artifacts/sound-effects/2026-10-28/third-pass/manifest.json) compared natural bells. Its tubular-bell source became the [work/rest pair](../artifacts/sound-effects/2026-10-28/fourth-pass/manifest.json), edited an octave apart. The 1.70-second rest cue is retained.
- The [revised work cue](../artifacts/sound-effects/2026-10-28/fifth-pass/manifest.json) restores the bell decay and adds a diffuse reverb tail, extending work to 2.00 seconds while preserving its pitch and first 100 ms. This is the bundled work cue.

## Verification

Verified on October 28, 2026 with the BPM scheme on the iOS 27 iPhone 18 Pro simulator:

- Build and launch succeeded; a runtime UI snapshot confirmed the workout screen.
- All 172 unit tests passed, with no failures or skips. Coverage includes [whole-cue playback, queueing, session cleanup, and recording suppression](../BPMTests/AlertSoundPlayerTests.swift), [threshold and zone decisions](../BPMTests/HeartRateAlertStateTests.swift), [preset sound routing](../BPMTests/TimerSoundRoutingTests.swift), and [HRV completion](../BPMTests/HRVCompletionSoundTests.swift).
- All ten WAVs in the built app match the integration-manifest hashes, have the expected formats and durations, and fully decode as PCM audio.
- `git diff --check` passed. Existing test warnings about recorder isolation and unused `synchronize()` results remain unrelated to this integration.

Physical-device listening remains required through the iPhone speaker and Bluetooth headphones, including silent mode, background/lock-screen use, and music playing. Check both threshold directions, all five spoken zones, the initial work cue, every preset transition, manual skip into cooldown, silent manual actions, successful HRV completion, simultaneous alerts, dictation, and audio interruptions. Confirm other audio returns to normal volume after the last cue.
