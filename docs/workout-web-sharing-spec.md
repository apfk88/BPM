# Private workout pages

Design specification, November 11, 2026. The local implementation now follows this design. See [configuration and operations](workout-web-sharing-operations.md) and [validation status](workout-web-sharing-validation.md) for activation requirements and remaining release checks. The original feature is deployed; the validation record identifies later refinements and their release status.

Add an optional private webpage to any saved workout share. BPM uploads a purpose-built workout export once; the browser renders the detailed chart, statistics, zones, and downloads. Pages have no automatic expiry. Users can delete them or replace their links.

At the current 400 monthly and 40 daily active users, a conservative model puts usage around $3–4/month before credits if every daily user uploads every day. Keeping old files is inexpensive. The important controls are explicit consent, durable deletion authority, accurate measurement handling, and bounded uploads.

## Sharing experience

Add an unchecked **Include private workout link** option to the existing share drawer. Keep the choice while navigating between formats and the card editor, but default it off for each new sharing session. The checkbox and supporting sentence occupy the same space in both states, so toggling never shrinks the chart or card preview. The portrait drawer opens at a compact, stable 700-point height and reserves a 355-point carousel for cards up to 260 points wide. Share sits 12 points below the disclosure rather than being pushed to the screen bottom. Content scrolls on shorter screens; landscape and accessibility text use the large sheet.

**Share Chart** and **Share Stats** export the full current preview and open the native share sheet directly. A smaller **Customize** button beside Share opens the existing editor for those two card formats. Text and logs show only Share. Accessibility text sizes stack the actions. A successful share closes the drawer; cancellation preserves the current screen and its edits.

Always show this supporting copy: “Anyone with the link can view and download your workout until you delete it.” There is no expanding disclosure or Review page. Enabling the option starts a private background upload while the user keeps choosing formats or editing the card. That draft cannot be viewed or downloaded and expires after 24 hours unless the final Share action activates it. Unchecking the option or closing the drawer does not activate it.

The page includes the full saved workout, its title and description, and its calendar date. Exact workout time is omitted in this share flow. The published calendar day stays stable across resharing, recovery, and page-detail edits. A card's cropped range and card-only title remain separate from page contents. Shared title/description can be edited later in Settings → Shared Pages without changing the saved workout.

1. Choose Chart Card, Stats Card, Plain Text, or Logs, as today.
2. Optionally include the private page. Save management credentials and an encrypted pending upload locally before starting the background upload.
3. Press the final Share button. If needed, wait for the background upload or retry it. Show “Uploading workout…” while sending data, then “Preparing link…” while activating it; keep the progress text readable on the Share button.
4. After the server confirms activation, finalize the local entry and open the native share sheet. Card sharing sends one URL with the exact selected PNG supplied through native link-preview metadata. Text and log formats retain their contents plus the link.
5. On failure, offer Retry or Share without link. Never silently omit a requested link.

Repeated sharing reuses an existing unchanged page. A changed shared export requires an explicit Update page action; editing a local workout does not silently republish it. Use a stable page URL across updates. A cancelled native share sheet can leave a successfully created page online, because the app cannot reliably infer whether a recipient already received it. Show it in Shared Pages with a delete action.

Show a Private link badge on the saved workout in History. Its detail screen provides the URL, Open, Copy, Manage, and Delete; Settings → Shared Pages remains available independently of workout history. Pending uploads and pending deletions have status and retry controls but no usable link. Card sharing supplies a single URL and the selected image as native metadata. Receiving apps decide whether to use that image or fetch the default full-workout chart card from the webpage. Test Messages and Mail; exact cropped, styled, or stats-card previews are not guaranteed across destinations.

## Webpage

Use BPM's existing visual identity, with a mobile-first layout that also works on desktop. No account or app installation is needed to view a page.

