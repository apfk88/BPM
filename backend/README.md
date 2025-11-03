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

## Environment Variables

- `KV_REST_API_URL` - Required
- `KV_REST_API_TOKEN` - Required

