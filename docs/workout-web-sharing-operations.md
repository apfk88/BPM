# Private workout pages: configuration and operations

Hosting activated November 11, 2026 on `kvamme-team/bpm` at `https://bpmtracker.app`. Initial production deployment: `dpl_Co79oXYcG51oDkJ3tGLZtDkYgB9j`. The iOS changes have not been distributed. API contract: [workout-web-sharing-contract.md](workout-web-sharing-contract.md).

The private `bpm-workout-pages` Blob store is connected to production in `iad1`, alongside the functions. Existing Redis is configured with `noeviction`; a created page's metadata TTL was `-1` (no expiry). Production upload settings, separate random IP salt, cleanup secret, bundle ID, and the App ID prefix from the signed app's provisioning profile are configured. The global upload limit is 1,000/day. Cleanup runs at `17 */6 * * *` UTC; a manual Vercel Cron invocation returned HTTP 200 after promotion.

Real-storage checks preserved 1,779 synthetic readings in a 17,219-byte compressed object, rejected unauthenticated direct Blob access with HTTP 403, and verified viewing, link rotation, revocation, and origin-object removal. Real-device App Attest remains a native release check. Provider backup/recovery retention has not been independently established; no indefinite durability guarantee is implied by the absence of an application expiry.

## Activation configuration

Use a private Vercel Blob store, in the same US region as the functions where practical. The SDK always writes `access: private`; a public store is not an acceptable substitute. Existing Redis credentials are reused, but permanent pages use the independent `workout-pages:v1:` namespace. Verify Redis persistence, no eviction of permanent records, and the provider's backup/recovery policy before launch.

| Environment variable | Required value / purpose |
| --- | --- |
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | Existing server-side Redis connection. Do not expose them to the app/browser. |
| `BLOB_READ_WRITE_TOKEN` | Server credential for the connected **private** Blob store. The SDK also supports Vercel's connected-store OIDC setup where available. |
| `WORKOUT_PAGES_UPLOADS_ENABLED` | Exactly `true` to enable challenge/registration/create/update/activate. Unset or false keeps uploads and draft activation unavailable while existing viewing/management can operate. |
| `WORKOUT_PAGES_APP_ID_PREFIX` | `5HW85B6746`, verified against the signed app's production provisioning profile. |
| `WORKOUT_PAGES_BUNDLE_ID` | `kvamme.BPM`. Server-controlled, never supplied by the client. |
| `WORKOUT_PAGES_IP_SALT` | Independently generated random secret, at least 32 characters. Rate-limit keys contain salted hashes rather than raw IPs. Missing/short salt makes the API unavailable. |
| `CRON_SECRET` | Random secret for Vercel's scheduled cleanup authentication. `WORKOUT_PAGES_CLEANUP_SECRET` is an optional override for a separately operated scheduler. |
| `WORKOUT_PAGES_DAILY_UPLOAD_LIMIT` | Optional, default 1,000 verified content upload attempts/day across the feature, including staging. Allowed range 1–10,000. |
| `WORKOUT_PAGES_MINIMUM_BUNDLE_VERSION` | Optional minimum numeric leading build component when newer App Attest metadata provides a version. Defaults to 1. Older OS versions without this metadata remain supported. |
| `WORKOUT_PAGES_ALLOW_DEVELOPMENT_ATTESTATION` | Optional, exactly `true` only on a non-production local/preview environment. Production always rejects development attestations. |
| `WORKOUT_PAGES_BLOCKED_TERMS` | Optional pipe-separated extra text phrases. Up to 100 terms, each 3–120 characters. No AI moderation provider or extra content disclosure is introduced. |

Use a current supported Node runtime. Dependencies are pinned for Blob and receipt parsing; the lockfile fixes the installed App Attest verifier. The app's App Attest entitlement/configuration must be exercised on a physical supported device. Both Debug and Release use the production App Attest entitlement because both target the production backend. Apple explicitly supports [production App Attest during development](https://developer.apple.com/documentation/devicecheck/preparing-to-use-the-app-attest-service). A separately configured local/preview backend can accept development-environment keys; production never does. Keychain registrations are separated by the configured environment, backend URL, and owner.

## Privacy and access

Viewing requires the fragment key sent as an authorization header. Ownership requires a separate owner key. Redis contains hashes, object paths, management envelopes, attestation public keys/receipts, and counters, without workout text or measurements. Files are private objects. Application errors deliberately omit raw exception objects because storage errors can include signed URLs.

