# Inline workout voice capture

Implemented and checked on October 26, 2026. The backend and privacy update are
deployed to production at https://bpmtracker.app. No commit, push, App Store
submission, or physical-device installation was performed. Existing unrelated
workout recovery, chart, timer, and Live Activity changes were retained.

## Behavior

Workout Type opens at full height with configured favorites first, followed by all
workout types alphabetically in the same scrollable list. Selecting either a
favorite or another type opens Save Workout directly.

Save Workout now opens at full height with its title, description, and an AI voice
button in one form. Record up to 60 seconds, then Send. Sending during recording
stops the captured audio, then requests first-use AI permission before upload. At 60 seconds recording stops and waits for
Send. The loading state fills the same editable fields on success. There is no
recap navigation screen, transcript editor, Prepare Draft step, or Use Draft step.
Undo AI changes restores the prior fields. Errors and request cancellation keep
the recording available to retry. Save is disabled during recording and loading.
Manual entry remains available without AI.

The recording controls share one row: Stop changes to Record again after capture,
and Send uses a borderless icon-and-text button. There is no separate discard row.
Recording again replaces the audio while preserving the title and description.

The iOS app records mono 16 kHz PCM WAV and posts it to `/api/workout-recap` on the
existing backend URL. The API key lives only in the ignored backend environment
file or server environment. Only the recording is uploaded. Measured heart rate,
HealthKit records, previous notes, and workout history are not attached.

The backend transcribes with `gpt-transcribe`, then uses `gpt-5.4` to produce
strict JSON with a title and exercise entries. The prompt asks for a brief descriptive
title with Oxford commas and structured exercise entries preserving numbers, units,
corrections, uncertainty, and discomfort. The server formats the entries as
exercise-by-exercise bullets with strength sets/reps/load and cardio duration/distance
when stated. Unknown units, reps, and circuit details are never invented. It permits rewriting and removes filler.
It does not claim factual infallibility; users review both fields before Save.

GPT-5.4 uses medium reasoning. Production model-improvement sharing was disabled
and verified after reload on October 26, 2026. Normal API charges apply; the
shared-traffic complimentary allowance is no longer used. GPT-Transcribe costs
$0.0045 per minute, approximately $0.0045 for 60 seconds, using pricing checked
on October 26. There is no automatic model fallback.

The form requires explicit first-use permission before upload and retains the
recording locally when permission is cancelled. Settings can reset the saved
permission; it is device-local and not part of iCloud preference sync. The
policy discloses transient audio processing, no model training, and possible
transcript/result retention in OpenAI safety logs for up to 30 days with legal
or safety exceptions. `store: false` disables stored response state, not those
logs. The microphone purpose string now correctly states 60 seconds.

## Verification

- iOS simulator build passed. Deployment target remains iOS 17.
- Nine focused Swift tests passed: microphone denial, cancellation during
  permission, interruptions, automatic 60-second stop, audio ownership/file
  cleanup, response validation, detailed generated text, and server errors.
- The UI regression test passed: Start recovery/cancel, inline record/stop,
  rerecording preserving existing fields, Send/loading, cancel/retry, generated
  fields, Undo, editing, explicit Save, relaunch, and saved history persistence.
  This test uses actual simulator recording controls with a DEBUG/simulator-only
  AI result fixture; it does not represent real transcription quality.
- Eight backend tests passed: deterministic bullet formatting, WAV format/duration/size/silence checks, structured
  output validation, two-stage provider contract, empty speech, refusal/provider
  failures, limits, and HTTP errors. Provider and KV failure scenarios are local
  tests, not production service fault injection.
- `npm run build` and `git diff --check` passed.
- A real synthetic speech recording went through the local Next.js endpoint and
  both OpenAI stages using the saved BPM key. HTTP 200 in 4.71 seconds. Input
  included 3 sets of 8 squats at 62.5 kg, a correction to 7 on the last set, 10
  push-ups, a 5-minute walk, knee discomfort, and keeping the same weight.
  Output title: **Squats, Push-Ups and Walk**. The detailed description retained
  those facts and correctly applied the last-set correction. This is one
  synthetic case, not an accuracy benchmark for real gym recordings.
- Initial real requests returned `credit_balance_exhausted`. After the user
  added credit, the same flow succeeded.

Focused tests: `/private/tmp/BPMVoice-Final.xcresult`. Full-height layout regression:
`/private/tmp/BPMVoice-Layout-Final.xcresult`. UI screenshot exports are under the ignored
`build/workout-voice-validation/` folder. The first simulator test tool run timed
out; direct xcodebuild runs succeeded. Two optional simulator diagnostic collections stalled after the cases completed and were stopped; the final run exited 0 with TEST SUCCEEDED. Early UI test failures were caused by the
system permission sheet query and a loading-state query, both corrected. The full-height test also needed to compare saved notes after the existing whitespace trimming. A visual
review also found the former medium sheet clipped the lower controls; the save
form now uses the large detent.