| Area | Initial behavior |
| --- | --- |
| Header | Workout calendar date, shared title, description, duration, optional exact time; older pages without dates remain supported |
| Summary | Average, minimum and maximum heart rate; recorded recovery result; estimated calories when available |
| Heart-rate chart | Touch scrub or mouse hover; active time and BPM readout; zoom, click-drag or touch-drag pan when zoomed, arrow pan controls, and reset; visible work/rest/cooldown boundaries and pauses |
| Zones | Duration and percentage in each recorded zone, with captured BPM thresholds where available; show unmeasured/unassigned time separately |
| Sets | Work/rest/cooldown table with duration and available HR statistics; selecting a row focuses that chart interval |
| Downloads | Download workout JSON and heart-rate CSV; sets CSV where useful |
| Footer | Private-link explanation, report/contact action, BPM attribution, privacy link |

Use keyboard-accessible chart controls and a readable data summary. Preserve sensor-loss gaps; do not draw a continuous measured line through them. Percentages must state their denominator. Calories remain labeled estimates. Omit unavailable metrics instead of displaying zero. Do not add workout HRV unless it was actually recorded.

The browser fetches the workout once. Scrubbing, zooming, panning, and file generation run locally in the browser. There is no polling or server request per chart interaction. Generate downloads from the fetched export, so CSV files need no extra storage or read.

## Data contract and fidelity

Create a versioned allowlisted export, separate from `WorkoutRecord.jsonString()`. The current generic JSON export contains local identifiers and HealthKit synchronization metadata that do not belong on the page.

Include shared title/description; saved summary metrics; all available HR samples; relative wall-clock and active-workout offsets; pauses; sensor-invalidity boundaries; work/rest/cooldown segments; zone durations and resolved boundaries; and data-quality metadata. Use fractional-second precision or integer milliseconds. Store the export/schema and calculation versions so later web changes do not silently reinterpret older measurements.

Exclude local workout and set UUIDs, HealthKit UUIDs/sync status/errors, device identifiers, demographic/profile inputs, audio, and unrelated history. Use fresh page-local indices for sets. Exact timestamps leave the device only when selected. HealthKit-imported weight, age, sex, resting HR, and VO2 max remain local; the page uses recorded summary values rather than those inputs.

Workouts currently save sensor-event HR samples, not beat-to-beat RR logs. Label downloads **Recorded heart-rate data**. Do not claim they contain RR intervals, ECG, or every original sensor packet.

Add `sampleFidelity: full | reduced | unknown`, exported sample count, and original sample count when known. Preserve this through local/cloud storage. Existing records without trustworthy provenance remain `unknown`. Current iCloud synchronization can reduce histories to 1,200 samples or fewer, and can replace a local record during merge. A webpage cannot recover omitted measurements.

Saved whole-workout summaries remain authoritative. For complete data, range calculations must match iOS: time-weighted HR, maximum three-second support per reading, early termination at known signal loss or pause, and the captured zone rules. Do not recompute whole-workout metrics from a reduced trace and present them as original values. For reduced/unknown data, render the available saved samples as points while preserving confirmed pauses and invalidity boundaries. The viewer has no recording-completeness banner or range-inspection panel; fidelity metadata remains in the downloadable export. Do not infer sensor failure or data coverage from sparse sample spacing. Where old zone thresholds are missing, show saved zone durations without inventing thresholds from today's settings.

## Storage and access

Use private Vercel Blob for one compressed workout export per current page version. Use the existing Redis service for small metadata records: blob location, schema/version, hashes of access credentials, encrypted view-key recovery envelopes, management ownership, status, and timestamps. Keep workout measurements and descriptions out of Redis. Configure persistent metadata without expiry or automatic eviction, and verify the provider's durability and recovery policy. Permanent pages have their own namespace and lifecycle, separate from live sharing's five-minute/90-minute expiry logic.