The server validates a one-time challenge, App Attest certificate chain, certificate validity period, nonce, App ID, credential ID, environment, and counter. It independently verifies the receipt's CMS signature and chain to Apple's pinned G3 root, App ID, attested public key, and five-minute freshness. Available newer OS extension metadata must indicate TestFlight, development signing, or App Store distribution (categories 2, 3, 4) and a valid build. Development signing is distinct from the App Attest environment: a Debug build still needs a production proof for the configured team and bundle. Legacy OS payloads without extensions remain accepted. Assertions bind the exact transmitted gzip bytes, method, pathname, owner, and challenge; the challenge and monotonic counter commit atomically. Stored development-environment keys are rejected during production assertion verification, even if a database was shared with a preview.

The client preserves the same generated key and challenge hash after Apple's temporary `serverUnavailable` error, as [Apple requires](https://developer.apple.com/documentation/devicecheck/dcappattestservice/attestkey(_:clientdatahash:completionhandler:)). An unfinished expired challenge starts a new key; a completed registration whose response was lost resubmits its saved proof so the server can recover its prior success. Only actual challenge expiry is labeled expired. Rejected proofs and environment mismatches retain their distinct errors. Server challenge expiry and replay checks remain enforced.

Receipts are retained for verification provenance; periodic Apple fraud-metric refresh is not implemented or claimed. App Attest is complemented by upload/IP/global limits. It does not establish a human identity, and blocking an anonymous owner cannot guarantee that a determined person never creates a new installation.

The private viewer has no analytics or third-party script requests and carries no workout content in its HTML shell. New links include a separate `p` capability for a fetched workout-card preview; the full-data view key remains in the fragment. The HTML contains an image endpoint URL only when that capability is supplied. Preview authorization never grants access to JSON or owner operations. Legacy fragment-only links retain generic fetched previews. The native share sheet also supplies the exact selected card locally.

The preview endpoint renders a 1080 × 1350 PNG from the existing private workout object, without another stored image, upload, or database migration. It includes title/date/chart/duration/average/maximum, not description or raw samples. At most 1,000 plotted points preserve signal gaps. The renderer makes no external font, emoji, or image requests: accented Latin titles are transliterated, unsupported glyphs omitted, and all-unsupported titles use “Workout.” The private page and native card retain the original title. The image response and every error are no-store/noindex. Deletion or rotation during storage access or image rendering is rechecked before bytes are returned; receiving apps can still retain previews already fetched.

No external log/trace drains are configured. The application does not log request bodies or authorization/proof headers and emits only a generic error on provider failures. Normal Vercel request metadata can contain page IDs and the image-only `p` query capability; the full-data fragment key is not sent in the URL. Treat preview URLs as sensitive, avoid logging them, and recheck platform logging if tracing or drains are added. Review provider backup retention separately from immediate access revocation.