## Deployment verification and remaining release checks

Production deployment `dpl_AJtmG4dv9uiqAERjJPGg8gcGhUBx` was staged, verified, and
promoted on October 26, 2026. It contains the local backend changes based on
commit `88e4a8e`, deployed from an isolated source directory. The saved OpenAI key
was installed as a production Secret; existing KV settings were retained.
A synthetic 13.99-second recording returned HTTP 200 with the expected title and
detailed notes in 5.70 seconds on the staged deployment and 4.62 seconds through
the public endpoint. Production admission through KV succeeded; exhaustion and
failure behavior remain covered by local tests rather than a production load test.
The public privacy page returned HTTP 200 with the AI voice disclosure. The
simulator app was relaunched without its test fixture and uses the production URL.

The subsequent 60-second/Astra update was promoted as deployment
`dpl_8KzmPLNC89HSz9tfXWjrT8ERHHGh` on October 26, 2026. Eight backend tests and
nine focused Swift tests passed (`/private/tmp/BPM-Voice60s.xcresult`); the iOS
simulator and production backend builds passed. The updated app was installed
on the active iPhone 18 Pro simulator. This does not represent a physical-device
or App Store installation.

A synthetic workout recording padded to exactly 60 seconds returned HTTP 200
in 7.11 seconds on the staged deployment and 7.35 seconds through
`https://bpmtracker.app/api/workout-recap`. Both returned exercise bullets and
Oxford-comma titles, preserved a corrected 5% incline, and left the unstated
deadlift weight unit unspecified. The staged result retained 204 snatches;
the public result returned 200. Earlier isolated transcription inspection also
found the 204-to-200 error, so workout terminology hints improve some results
but do not establish reliable exact-number transcription. Numeric review before
Save remains necessary. These synthetic cases are not an accuracy benchmark.
The public privacy page also returned HTTP 200 with the 60-second limit.

After the user supplied the account's actual eligibility list, the recap model
was corrected to `gpt-5.4`, using medium reasoning. Production deployment
`dpl_7TpUDtAnqtxdd54ghseajiJvSS5v` replaced the Astra deployment on October 26,
2026. Eight backend tests and the production build passed. A synthetic recording
returned HTTP 200 in 8.94 seconds on the staged build and 6.55 seconds through
the public endpoint, preserving 62.5 kilograms, reps of 8/8/7, knee discomfort,
exercise bullets, and the title "Squats, Push-Ups, and Walk". The production
environment had no model override. The account-specific eligibility screenshot,
rather than a general eligibility page, is the basis for this model selection.

Logging conventions were checked against Strong's exercise/set/weight/rep model
and Hevy's strength, duration, and distance record types. The prompt uses stated
sets × reps @ load for strength, duration/distance/speed/incline for cardio, and
exercise-specific effort and notes. Missing values are never filled by assumption.

Noisy gym audio, Bluetooth microphone routing, real calls/backgrounding, and
alert coexistence still need physical-device verification. The simulator emitted
an AVAudioSession advisory about synchronous activation on the main thread; no
freeze was observed.

The privacy release update was promoted as `dpl_4v2GF94xH7NFW63CnbtnjcB7pEto`
on October 26, 2026. The public privacy page returned HTTP 200 and matched the
local file. App Store Connect published Health, Fitness, and Other User Content
for App Functionality, linked to identity and not used for tracking. Existing
analytics disclosures were preserved. Raw audio is processed transiently by the
transcription endpoint; retained transcript/result content drives the new labels.
The app privacy manifest matches these disclosures.

The consent regression run passed nine unit tests and one UI test in
`/private/tmp/BPM-VoiceConsent.xcresult`. It checks cancelling the first-use
confirmation, approving it, subsequent use, and resetting permission in Settings.
Version 2.0.13 (14) archived and exported successfully. Release status and reviewer
instructions are recorded in `docs/app-store/2.0.13/release.md`.

Sources checked:
- https://developers.openai.com/api/docs/guides/speech-to-text
- https://developers.openai.com/api/docs/guides/structured-outputs
- https://developers.openai.com/api/docs/models/gpt-5.4
- https://developers.openai.com/api/docs/models/gpt-transcribe
- https://help.strongapp.io/article/229-my-first-workout
- https://help.hevyapp.com/hc/en-us/articles/38279531346455-Set-Records-vs-Personal-Records
- https://help.openai.com/en/articles/10306912-sharing-feedback-evaluation-and-fine-tuning-data-and-api-inputs-and-outputs-with-openai
- https://vercel.com/docs/headers/request-headers