Serve a server-rendered page shell at `https://bpmtracker.app/w/<22-character-link-code>#<view-key>`, retaining the older UUID and preview-query forms. The 128-bit link code authorizes only the preview image; the app uses it after server metadata confirms registration. The app generates an independent random 256-bit view key before creation. The fragment keeps the view secret out of ordinary page-request URLs; the browser sends it in an authorization header when fetching data. Test that intended sharing destinations preserve the fragment. The separate preview token permits only a PNG containing the shared title, date, chart, duration, average, and maximum heart rate. It cannot authorize the workout JSON. The HTML exposes generic text plus that image URL, never the workout payload. Old fragment-only links continue to work with generic metadata. Replacing or deleting a link revokes future preview retrieval; recipients may retain cached cards. The user approved this preview disclosure. Preview rendering uses bundled assets without third-party font or emoji requests; unsupported title glyphs are omitted from the remote image while the native card and webpage retain the original title.

The data endpoint checks authorization and revocation before reading private Blob. The raw object URL must not grant public access. This is a bearer link: anyone who receives or forwards the full link can view the workout. BPM and its hosting providers can process the stored data; this design does not promise end-to-end encryption.

Workout API, PNG, HTML shell, and Next.js data responses use `Cache-Control: private, no-store`. Public static assets may be cached. Use `noindex`, `nofollow`, and `no-referrer`, exclude pages from sitemaps, and load no third-party analytics or external fonts/scripts on workout pages. Explicitly exclude these routes from the existing global Vercel Analytics component. No secrets, notes, measurements, or request bodies in application logs; verify platform log and monitoring behavior before launch. Render user text as text, never executable HTML.

The API needs create, stage, activate, read, preview-image, update, revoke/delete, and owner-list operations. Creates and retries use an idempotency key bound to management authority that the app persists before upload. An authenticated retry must recover the same page if creation or activation succeeds but its response is lost. Staging writes a validated private object without publishing it or changing an existing page; drafts expire after 24 hours and their objects enter cleanup. Activation atomically publishes the staged metadata. An update switches the metadata pointer only after its new object is complete. Existing direct publication and management operations remain supported. Expired pending uploads and superseded objects are cleaned up. Deletion revokes access first, then removes the object with retryable cleanup; a revoked page cannot become readable because Blob deletion failed.

## Ownership and indefinite retention

Viewer authority and management authority are separate. A viewer cannot edit or delete a page. Store management credentials in Keychain and maintain a Shared Pages registry independently of workout records. Current local history defaults to deletion after 365 days, which must not remove the user's ability to manage a hosted page.

Shared Pages provides Open, Copy Link, Update, Replace Link, and Delete. Deleting a local workout offers an explicit choice about its hosted page. Automatic local-history pruning leaves the Shared Pages registry intact. Replacing a link invalidates the old view key while preserving management access.

Offer a user-saved management recovery credential and a restore flow so device loss or reinstall need not orphan indefinite uploads. Preserve view keys in encrypted registry envelopes, with the encryption key held by the app and the recovery credential, never the server. This lets a recovered installation restore existing links without trying to reverse stored hashes or forcing link replacement. The recovery credential also restores management authority and is never included in ordinary sharing. Losing both the device's credential and the recovery copy prevents automatic ownership recovery; make this limitation clear. Do not rely on a local workout ID, the viewer link, or presumed Keychain survival after uninstall as deletion authority.

Retain pages with no scheduled expiry while the feature is operated, until user deletion or abuse removal. Describe this as **No automatic expiration**, not an irrevocable hosting guarantee. Disclose any operational backup retention before launch. Deletion blocks future server retrieval but cannot recall recipient downloads, cached link-preview cards, or data already loaded in a browser.

## Apple review and privacy

The design is compatible with Apple's published rules in principle; final review approval cannot be guaranteed. Sections 5.1.1–5.1.3 require consent, clear collection/sharing/retention disclosures, a withdrawal/deletion path, and appropriate handling of health data. Anonymous collection still requires consent. These sections do not specify a fixed retention maximum. Keeping a deliberately shared page until deletion is a reasonable interpretation, provided deletion works. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy)

Call the feature private-link or unlisted sharing. Names can appear in titles and descriptions, and removing account identifiers does not make health data fully anonymous. Restrict use to delivering the requested fitness page. Keep health content out of advertising and unrelated analytics. HealthKit-derived information carries additional restrictions, reinforcing the decision to omit imported profile data. [HealthKit privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)