Saved workout pages (`/w/*`) and live-sharing invitations (`/join/*`, including shared HRV) carry both robots metadata and `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet`. Their `/api/workout-pages` and `/api/share` endpoints and subpaths carry the response header too. The join page also sets it in server-side rendering so its `/_next/data/.../join/*.json` representation is covered. Public marketing pages remain indexable. Do not add a robots.txt Disallow for private pages: crawlers need to read the noindex directive. See [Google's noindex guidance](https://developers.google.com/search/docs/crawling-indexing/block-indexing).

## Cleanup and deletion

`GET` or `POST /api/workout-pages/cleanup`, authorized with the configured cleanup secret, drains up to 100 queued objects. Vercel Cron supplies `Authorization: Bearer <CRON_SECRET>`. The configured six-hour schedule retries failed removals; repeated failures remain queued rather than restoring access.

Every object gets a durable cleanup intent **before** upload. Publishing a completed object removes that intent atomically with metadata publication. Abandoned uploads become eligible after 15 minutes, safely beyond the two-minute publish lease. Updates atomically swap the object pointer and queue the prior version. Deletion revokes access first and makes a best-effort immediate cleanup attempt; later scheduled attempts finish any remaining object deletion. Deleted metadata remains a small tombstone to prevent a delayed retry from recreating a deleted page.

Background uploads use separate `stage:<pageID>` metadata with a 24-hour expiry. A completed draft stays private and cannot alter an active page until the explicit activation request. Its Blob object remains queued for deletion at expiry; the six-hour cron removes it afterward, retrying storage failures. Replacing a draft queues its prior object immediately. Activation atomically swaps the active pointer, removes the draft and its cleanup intent, and queues the previous active object. Cleanup atomically invalidates an expired draft before deleting its object, preventing a concurrent activation from publishing an object being removed. Legacy clients that omit `staged` retain immediate publication.

Vercel's authenticated Blob cache can retain deleted bytes for up to a minute after origin deletion. Viewer access remains revoked immediately because every response checks authoritative page metadata. Verify physical deletion with a private `get(..., { useCache: false })` and object listing; a cached read is not an origin-deletion test. See [Vercel Blob caching](https://vercel.com/docs/vercel-blob#caching).

Deleting an unpublished page records an owner-scoped cancellation for 24 hours, including when the original create request has not reached storage yet. Creates check it before work and atomically before publication. Requests have a 60-second duration cap, so this cancellation outlives any in-flight request. The client must clear its pending entry only after deletion is acknowledged and must never retry a canceled create. Unknown-page cancellations expire and are capped at 100/owner/day and 5,000 globally/day to prevent an unauthenticated permanent-record attack; cancellation keys from another owner cannot preempt the legitimate owner.

## Reports, moderation, and emergency controls

The viewer's report action includes only the page ID, not its view key. The operator can locate/revoke a reported page with server credentials. Narrow local rules reject explicit threats, high-confidence slurs, and explicit sexual solicitations; normal training terms such as snatch, deadlift, assault bike, chest, and killer workout remain allowed. The filter cannot judge all context, so reports and uploader blocking remain required operational work.

Compile the operator helper with `npx tsc -p tsconfig.test.json`. Run it only from a trusted server environment with the intended project's credentials already loaded. It prints aggregate usage or a short outcome, never page contents or access keys:

```sh
node .test-build/scripts/workout-pages-admin.js usage
node .test-build/scripts/workout-pages-admin.js usage 2026-11
node .test-build/scripts/workout-pages-admin.js remove PAGE_ID
node .test-build/scripts/workout-pages-admin.js block PAGE_ID
node .test-build/scripts/workout-pages-admin.js pause
node .test-build/scripts/workout-pages-admin.js resume
node .test-build/scripts/workout-pages-admin.js cleanup
```

`remove` revokes the reported page; `block` also prevents its owner from registering devices or uploading more content. These are operator-only code paths, with no public admin endpoint. `pause` stops new content uploads while retaining existing reads, deletion, and link management. It is separate from Vercel's account-wide project pause.

## Usage and cost controls

Monthly Redis hashes report pages created/updated/deleted, staged uploads, successful publishes, compressed bytes uploaded/read, authorized object reads (approximate views), authorized preview reads (`previews`, `previewCompressedBytes`), link rotations, and object removals. A stage counts its uploaded bytes once; activation counts publication without charging the bytes again. They contain no page IDs or workout content. Read counters are best-effort and can include a read rejected by the final revocation check. Compressed-byte counters approximate payload volume, excluding rendered PNG bytes; actual Vercel billing also includes asset traffic, transfer legs, requests, and compute. They are not invoice figures.

Initial limits are 30 verified content upload attempts/owner/day, 300/IP/day, and the configured global daily limit, including staged uploads. Activation rechecks blocking/pause controls but does not consume another upload allowance. Public attempts are limited to 300/IP/minute; a page to 1,200 authorized data reads/hour and a separate 120 authorized preview renders/hour. Invalid credentials never consume the per-page allowance or read Blob. Challenge and registration endpoints have additional limits. Repeated identical shares or draft retries reuse the object, although verified retry attempts still count toward admission limits.

Team spending controls were inspected; no account-wide billing threshold was changed. A dedicated incremental-feature spend alert has not been configured. Compare aggregate counters with actual Vercel/Redis charges and adjust limits using measured payloads. The pause control protects new writes; existing reads still generate usage. Neither these limits nor the planning model guarantee a hard ceiling against distributed traffic.

## Validation

Run the full backend suite with a local Redis executable available:

```sh
BPM_TEST_REDIS_SERVER=/path/to/redis-server npm test
```

For browser integration, first run the ordinary Next.js viewer on localhost port 3013. Then run this separate loopback-only harness, which uses isolated Redis, memory-backed private objects, and the real production HTTP handler. It has no route/header/environment switch in the deployed application:

```sh
npx tsc -p tsconfig.test.json
BPM_TEST_REDIS_SERVER=/path/to/redis-server node .test-build/tests/workout-page-browser-server.js
```

The harness prints a synthetic viewer URL on port 3014 and writes synthetic management credentials to `/private/tmp/bpm-workout-page-browser-fixture.json`, mode 0600. It refuses to run in a Vercel or production environment. Shut it down after testing.

Local verification includes Redis concurrency, create/update retries, viewer/owner separation, revocation during a Blob read, deletion racing updates, orphan cleanup, gzip limits, actual assertion signatures/replay, extension handling, and Apple's signed receipt fixture. Private Vercel Blob reads/deletes and hosted HTTP/browser behavior were exercised with synthetic data. Real-device App Attest registration and the complete signed-app upload path remain native release checks; administrative fixture seeding is not evidence of a physical App Attest upload.
