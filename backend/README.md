# BPM Sharing Backend

Simple Next.js API backend for sharing heart rate data. Uses Vercel KV (Upstash Redis) for persistence.

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

## API Endpoints

- `POST /api/share` - Create a new sharing session, returns `{ code, token }`
- `POST /api/share/beat` - Update heart rate (requires `token` and `bpm` in body)
- `GET /api/share/[code]` - Get latest heart rate for a share code, returns `{ bpm, timestamp }`

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
`{ "title": "Brief descriptive title", "description": "Detailed workout notes" }`.
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
The model returns structured exercise entries; the server renders each as `- Exercise: details`, so descriptions always use bullets. English titles use the Oxford comma. Strength entries use stated sets, reps, and load; cardio entries use stated duration, distance, speed/pace, and incline. Missing units or reps are never inferred.

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