Permanent off-device hosting counts as collection. Declare Health, Fitness, and Other User Content for App Functionality as appropriate; an optional checkbox does not by itself qualify for Apple's optional-disclosure exception. Review linkage based on actual data handling. The current local privacy manifest already marks these categories linked to the user, without tracking. Verify App Store Connect answers independently and update the privacy policy's current live-only retention description. [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

Because title/description are user content, include proportionate text filtering, a report/contact route, timely removal, and the ability to block abusive uploaders. Unlisted URLs are not an exemption from user-content rules. Review notes should demonstrate consent, viewing, downloads, deletion, and the Bluetooth data source. [Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)

## Cost model

Planning estimates at published US rates checked November 11, 2026, not a verified account invoice. Assume 30-day months, a constant upload rate, no deletions, and monthly total page loads equal to ten times new monthly uploads, including all revisits to older pages. Each view fetches the data once plus 0.5 MB of page assets. This does not assume every archived page gets ten new views every month.

| Scenario | Uploads/month | Total page loads/month | Stored at year 1 / year 5 | Monthly gross usage at year 1 / year 5 |
| --- | ---: | ---: | ---: | ---: |
| Light adoption, 0.5 MB compressed workouts | 300 | 3,000 | 1.8 / 9 GB | $0.86 / $1.03 |
| All 40 DAUs upload daily, 0.5 MB workouts | 1,200 | 12,000 | 7.2 / 36 GB | $3.44 / $4.11 |
| Same audience, 2 MB workouts | 1,200 | 12,000 | 28.8 / 144 GB | $10.08 / $12.73 |
| Ten times the volume, 2 MB workouts | 12,000 | 120,000 | 288 / 1,440 GB | $101 / $127 |

These estimates include Blob storage/operations, private delivery's transfer legs, upload traffic, CDN requests, illustrative function execution, and small Redis command usage. They exclude existing subscription fees, other project usage, taxes, backups, and paid optional security/monitoring add-ons. Assume all Blob reads miss cache and no pricing credits or Flat Rate CDN benefit. Actual workout sizes and function costs require measurement. This original model excludes the later server-rendered HTML and PNG preview requests. Each uncached preview adds one bounded private-object read and image render; no second stored object is created. The preview endpoint permits 120 valid requests per page per hour, separately from full-workout reads.

Rates used: Blob storage $0.023/GB-month, Blob simple/advanced operations $0.40/$5 per million, Blob transfer $0.05/GB, Fast Data Transfer $0.15/GB, Fast Origin Transfer $0.06/GB, and CDN requests $2/million. Private delivery can incur transfer from Blob to the function and from the function to the browser. [US regional pricing](https://vercel.com/docs/pricing/regional-pricing/iad1), [Blob billing](https://vercel.com/docs/vercel-blob/usage-and-pricing)

Compute assumptions: 50 ms active CPU and one second of 1 GB memory per create/read, at $0.128/CPU-hour, $0.0106/GB-hour, and $0.60/million invocations; eight CDN requests per page load. Redis assumes four commands per upload and two per view at $0.20/100,000 commands, with metadata within the provider's first free GB. Marketplace/provider charges may be separate. [Function pricing](https://vercel.com/docs/functions/usage-and-pricing), [Redis pricing](https://upstash.com/pricing/redis.md)

At 1,200 uploads/month and 0.5 MB each, year-one storage alone costs about $0.17/month; year-five storage costs $0.83/month. Each additional year adds 7.2 GB and roughly $0.17 to monthly storage at unchanged rates. Traffic, including old links becoming popular, matters more than keeping dormant files.

Pro currently starts at $20/month with a shared $20 usage credit. Its optional Flat Rate CDN's included tier covers 1 million requests and 1 TB/month, including Fast Data Transfer and Blob Data Transfer; Fast Origin Transfer remains separate. If enabled and there is spare shared capacity, the 1,200-upload/0.5 MB model falls to about $1.06/$1.72 at year one/five before available usage credit. Actual incremental Vercel charges could be zero, but the account's plan, remaining credit, and CDN settings have not been verified. Do not assume credits cover external Redis charges. [Vercel plans](https://vercel.com/pricing), [Flat Rate CDN](https://vercel.com/docs/pricing/flat-rate-cdn)

## Abuse and budget controls

Accept only the versioned workout schema. Bound compressed and decoded bytes, sample count, duration, and title/description lengths before allocating large buffers or storing data. A starting design is 2 MB compressed and 16 MB decoded, subject to checking representative long workouts and platform request limits. Reject an oversized upload with a clear message; do not silently reduce the promised raw download.

Restrict creation to verified app clients, preferably App Attest, with per-installation and IP rate limits and a global daily creation cap. Do not ship an unrestricted anonymous file-hosting endpoint or embed a reusable server secret in the app. Provide a defined fallback for legitimate devices that cannot attest. Validate payloads server-side even for attested clients.

Deduplicate unchanged re-shares. Apply per-page and per-IP read limits that tolerate normal sharing but contain automated repeated downloads. Record aggregate counts and byte sizes without workout content or view keys. Set alerts around $10/month of feature usage and a configurable guard that can pause new uploads while retaining existing reads. Account for separately billed provider usage. These are alerts and operational controls, not a guaranteed billing ceiling against arbitrarily large traffic.

## Acceptance criteria

- Checkbox off starts no workout upload. Turning it on prepares an inaccessible draft in the background; only explicit Share activates the page. Unchecking or closing never activates a draft. Unused drafts expire after 24 hours. Cancelling, retrying, and double tapping do not create uncontrolled duplicate pages.
- Chart, stats, text, and file sharing all receive the same correct link. Cards send one URL with selected-image metadata. Messages/Mail receiving behavior requires device verification; Copy Link preserves the short preview alias and full viewing fragment; older server responses retain the legacy preview-query format.
- Page/export exclude disallowed fields. Page contents use the saved title, description, and full workout independently of temporary card edits.
- iOS/web parity fixtures cover rapid samples, pauses, signal loss, cooldown, custom zone gaps, missing thresholds, reduced histories, and absent calories/HRR. Full-workout totals match saved values.
- JSON preserves every exported sample and CSV matches that data. Downloads do not trigger duplicate data fetches. CSV escaping prevents formula interpretation of user text.
- Unknown/wrong/revoked view keys cannot retrieve data. Viewer keys cannot manage pages. Owner recovery, local-history pruning, updates, and deletion work independently of the source workout.
- Delete blocks subsequent full-workout and preview retrieval immediately; object cleanup failures retry. Only the explicitly permitted card content appears in previews. No workout payload or viewing/management key appears in HTML, analytics, application logs, or search listings. Preview-only aliases and legacy preview query tokens may appear in platform request metadata; recipients may cache the image despite no-store.
- Representative file-size/latency measurements validate limits and cost assumptions before release. Upload abuse limits and budget alerts are exercised.
- Privacy policy, App Store disclosures, and reviewer instructions match the shipped behavior.

## Code touchpoints

- `BPM/WorkoutShareDrawer.swift` and `BPM/WorkoutShareCardEditor.swift`: fixed option layout, shared consent state, background upload and final activation, and both share paths.
- `BPM/ShareSheet.swift`: mixed attachment/text/link payloads and destination behavior.
- `BPM/WorkoutRecord.swift`, `BPM/WorkoutStore.swift`, and a new export/service/registry layer: allowlisted export, fidelity, persistence, ownership and recovery.
- `backend/pages/w/`, a dedicated workout-page API, private Blob integration, and separate Redis metadata.
- `backend/pages/_app.tsx`: exclude private pages from analytics.
- `backend/public/privacy.html`, `BPM/PrivacyInfo.xcprivacy`, and release/App Store records: accurate collection, retention and deletion disclosures.

Initial scope is completed-workout pages with no accounts, password prompts, social feed, comments, AI analysis, or uploaded photos/audio. Those additions would change privacy, moderation, size, and cost assumptions.
