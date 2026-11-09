# BPM Sharing Backend

Next.js backend for live heart rate, workout controls, raw RR intervals, and share invitations. Uses Vercel KV (Upstash Redis) for persistence.

## Setup

1. Install dependencies:
```bash
npm install
```

2. Set up Vercel KV:
   - Go to your Vercel project dashboard
   - Navigate to Storage → Create Database → KV
   - Copy the connection details

3. Set environment variables in Vercel (or `.env.local` for local dev):
   - `KV_REST_API_URL` - Your KV endpoint URL
   - `KV_REST_API_TOKEN` - Your KV access token
   - `KV_REST_API_READ_ONLY_TOKEN` - (Optional) Read-only token

4. Deploy to Vercel:
```bash
vercel
```

Or connect your GitHub repo to Vercel for automatic deployments.

## Marketing reviews

Featured App Store reviews live in `public/index.html` inside `#reviews`, directly
after the chest strap section.
Add a `figure.review-card` to `.review-grid` for each additional verified review.
Show the review's star rating and complete verbatim text, with the public reviewer
name and an App Store source link. Omit review titles and dates.
The CSS grid automatically lays out multiple cards and stacks them on narrow screens. Reviews are static HTML, so
they remain visible without JavaScript or an App Store API request.

The first featured review is Loren Crow's five-star review (ID `14675064289`),
posted October 16, 2026 for version 2.0.12. Its full text, author, rating,
and date were verified against [Apple's US review feed](https://itunes.apple.com/us/rss/customerreviews/id=6754830191/sortBy=mostRecent/json)
on October 28, 2026. Preserve the full review verbatim, including its original spelling and punctuation;
verify new reviews before adding them. The full text was also checked against
the review screenshot supplied by the user. Reviews are curated manually, not synced automatically.

When changing `public/marketing-v2.css`, increment its `?v=` value in the HTML
because production serves stylesheets with an immutable cache header.

## API Endpoints

- `POST /api/share` - Create a sharing session; returns `{ code, token }`.
- `POST /api/share/beat` - Update heart rate and optional summaries using the host token.
- `POST /api/share/workout` - Publish an ordered workout snapshot with optional shared HRV state and acknowledge consumed controls; returns queued commands and server time. Requires the host token.
- `POST /api/share/rr` - Publish raw RR intervals with source stream identity, interval IDs, and monotonic timestamps. Requires the host token.
- `GET /api/share/[code]` - Read current heart rate, optional workout snapshot, and optional raw RR stream, with separate timestamps and server time. The host token is never returned.
- `POST /api/share/control` - Request an allowed workout or HRV action using the viewer code, UUID command ID, workout ID, and current control revision. A preset payload is accepted only for `loadPreset`.
- `DELETE /api/share` - End a session and remove its workout, RR stream, pending controls, and replay records. Requires the host token.
- `GET /join/[code]` - Render the invite landing page for a six-digit code.

Control actions are `work`, `rest`, `start`, `startIncludingHistory`, `pause`, `resume`, `end`, `reset`, `cool`, `loadPreset`, and `clearPreset`. Save remains local to the broadcaster. The server checks the snapshot's advertised actions, workout identity, revision, and five-second freshness; the broadcaster validates again before applying the command. Older snapshots without `allowedActions` retain only manual Work/Rest control support.

Optional `snapshot.hrv` carries the owner's HRV measurement state, readiness, countdown, result and BPM summary. It includes a UUID `revision`, `isPresented`, `state` (`idle`, `measuring`, `completed`, or `error`), `remainingTime` (0–120 seconds), optional `hrvValue` (0–5000 ms), optional `avgHeartRate`/`minHeartRate`/`maxHeartRate`/`currentBPM` (1–400 BPM), `readinessReason`, optional `errorMessage` (up to 512 characters), and `allowsRemoteControl`.

Additional controls are `hrvStart`, `hrvCancel`, and `hrvReset`. The host must explicitly enable `hrv.allowsRemoteControl`. Start requires an idle or completed measurement with readiness `ready`; cancel requires `measuring`; reset requires `completed` or `error`. These controls use the existing snapshot freshness, workout identity, control revision, idempotency and command-claim checks. The host includes its HRV revision in the top-level control revision. HRV actions stay out of `allowedActions` so older viewers can still decode workout snapshots. Hosts with missing or null `hrv` do not expose HRV controls.

Deploy this backend before releasing an app that publishes `hrv`: older backend validators reject unrecognized snapshot fields. The shared-HRV update was validated locally with all 29 backend tests, including the real Redis integration suite, and a production build. Its production deployment is not recorded here yet.

Redis scripts atomically handle updates, command claims, acknowledgements, and replay protection. Sessions retain their original 90-minute expiry; updates cannot extend that lifetime or recreate a deleted session. See [protocol and validation](../docs/live-workout-sharing.md).

Production verification on November 4, 2026: sharing deployment
`dpl_AH8UrWd8hoHG8bXidCZMKFfDjtdt` is READY at `https://bpmtracker.app`.
The sharing-only release passed 25 backend tests and 61 API checks on both its
staged URL and the live domain. Legacy sessions retained their original expiry.
Existing marketing and workout-recap code were preserved from the prior live
source. See the protocol document for the complete test and rollout record.

## App sharing workflow

Device contains Start Sharing, Copy, Share Invite, Stop Sharing, and friend-code entry. Sharing and viewing are mutually exclusive: broadcasting hides friend-code entry, and the service rejects self-joining. Joining from Home, Workout, or HRV confirms ending and clearing an existing local workout, then disconnects the local monitor before entering shared mode. Successful manual connections and invites close Device automatically; connection errors stay visible. When an established session ends, the viewer receives an alert and returns Home.

Both devices navigate independently. Explicit joins follow the broadcaster's Home or Workout screen, with Workout starting on the table page. Home → Workout also starts on the table page. Cold launches open Home while preserving restored sessions. Green heart/person and workout/person badges identify shared viewing, with no persistent code label or border.

Either person can start shared HRV. The monitor's device owns acquisition and calculation; both screens show its countdown and result. A new measurement opens HRV on connected devices, while cold restoration of an ongoing measurement keeps Home visible. Viewer Stop waits for the owner to confirm cancellation and keeps failures visible. Leave screen exits without stopping the owner; closing a completed result also leaves the owner's result intact. Only the owner can save. Raw RR transport remains available for older clients that perform a separate measurement; rounded BPM is never treated as beat data.

Share Invite sends `https://bpmtracker.app/join/{code}` through the native share sheet. Updated apps handle these Universal Links directly. The landing page's Open in BPM fallback uses `bpm://join?code={code}`. Both invite forms connect automatically, after any required local-workout confirmation. The page also shows the code and an App Store link. It uses no-store caching and no-referrer metadata/headers; Vercel Analytics is omitted from join pages.

The November 5 shared-HRV and navigation revision still needs its final app validation and production deployment status recorded. Earlier results in the protocol document apply to superseded revisions.

## Error Contract

All API errors now return a stable shape:

```json
{
  "error": "Human-readable message",
  "message": "Human-readable message",
  "code": "MACHINE_READABLE_CODE"
}
```

- `message` is the preferred field for clients to show to users.
- `code` is stable for programmatic handling (for example future quota enforcement).
- `error` is preserved for legacy compatibility.

## Environment Variables

- `KV_REST_API_URL` - Required
- `KV_REST_API_TOKEN` - Required

## Workout voice capture

`POST /api/workout-recap` accepts `{ "audio": "<base64 WAV>" }` and returns
`{ "title": "Short, specific title", "description": "Shorthand workout bullets" }`.
The iOS Save Workout form records locally, sends only on Send, and fills editable
fields. It does not upload heart-rate samples, HealthKit data, or previous notes.

Set `OPENAI_API_KEY` in the ignored `backend/.env.local` for local development and
as a server-only environment variable on the backend deployment. Never put it in
the app, Info.plist, UserDefaults, a `NEXT_PUBLIC_` variable, or source control.

Defaults:

- Transcription: `gpt-transcribe` (`OPENAI_TRANSCRIPTION_MODEL` override), with workout terminology hints and exact-number context.
- Title and description: `gpt-5.4` (`OPENAI_RECAP_MODEL` override).
- GPT-5.4 uses medium reasoning. Production input/output, evaluation, and feedback
  sharing are disabled. Keep sharing disabled for workout/health content; normal
  API charges apply instead of the shared-traffic complimentary allowance.
- Transcription costs
  $0.0045/minute, about $0.0045 for 60 seconds, at the rates checked October 26, 2026.
- Responses use `store: false`; this controls stored response state, not the
  project's training/data-sharing setting or abuse-monitoring retention.
  OpenAI's transcription endpoint does not retain audio; text requests may be
  retained in safety logs for up to 30 days, with legal/safety exceptions.
- The app requires explicit first-use consent before uploading and supports
  resetting that device-local permission in Settings. No automatic model fallback.

The server checks the WAV contents: mono 16 kHz, signed 16-bit PCM, 0.5–60 seconds,
under 1,930 KB, with a small silence check. The iOS recorder has its own 60-second
limit. The route accepts up to 2800 KB of JSON and has a 55-second provider timeout.
The model returns structured entries; the server renders each as `- Exercise: details`, or just `- Exercise` when no details were stated, so descriptions always use bullets.

Output guidance:

- Titles name the main movements or activity and a useful stated distinction, such as circuit format or incline. Usually 3–7 words, aiming for at most 50 characters (80 maximum). Skip generic "Workout" or "Session" wording. English lists use the Oxford comma.
- Descriptions use shorthand fragments: `3×8 @ 62.5 kg`, `4 sets`, or `20 min; 3 mph; 8% incline`. Preserve substantive details once, including uncertain counts, corrections, effort, and pain.
- Group an explicitly stated circuit or superset in one bullet. State shared rounds and each movement's prescription once; keep standalone exercises separate.
- Omit commentary about missing information, such as "reps not stated" or "unit unspecified". Never infer missing values or units; retain an unqualified load as given.
- Keep descriptions as short as the facts allow, without narrative filler, repeated context, calculated totals, or advice.

Example style for a stated 10-round circuit followed by four sets of hollow rocks:

```text
Chin-Up, Push-Up, and Squat Circuit
- Circuit: 10 rounds × (5 chin-ups, 10 push-ups, 15 squats)
- Hollow rocks: 4 sets
```

A failed request leaves the local recording available for retry. Dismissal,
discard, and successful generation delete the temporary recording.

Production requires the existing KV configuration. Atomic limits admit at most
20 requests per source IP per UTC day and 500 total per UTC day. IP-derived keys
are HMAC-hashed with a daily salt and expire; audio and transcript are never
written to KV or application logs. If KV is unavailable, the endpoint fails
closed. Local `next dev` can use bounded in-memory limits when KV is absent.
This is a public, rate-limited endpoint, not authenticated user access. The global
cap bounds usage but can be exhausted by abuse; app attestation or account auth
would provide stronger admission control if usage grows.

Run `npm test` for audio validation, API contracts, provider errors, structured
results and limit behavior. Run `npm run build` for production type/build checks.
Real provider testing requires a configured key. Start `npm run dev`, then point
a development app at it with the existing `BPM_API_BASE_URL` override. Release
apps use HTTPS at `https://bpmtracker.app`.

Sources:
- https://developers.openai.com/api/docs/guides/speech-to-text
- https://developers.openai.com/api/docs/guides/structured-outputs
- https://help.openai.com/en/articles/10306912-sharing-feedback-evaluation-and-fine-tuning-data-and-api-inputs-and-outputs-with-openai
- https://developers.openai.com/api/docs/models/gpt-transcribe
- https://developers.openai.com/api/docs/models/gpt-5.4
- https://help.strongapp.io/article/229-my-first-workout
- https://help.hevyapp.com/hc/en-us/articles/38279531346455-Set-Records-vs-Personal-Records

## Universal Links

`public/.well-known/apple-app-site-association` associates invite paths with
`5HW85B6746.kvamme.BPM`. Vercel sets `Content-Type: application/json` and a
five-minute cache. Serve this exact endpoint over HTTPS without redirects.
The iOS app includes `applinks:bpmtracker.app` and handles both browsing activity
and open-URL delivery. Valid invites connect automatically, with confirmation
before clearing an existing local workout. See the protocol document for validation.
